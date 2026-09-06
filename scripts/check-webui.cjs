/*
 * Render the web dashboard headlessly, every page in every operating mode.
 *
 * Why this exists: the dashboard is one inline script, so a stale reference
 * survives every check the repo had. `node --check` only parses it and the
 * Swift schema tests only read schema.json -- neither ever RUNS a render. A
 * helper deleted during the 0.50 operating-mode work left two call sites
 * behind, and the Monitoring page (the landing page) threw ReferenceError in
 * every mode with no test failing anywhere. This runs the real script against
 * a real DOM.
 *
 * What it asserts, per mode (mpx / fm / hd / am) and per page:
 *   1. the render does not throw -- stale references, bad reads, typos;
 *   2. nothing is shown that has no function in the mode: no sidebar entry,
 *      no overview / signal-chain card, no widget whose schema entry excludes
 *      this mode;
 *   3. no titled card renders empty, which is what gating every key inside a
 *      card leaves behind.
 *
 * Usage: scripts/check-webui.sh   (installs jsdom into .webui-check/ once)
 */
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");
const { JSDOM } = require("jsdom");

const root = resolve(__dirname, "..");
const webui = resolve(root, "macOS/Sources/MPXPrime/Control/WebUI");
const html = readFileSync(resolve(webui, "index.html"), "utf8");
const schema = JSON.parse(readFileSync(resolve(webui, "schema.json"), "utf8"));

const MODES = ["mpx", "fm", "hd", "am"];

// The page is one inline <script>. Run it ourselves (scripts disabled during
// parse) so the stubs are in place first, and drop the boot() call + timers,
// which only talk to an encoder that is not here.
const script = html.slice(html.indexOf("<script>") + 8, html.lastIndexOf("</script>"))
  .replace(/^boot\(\);$/m, "")
  .replace(/^setInterval\(.*$/gm, "");

/** A config with every schema key at a plausible default, in the given mode. */
function configFor(mode) {
  const cfg = { control_bind: "127.0.0.1", control_port: "8737" };
  for (const [key, def] of Object.entries(schema.schema)) {
    if (def.kind === "toggle") cfg[key] = "True";
    else if (def.kind === "slider") cfg[key] = String(def.min ?? 0);
    else if (def.kind === "seg") cfg[key] = String((def.options || [{ value: "" }])[0].value ?? "");
    else cfg[key] = "";
  }
  cfg.processed_audio_ceiling_dbtp = "-1.0";
  cfg.am_positive_peak_pct = "125";
  cfg.operating_mode = mode;   // last: it is itself a widget key the loop seeds
  return cfg;
}

// Probe appended to the page script, so it shares the script's own scope and
// can see `cfg`, `MODEL`, `showPage` and the rest.
const probe = `
  SCHEMA = __fixture.schema;
  MODEL = __fixture.model;
  cfg = __fixture.cfg;
  deviceInfo = { inputs: [], outputs: [], selectedInput: "", selectedOutput: "" };
  statusInfo = { running: false, outputMode: __fixture.mode };
  presetLists = { primebass: [], multiband: [], finalstage: [], format_profile: [] };
  // Renders end by kicking off the live polls; there is no encoder here and
  // their async continuations would outlive the closed window.
  pollMeters = () => {};
  pollStatus = () => {};
  pollRDS = () => {};
  const __problems = [];
  const __inMode = (modes) => !modes || modes.indexOf(__fixture.mode) >= 0;
  const __fail = (page, msg) => __problems.push(page + ": " + msg);

  renderSidebar();
  const __nav = [...document.querySelectorAll("#sidebar .nav")].map(n => n.dataset.page);
  for (const s of MODEL.stages) {
    if (!__inMode(s.modes) && __nav.includes(s.id)) __fail("sidebar", 'stage "' + s.id + '" is listed but has no function in this mode');
  }
  for (const p of MODEL.rds) {
    if (!__inMode(p.modes || MODEL.rdsModes) && __nav.includes(p.id)) __fail("sidebar", 'RDS page "' + p.id + '" is listed');
  }

  const __pages = ["monitoring", "overview"]
    .concat(MODEL.stages.map(s => s.id))
    .concat(MODEL.rds.map(p => p.id))
    .concat(MODEL.tools.map(p => p.id));
  for (const id of __pages) {
    const hidden = pageHiddenInMode(id);
    try { showPage(id); }
    catch (e) { __fail(id, "render threw " + e.name + ": " + e.message); continue; }
    if (hidden) continue;                    // showPage falls back to Monitoring
    const c = document.getElementById("content");
    for (const el of c.querySelectorAll("[data-key]")) {
      const def = SCHEMA[el.dataset.key];
      if (def && !__inMode(def.modes)) __fail(id, 'control "' + el.dataset.key + '" is shown but has no function in this mode');
    }
    for (const fc of c.querySelectorAll(".fcard")) {
      const body = fc.querySelector(".card");
      const h2 = fc.querySelector("h2");
      if (body && body.children.length === 0) __fail(id, 'card "' + (h2 ? h2.textContent : "?") + '" renders empty');
    }
  }
  __result = __problems;
`;

const problems = [];
for (const mode of MODES) {
  // A real origin, or jsdom disables localStorage (the page remembers its
  // API key there).
  const dom = new JSDOM(html, {
    runScripts: "outside-only", pretendToBeVisual: true, url: "http://localhost:8737/"
  });
  const win = dom.window;
  win.fetch = () => Promise.reject(new Error("offline"));
  win.EventSource = class { close() {} };
  win.__fixture = { schema: schema.schema, model: schema.model, cfg: configFor(mode), mode };
  win.__result = null;
  try {
    win.eval(script + probe);
  } catch (e) {
    problems.push(`[${mode}] page script threw ${e.name}: ${e.message}`);
    win.close();
    continue;
  }
  for (const p of win.__result || []) problems.push(`[${mode}] ${p}`);
  win.close();
}

if (problems.length) {
  console.error(`web dashboard: ${problems.length} problem(s)`);
  for (const p of problems) console.error("  " + p);
  process.exit(1);
}
console.log(`web dashboard: ${MODES.length} modes x all pages rendered clean`);
