/*
 * Boot the web dashboard headlessly against a fake encoder and drive it.
 *
 * Why this exists: the dashboard is one inline script, so a stale reference or
 * a wrong boot order survives every other check the repo has -- `node --check`
 * only parses it and the Swift schema tests only read schema.json. Two 0.50
 * defects shipped that way: a deleted helper left two call sites behind (the
 * landing page threw in every mode), and the sidebar was rendered BEFORE the
 * config arrived (RDS pages and composite stages stayed on screen in fm/hd/am).
 * Neither had a failing test anywhere. This runs the real script, with the real
 * `boot()`, against a real DOM and a fake server.
 *
 * What it asserts, per mode (mpx / fm / hd / am):
 *   1. boot leaves a sidebar that matches the mode the SERVER reports;
 *   2. every page renders without throwing (stale references, bad reads);
 *   3. nothing is shown that has no function in the mode: no sidebar entry,
 *      no overview / signal-chain card, no widget the schema gates out;
 *   4. no titled card renders empty, and no page renders the same key twice;
 *   5. switching the operating mode from the page WORKS: the segment follows,
 *      the sidebar follows, the restart badge appears, and a level the backend
 *      recalled for the new mode is visible (i.e. the config was re-read);
 *   6. switching back does not blow up (the historical stack overflow);
 *   7. a server-side clamp snaps the control back instead of throwing;
 *   8. changing a device re-reads the device list;
 *   9. a mode change made elsewhere reaches a page that is sitting on
 *      Monitoring;
 *  10. the levelling engine selector on the Overview WORKS: only the engine in
 *      use has its pages listed (sidebar, overview grid), nothing is ghosted,
 *      and switching engines flips them both ways;
 *  11. "Apply recommended" on the Overview WORKS: with a Format Profile
 *      selected one click POSTs that profile to /api/presets and re-reads the
 *      config; with `custom` selected the button is disabled and says why.
 *
 * Usage: scripts/check-webui.sh   (installs jsdom into .webui-check/ once)
 */
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");
const { JSDOM } = require("jsdom");

const root = resolve(__dirname, "..");
const webui = resolve(root, "Sources/MPXPrime/Control/WebUI");
const html = readFileSync(resolve(webui, "index.html"), "utf8");
const schema = JSON.parse(readFileSync(resolve(webui, "schema.json"), "utf8"));

const MODES = ["mpx", "fm", "hd", "am"];

// The page is one inline <script>. Run it ourselves (scripts disabled during
// parse) so the fake server is in place first, and drop the timers -- boot()
// itself is kept and awaited, because its ORDER is one of the things at stake.
const script = html.slice(html.indexOf("<script>") + 8, html.lastIndexOf("</script>"))
  .replace(/^boot\(\);$/m, "")
  .replace(/^streamMeters\(\);$/m, "")
  .replace(/^setInterval\(.*$/gm, "");

// The page is strict-mode, so its declarations stay inside the eval that runs
// it. Hand the few entry points we drive out through the window, in the SAME
// eval, rather than re-evaluating snippets against a scope that cannot see them.
const bridge = `
window.__page = {
  boot, showPage, syncAll, loadConfig, currentMode, pageHiddenInMode, streamMeters,
  configKeyCount: () => Object.keys(cfg).length
};
`;

/** Per-mode calibration the fake backend "recalls" on a mode change, the way
 *  DeviceCalibrationStore does after ConfigPatch has already answered. */
const RECALLED_OUTPUT_GAIN = { mpx: "-4.5", fm: "1.5", hd: "2.5", am: "3.5" };

/** A config with every schema key at a plausible default, in the given mode. */
function configFor(mode) {
  const cfg = { control_bind: "127.0.0.1", control_port: "8737" };
  for (const [key, def] of Object.entries(schema.schema)) {
    if (def.kind === "toggle") cfg[key] = "True";
    else if (def.kind === "slider") cfg[key] = String(def.min ?? 0);
    else if (def.kind === "seg") {
      // Options are [value, label] PAIRS. Reading `.value` here seeded every
      // seg with "" and silently disabled every seg-dependent branch.
      const first = (def.options || [])[0];
      cfg[key] = first ? String(first[0]) : "";
    } else cfg[key] = "";
  }
  cfg.processed_audio_ceiling_dbtp = "-1.0";
  cfg.am_positive_peak_pct = "125";
  cfg.format_profile_id = "music_clean";   // not a widget: the loop misses it
  cfg.output_gain_db = RECALLED_OUTPUT_GAIN[mode];
  cfg.operating_mode = mode;   // last: it is itself a widget key the loop seeds
  return cfg;
}

const problems = [];
const fail = (mode, where, msg) => problems.push(`[${mode}] ${where}: ${msg}`);

/** The fake encoder. Serves the real schema, a config it mutates on PATCH, and
 *  the few other endpoints the page touches. */
function makeServer(mode) {
  const state = {
    cfg: configFor(mode),
    restartPending: false,
    running: false,
    deviceCalls: 0,
    configReads: 0,
    patches: [],
    presetPosts: []
  };
  const devices = {
    inputs: [{ id: "in-a", name: "Input A", canInput: true, canOutput: false },
             { id: "in-b", name: "Input B", canInput: true, canOutput: false }],
    outputs: [{ id: "out-a", name: "Output A", canInput: false, canOutput: true },
              { id: "out-b", name: "Output B", canInput: false, canOutput: true }],
    selectedInput: "in-a",
    selectedOutput: "out-a",
    selectedMonitor: "out-b",
    monitorEnabled: false,
    note: ""
  };
  const json = (body, status = 200) => ({
    ok: status < 400, status, statusText: "", json: async () => body
  });

  async function fetchImpl(url, opts = {}) {
    const path = String(url).replace(/^https?:\/\/[^/]+/, "");
    const method = (opts.method || "GET").toUpperCase();
    if (path === "/api/schema") return json(schema);
    if (path === "/api/config") {
      if (method === "GET") state.configReads += 1;
      if (method === "PATCH") {
        const patch = JSON.parse(opts.body);
        const outcomes = [];
        for (const [key, raw] of Object.entries(patch)) {
          state.patches.push(key);
          let value = raw;
          // The one server-side clamp the page has to survive: composite modes
          // cap the output level at 0 dB.
          if (key === "output_gain_db" && state.cfg.operating_mode === "mpx" && Number(value) > 0) value = "0.0";
          const same = state.cfg[key] === value;
          state.cfg[key] = value;
          let disposition = "live";
          if (same) disposition = "unchanged";
          else if (schema.schema[key]?.restart || key.endsWith("_device_uid") || key === "operating_mode") {
            disposition = "restartRequired";
            state.restartPending = true;
          }
          if (key === "operating_mode" && !same) {
            // The recall the real backends do AFTER computing outcomes, which
            // is why the page has to re-read the config.
            state.cfg.output_gain_db = RECALLED_OUTPUT_GAIN[value] ?? state.cfg.output_gain_db;
          }
          if (key.endsWith("_device_uid") && !same) {
            if (key === "input_device_uid") devices.selectedInput = value;
            if (key === "output_device_uid") devices.selectedOutput = value;
            if (key === "monitor_device_uid") devices.selectedMonitor = value;
          }
          outcomes.push({ key, disposition, effectiveValue: value });
        }
        return json({ outcomes, appliedLive: true, restartPending: state.restartPending });
      }
      return json({ MPX: state.cfg });
    }
    if (path === "/api/config/defaults") return json({ MPX: configFor(mode) });
    if (path === "/api/devices") { state.deviceCalls += 1; return json(devices); }
    if (path === "/api/status") {
      return json({
        running: state.running, platform: "macOS", version: "0.50",
        sampleRateHz: Number(state.cfg.sample_rate || 192000),
        restartPending: state.restartPending,
        sourceMode: state.cfg.source_mode || "input",
        outputMode: state.cfg.operating_mode, notes: []
      });
    }
    const meters = { inputLeftPeak: 0.5, inputRightPeak: 0.25, outputPeak: 0.8, dacPeakDBFS: -3.2, renderXruns: 0, captureXruns: 0, renderLoadPercent: 42 };
    if (path === "/api/meters") return json(meters);
    if (path.startsWith("/api/meters/stream")) {
      // Two NDJSON lines split across chunks, then end -- the page must parse
      // them, apply both, and fall back to polling when the stream closes.
      const enc = new TextEncoder();
      const second = JSON.stringify({ ...meters, outputPeak: 0.4 }) + "\n";
      const chunks = [enc.encode(JSON.stringify(meters) + "\n" + second.slice(0, 10)), enc.encode(second.slice(10))];
      let i = 0;
      const body = { getReader: () => ({ read: async () => i < chunks.length ? { value: chunks[i++], done: false } : { value: undefined, done: true } }) };
      state.streamReads = (state.streamReads || 0) + 1;
      return { ok: true, status: 200, statusText: "", body, json: async () => ({}) };
    }
    if (path === "/api/presets") {
      if (method === "POST") {
        const body = JSON.parse(opts.body);
        state.presetPosts.push(body);
        if (body.kind === "format_profile") state.cfg.format_profile_id = body.id;
      }
      return json({});
    }
    if (path === "/api/rds") return json({ ps: "TEST", rt: "" });
    if (path === "/api/snapshots") return json({ slots: [] });
    if (path.startsWith("/api/transport/")) return json({ ok: true });
    return json({ error: { message: "not found" } }, 404);
  }
  return { state, devices, fetchImpl };
}

/** Let queued promises and the page's own async work drain. */
const settle = async () => { for (let i = 0; i < 8; i++) await new Promise(r => setTimeout(r, 0)); };

async function runMode(mode) {
  try {
    await runModeUnguarded(mode);
  } catch (e) {
    fail(mode, "check", `the page broke the harness: ${e.name}: ${e.message}`);
  }
}

async function runModeUnguarded(mode) {
  const server = makeServer(mode);
  const dom = new JSDOM(html, {
    runScripts: "outside-only", pretendToBeVisual: true, url: "http://localhost:8737/"
  });
  const win = dom.window;
  win.fetch = (url, opts) => server.fetchImpl(url, opts);
  // Browsers have these on window; jsdom does not. The meters stream decodes
  // its chunks with TextDecoder.
  win.TextDecoder = TextDecoder;
  win.TextEncoder = TextEncoder;
  win.EventSource = class { close() {} };
  const errors = [];
  win.addEventListener("error", (e) => errors.push(e.error?.message || e.message));
  win.addEventListener("unhandledrejection", (e) => errors.push(String(e.reason)));

  const inMode = (modes) => !modes || modes.indexOf(mode) >= 0;
  const $ = (id) => win.document.getElementById(id);
  const content = () => win.document.getElementById("content");
  const navIds = () => [...win.document.querySelectorAll("#sidebar .nav")].map(n => n.dataset.page);
  const drainErrors = (where) => {
    for (const e of errors) fail(mode, where, `raised ${e}`);
    errors.length = 0;
  };

  win.eval(script + bridge);
  const page = win.__page;
  // (1) the REAL boot, in its real order.
  await page.boot();
  await settle();
  drainErrors("boot");

  // (1b) the meters stream: two NDJSON lines split across chunks must both be
  // parsed and the last one must reach the bars (outputPeak 0.4 = -8.0 dBFS).
  await page.streamMeters();
  await settle();
  drainErrors("meters stream");
  if (!server.state.streamReads) fail(mode, "meters stream", "the stream was never requested");
  const outText = $("monOut") ? $("monOut").textContent : "";
  if (!outText.includes("-8.0")) fail(mode, "meters stream", `streamed meters did not reach the bars (Output reads "${outText}")`);

  if (!page.configKeyCount()) fail(mode, "boot", "config was never loaded");

  // (1c) the taxonomy: every page the model knows sits in exactly one section
  // or group, and the sidebar never shows a section or group header with
  // nothing under it; the current page carries its breadcrumb.
  {
    const placed = new Map();
    for (const sec of schema.model.sections) {
      for (const id of sec.pages || []) placed.set(id, (placed.get(id) || 0) + 1);
      for (const g of sec.groups || []) for (const id of g.pages) placed.set(id, (placed.get(id) || 0) + 1);
    }
    const allPages = ["monitoring", "overview"]
      .concat(schema.model.stages.map(s => s.id), schema.model.rds.map(p => p.id), schema.model.tools.map(p => p.id));
    for (const id of allPages) {
      if ((placed.get(id) || 0) !== 1) fail(mode, "taxonomy", `page "${id}" is in ${placed.get(id) || 0} sections/groups (must be exactly 1)`);
    }
    for (const id of placed.keys()) if (!allPages.includes(id)) fail(mode, "taxonomy", `sections name an unknown page "${id}"`);
    for (const sec of win.document.querySelectorAll("#sidebar .ssec")) {
      if (!sec.querySelectorAll(".nav").length) fail(mode, "taxonomy", `section "${sec.dataset.section}" is drawn empty`);
    }
    for (const gh of win.document.querySelectorAll("#sidebar .sgroup")) {
      const next = gh.nextElementSibling;
      if (!next || !next.classList.contains("nav")) fail(mode, "taxonomy", `group "${gh.dataset.group}" is drawn with no page under it`);
    }
    if (!content().querySelector(".crumb")) fail(mode, "taxonomy", "the landing page has no breadcrumb");
  }

  // (1d) the aids: task shortcuts lead only to pages this mode has; the
  // settings search finds a control, jumps to its page, opens the Advanced
  // card it sits in and highlights it; the phone layout's hooks exist.
  {
    const scs = [...content().querySelectorAll(".shortcuts .sc")];
    if (scs.length < 2) fail(mode, "aids", `landing page shows ${scs.length} task shortcuts`);
    for (const b of scs) if (page.pageHiddenInMode(b.dataset.page)) fail(mode, "aids", `shortcut "${b.textContent}" leads to a page hidden in this mode`);
    const search = $("navSearch");
    if (!search) fail(mode, "aids", "no settings search box");
    else {
      const probe = mode === "mpx" ? "pilot" : "hpf";
      search.value = probe;
      search.dispatchEvent(new win.Event("input", { bubbles: true }));
      const hits = [...win.document.querySelectorAll("#navResults .nav")];
      if (!hits.length) fail(mode, "aids", `search for "${probe}" found nothing`);
      else {
        hits[0].click();
        await settle();
        const key = hits[0].dataset.hit;
        const el = content().querySelector(`[data-key="${key}"]`);
        if (!el) fail(mode, "aids", `search hit "${key}" did not land on a page showing it`);
        else if (!el.classList.contains("hit")) fail(mode, "aids", `search hit "${key}" is not highlighted`);
        const det = el && el.closest("details.advcard");
        if (det && !det.open) fail(mode, "aids", `search hit "${key}" sits in a closed Advanced card`);
      }
      search.value = "";
      search.dispatchEvent(new win.Event("input", { bubbles: true }));
      if (win.document.querySelectorAll("#sidebar .ssec[hidden]").length) fail(mode, "aids", "sections stay hidden after the search is cleared");
    }
    if (!$("navToggle")) fail(mode, "aids", "no menu button for the phone drawer");
    if (!/@media \(max-width: 720px\)/.test(html)) fail(mode, "aids", "no phone media query in the stylesheet");
    page.showPage("limiter"); await settle();
    if (!content().querySelector(".row .numin")) fail(mode, "aids", "slider rows carry no numeric field for phones");
  }
  if (page.currentMode() !== mode) {
    fail(mode, "boot", `page thinks the mode is ${page.currentMode()}`);
  }
  for (const s of schema.model.stages) {
    if (!inMode(s.modes) && navIds().includes(s.id)) {
      fail(mode, "boot sidebar", `stage "${s.id}" is listed but has no function in this mode`);
    }
  }
  for (const p of schema.model.rds) {
    if (!inMode(p.modes || schema.model.rdsModes) && navIds().includes(p.id)) {
      fail(mode, "boot sidebar", `RDS page "${p.id}" is listed`);
    }
  }

  // (2-4) every page renders, shows only what the mode has, no empty or
  // duplicated cards.
  const pages = ["monitoring", "overview"]
    .concat(schema.model.stages.map(s => s.id))
    .concat(schema.model.rds.map(p => p.id))
    .concat(schema.model.tools.map(p => p.id));
  for (const id of pages) {
    const hidden = page.pageHiddenInMode(id);
    try { page.showPage(id); }
    catch (e) { fail(mode, id, `render threw ${e.name}: ${e.message}`); continue; }
    await settle();
    drainErrors(id);
    if (hidden) continue;   // showPage falls back to Monitoring
    const seen = new Set();
    for (const el of content().querySelectorAll("[data-key]")) {
      const key = el.dataset.key;
      const def = schema.schema[key];
      if (def && !inMode(def.modes)) {
        fail(mode, id, `control "${key}" is shown but has no function in this mode`);
      }
      if (seen.has(key)) fail(mode, id, `control "${key}" is rendered twice on one page`);
      seen.add(key);
    }
    for (const el of content().querySelectorAll("[data-key]")) {
      const def = schema.schema[el.dataset.key];
      const inAdv = !!el.closest("details.advcard");
      if (def && !!def.advanced !== inAdv && schema.model.stages.some(s => s.id === id)) {
        fail(mode, id, `control "${el.dataset.key}" is ${inAdv ? "inside" : "outside"} the Advanced card but the schema says advanced=${!!def.advanced}`);
      }
    }
    for (const det of content().querySelectorAll("details.advcard")) {
      if (det.open) fail(mode, id, "the Advanced card renders open");
      if (!det.querySelectorAll("[data-key]").length) fail(mode, id, "an Advanced card renders with no controls");
    }
    for (const fc of content().querySelectorAll(".fcard")) {
      const body = fc.querySelector(".card");
      if (body && body.children.length === 0) {
        fail(mode, id, `card "${fc.querySelector("h2")?.textContent}" renders empty`);
      }
    }
  }

  // (10) the levelling engine. configFor() seeds every toggle "True", so the
  // page boots on the Advanced Dynamics engine; the AGC + Multiband pages
  // must be gone (not ghosted), and the selector must flip them both ways.
  {
    const lv = schema.model.levelling;
    if (!lv || !Array.isArray(lv.engines) || lv.engines.length < 2) {
      fail(mode, "levelling", "schema.json has no model.levelling with two engines");
    } else {
      const engineFor = (on) => lv.engines.find(e => /^(true|yes|1|on)$/i.test(e.value) === on) || lv.engines[0];
      const cardIds = () => [...content().querySelectorAll(".ovgrid .ovcard")].map(n => n.dataset.page);
      // Every page an engine owns is a stage; the overview draws a card for
      // each one its engine has in use, switch or no switch (Advanced
      // Dynamics has none: the selector IS its switch).
      const expect = async (where, cur) => {
        const sel = content().querySelector("#levelling .seg button.sel");
        if (!sel || sel.dataset.engine !== cur.id) fail(mode, where, `the selector shows "${sel ? sel.dataset.engine : "none"}", not "${cur.id}"`);
        for (const e of lv.engines) {
          for (const id of e.pages || []) {
            const hidden = page.pageHiddenInMode(id);
            const listed = navIds().includes(id);
            const carded = cardIds().includes(id);
            if (e === cur) {
              if (hidden) fail(mode, where, `"${id}" belongs to the engine in use but pageHiddenInMode says hidden`);
              if (!listed) fail(mode, where, `sidebar does not list "${id}" though its engine is in use`);
              if (!carded) fail(mode, where, `overview shows no card for "${id}" though its engine is in use`);
            } else {
              if (!hidden) fail(mode, where, `"${id}" belongs to the other engine but pageHiddenInMode says shown`);
              if (listed) fail(mode, where, `sidebar still lists "${id}" of the engine not in use`);
              if (carded) fail(mode, where, `overview still shows a card for "${id}" of the engine not in use`);
            }
          }
        }
        if (win.document.querySelector("#sidebar [data-bypasswhen]")) fail(mode, where, "a sidebar entry is still marked as bypassed");
        for (const c of content().querySelectorAll(".ovgrid .ovcard")) {
          const st = schema.model.stages.find(s => s.id === c.dataset.page);
          if (c.style.opacity && Number(c.style.opacity) < 1) fail(mode, where, `overview card "${c.dataset.page}" is dimmed`);
          if (c.querySelector("input:disabled")) fail(mode, where, `overview card "${c.dataset.page}" has a disabled switch`);
          if (st && !st.enable && c.querySelector(".switch")) fail(mode, where, `overview card "${c.dataset.page}" has a switch but the stage has no enable key`);
          if (st && st.enable && !c.querySelector(".switch")) fail(mode, where, `overview card "${c.dataset.page}" has no switch`);
        }
        // The Monitoring signal chain follows the same choice.
        page.showPage("monitoring");
        await settle();
        const chain = cardIds();
        for (const e of lv.engines) {
          for (const id of e.pages || []) {
            const st = schema.model.stages.find(s => s.id === id);
            if (e === cur && st && st.summary && !chain.includes(id)) fail(mode, where, `signal chain shows no card for "${id}" though its engine is in use`);
            if (e !== cur && chain.includes(id)) fail(mode, where, `signal chain still shows "${id}" of the engine not in use`);
          }
        }
        page.showPage("overview");
        await settle();
        drainErrors(where);
      };
      page.showPage("overview");
      await settle();
      const buttons = content().querySelectorAll("#levelling .seg button");
      if (buttons.length !== lv.engines.length) {
        fail(mode, "levelling", `the Overview shows ${buttons.length} engine buttons, not ${lv.engines.length}`);
      } else {
        const start = engineFor(/^(true|yes|1|on)$/i.test(server.state.cfg[lv.key]));
        const other = lv.engines.find(e => e !== start);
        await expect("levelling", start);
        const patchesBefore = server.state.patches.length;
        content().querySelector(`#levelling .seg button[data-engine="${other.id}"]`).dispatchEvent(new win.MouseEvent("click", { bubbles: true }));
        await settle();
        drainErrors(`levelling ${start.id}->${other.id}`);
        if (!server.state.patches.slice(patchesBefore).includes(lv.key)) fail(mode, `levelling ${start.id}->${other.id}`, `no PATCH carried ${lv.key}`);
        if (server.state.cfg[lv.key] !== other.value) fail(mode, `levelling ${start.id}->${other.id}`, `server holds ${lv.key}=${server.state.cfg[lv.key]}`);
        await expect(`levelling ${start.id}->${other.id}`, other);
        const back = content().querySelector(`#levelling .seg button[data-engine="${start.id}"]`);
        if (!back) fail(mode, `levelling ${other.id}->${start.id}`, "the Overview no longer offers the selector");
        else {
          back.dispatchEvent(new win.MouseEvent("click", { bubbles: true }));
          await settle();
          drainErrors(`levelling ${other.id}->${start.id}`);
          if (server.state.cfg[lv.key] !== start.value) fail(mode, `levelling ${other.id}->${start.id}`, "did not switch back");
          await expect(`levelling ${other.id}->${start.id}`, start);
        }
      }
    }
  }

  // (11) "Apply recommended": the Overview offers it next to the levelling
  // selector; with a profile selected a click POSTs exactly that profile and
  // re-reads the config; with `custom` it is disabled and says why.
  {
    const profileId = server.state.cfg.format_profile_id;
    page.showPage("overview");
    await settle();
    const button = content().querySelector("#recommended #applyRecommended");
    if (!button) fail(mode, "recommended", "the Overview shows no Apply recommended button");
    else {
      if (button.disabled) fail(mode, "recommended", `the button is disabled though "${profileId}" is selected`);
      const caption = content().querySelector("#recommended .subtitle");
      if (!caption || !caption.textContent.includes(profileId)) fail(mode, "recommended", "the caption does not name the selected profile");
      const postsBefore = server.state.presetPosts.length;
      const readsBefore = server.state.configReads;
      button.dispatchEvent(new win.MouseEvent("click", { bubbles: true }));
      await settle();
      drainErrors("recommended");
      const posts = server.state.presetPosts.slice(postsBefore);
      if (posts.length !== 1) fail(mode, "recommended", `the click made ${posts.length} POSTs to /api/presets, not 1`);
      else if (posts[0].kind !== "format_profile" || posts[0].id !== profileId || "intensity" in posts[0]) {
        fail(mode, "recommended", `the POST body was ${JSON.stringify(posts[0])}`);
      }
      if (server.state.configReads <= readsBefore) fail(mode, "recommended", "the config was not re-read after the apply");
      // Custom: nothing to re-apply, so the button rests and the caption says so.
      server.state.cfg.format_profile_id = "custom";
      await page.loadConfig();
      page.showPage("overview");
      await settle();
      drainErrors("recommended custom");
      const rest = content().querySelector("#recommended #applyRecommended");
      if (!rest) fail(mode, "recommended custom", "the button is gone instead of disabled");
      else if (!rest.disabled) fail(mode, "recommended custom", "the button is enabled with the custom profile");
      const restCaption = content().querySelector("#recommended .subtitle");
      if (!restCaption || !/Custom keeps your manual tuning/.test(restCaption.textContent)) fail(mode, "recommended custom", "the caption does not explain the disabled button");
      server.state.cfg.format_profile_id = profileId;
      await page.loadConfig();
      page.syncAll();
      await settle();
    }
  }

  // (5-6) switch the operating mode from the Audio I/O page, to every other
  // mode and back. This is the operator's "breaks when switching".
  for (const other of MODES.filter(m => m !== mode)) {
    page.showPage("interfaces");
    await settle();
    const seg = content().querySelector('[data-key="operating_mode"]');
    if (!seg) { fail(mode, "switch", "the Audio I/O page has no operating mode control"); break; }
    const button = seg.querySelector(`button[data-v="${other}"]`);
    if (!button) { fail(mode, "switch", `no segment for ${other}`); break; }
    button.dispatchEvent(new win.MouseEvent("click", { bubbles: true }));
    await settle();
    drainErrors(`switch ${mode}->${other}`);

    if (page.currentMode() !== other) {
      fail(mode, `switch ${mode}->${other}`, `page still thinks the mode is ${page.currentMode()}`);
    }
    const selected = content().querySelector('[data-key="operating_mode"] button.sel');
    if (!selected || selected.dataset.v !== other) {
      fail(mode, `switch ${mode}->${other}`, `the segment shows "${selected ? selected.dataset.v : "none"}"`);
    }
    for (const s of schema.model.stages) {
      const applies = !s.modes || s.modes.indexOf(other) >= 0;
      if (!applies && navIds().includes(s.id)) {
        fail(mode, `switch ${mode}->${other}`, `sidebar still lists "${s.id}"`);
      }
    }
    const gain = content().querySelector('[data-key="output_gain_db"] input');
    if (gain && Number(gain.value) !== Number(RECALLED_OUTPUT_GAIN[other])) {
      fail(mode, `switch ${mode}->${other}`,
        `output level shows ${gain.value}, not the recalled ${RECALLED_OUTPUT_GAIN[other]} (config was not re-read)`);
    }
    if ($("restartBadge") && $("restartBadge").style.display === "none") {
      fail(mode, `switch ${mode}->${other}`, "no restart-pending badge");
    }
    // ...and back, which is where the recursion used to detonate.
    const back = content().querySelector(`[data-key="operating_mode"] button[data-v="${mode}"]`);
    if (!back) {
      fail(mode, `switch ${other}->${mode}`, "the page no longer offers the operating mode control");
      break;
    }
    back.dispatchEvent(new win.MouseEvent("click", { bubbles: true }));
    await settle();
    drainErrors(`switch ${other}->${mode}`);
    if (page.currentMode() !== mode) {
      fail(mode, `switch ${other}->${mode}`, "did not switch back");
    }
  }

  // (7) a server-side clamp must snap the control, not throw.
  if (mode === "mpx") {
    page.showPage("interfaces");
    await settle();
    const gain = content().querySelector('[data-key="output_gain_db"] input');
    if (gain) {
      gain.value = "6";
      gain.dispatchEvent(new win.Event("change", { bubbles: true }));
      await settle();
      drainErrors("clamp");
      if (Number(gain.value) > 0) fail(mode, "clamp", `slider kept ${gain.value} after the server clamped to 0`);
    }
  }

  // (8) a device change re-reads the listing.
  page.showPage("interfaces");
  await settle();
  const before = server.state.deviceCalls;
  const devOut = $("devOut");
  if (!devOut || devOut.options.length < 2) {
    fail(mode, "devices", "the output picker was not populated");
  } else {
    devOut.value = "out-b";
    devOut.dispatchEvent(new win.Event("change", { bubbles: true }));
    await settle();
    drainErrors("devices");
    if (server.state.deviceCalls <= before) fail(mode, "devices", "the device list was not re-read after a device change");
  }

  // (9) a mode change made elsewhere reaches a page sitting on Monitoring.
  const elsewhere = MODES.find(m => m !== mode);
  page.showPage("monitoring");
  await settle();
  server.state.cfg.operating_mode = elsewhere;
  await page.loadConfig();
  page.syncAll();
  await settle();
  drainErrors("external mode change");
  for (const s of schema.model.stages) {
    const applies = !s.modes || s.modes.indexOf(elsewhere) >= 0;
    if (!applies && navIds().includes(s.id)) {
      fail(mode, "external mode change", `sidebar still lists "${s.id}" after the mode changed to ${elsewhere}`);
    }
  }

  win.close();
}

(async () => {
  const started = Date.now();
  for (const mode of MODES) await runMode(mode);
  if (problems.length) {
    console.error(`web dashboard: ${problems.length} problem(s)`);
    for (const p of problems) console.error("  " + p);
    process.exit(1);
  }
  console.log(`web dashboard: ${MODES.length} modes booted, rendered and switched clean (${((Date.now() - started) / 1000).toFixed(1)}s)`);
})();
