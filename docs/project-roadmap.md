# MPX Prime -- Project Roadmap and Open Work

<!-- markdownlint-disable MD025 -->
<!-- Planning document: several deliberate top-level parts (roadmap, open
     work, guardrails), each a `#` heading so they read as separate papers. -->

Active work list + anti-rework guardrails. **Not** a readme: positioning, architecture, and build live in `README.md` / `docs/ARCHITECTURE.md` / `docs/BUILDING.md`; shipped-feature history lives in `CHANGELOG.md`. Don't re-plan shipped work as pending -- cross-check CHANGELOG before acting.

## Status

Released through **0.50** (2026-09-11, tag `v0.50`, AGPL-3.0). **Active branch:
`develop/v.060`**; 0.60 is the next target. Shipped-feature history lives in
CHANGELOG -- this file tracks only pending work and the anti-rework guardrails.
Pruned 2026-09-05: every DONE item removed, open remainders kept.

---

# Open work

## Web dashboard taxonomy and navigation -- PLAN (2026-09-11, target 0.60; phase 1 landed 2026-09-11)

The dashboard (and, by the parity rule, the GUI sidebar) groups functions the
way the ENGINE is built, not the way an operator works. This is the plan to
fix that; nothing here changes an INI key or an API route -- it is
presentation, shared by both front ends.

### The problem, measured

- Four sidebar groups -- Monitoring, Processing, RDS, Tools -- over **31 pages
  and 222 controls** (109 sliders, 74 toggles, 19 text fields, 14 segmented,
  6 numbers).
- **Processing is a flat list of 19 stage pages in engine order** with
  engine names: Core, Phase Rotator, AGC, Parametric EQ, Multiband, Advanced
  Dynamics, Expander, MB Limiter, PrimeBass, Bass Clipper, Audio Clipper, HF
  Limiter, HF Clipper, Audio Limiter, Stereo Coder, Composite Clipper, BS.412,
  Final Stage. Nothing says which of these a music station touches (three)
  and which are set once and left (the rest). Multiband alone shows 20
  controls on one page.
- **Tools is a drawer of unrelated things**: Test Tone (a signal source),
  Audio I/O (devices, mode, level calibration -- the first thing a new rig
  needs), Presets (whole-config slots), Advanced, About. An operator looking
  for "where do I set my output level" has no reason to open Tools.
- **No basic / advanced split** on any page, **no search**, no task entry
  points ("get on air", "set my levels", "change the station text").
- The GUI has the same shape (`AppSection` Monitoring / Processing / RDS,
  `ProcessingTab` 19 cases, Settings window), so this is a taxonomy change
  for both, driven from one table -- not a web-only re-skin.

### What comparable products and the IA literature do

- **Omnia.9** (Telos): a Home menu of Input / Undo / Processing / System /
  Client Audio; processing pages in signal order (expander, input AGC,
  wideband AGC, bass, EQ, stereo enhancer, multiband, band mix, output);
  **adjustment levels** that reveal more controls (basic to expert, the same
  page); breadcrumb "tree" or "tabbed" navigation; presets first-class with
  compare and protect
  ([Omnia.9 processing setup](https://docs.telosalliance.com/docs/omnia9-processing-setup)).
- **Omnia Forza**: the whole processor on one page behind a few "smart
  controls" that move many parameters at once -- the far end of hiding
  engine structure ([Telos Alliance](https://www.telosalliance.com/radio-processing/radio-processors/omnia9),
  [Forza manual](https://manuals.plus/m/351cc452ee69fd0a32b06a209f56ca96f045de7d6ee46fcb4c33328bdd430126)).
- **Orban PC Remote**: menus named after tasks -- File, Manage, Preset,
  Modify, Setup, Help ([Optimod 8600 manual](https://www.manualslib.com/manual/1267434/Orban-Optimod-Fm-8600.html?page=120)).
- **Progressive disclosure** (Nielsen Norman Group): at most **two** levels;
  the primary view holds what is used often; the disclosure control needs a
  label with a strong "information scent"; the grouping is found by card
  sorting and tested with real tasks, not decided at a desk
  ([NN/g](https://www.nngroup.com/articles/progressive-disclosure/),
  [nested tabs guidance](https://www.designmonks.co/blog/nested-tab-ui)).
- **Task-based navigation** for tools people use to get a job done: group by
  what the user is trying to do, keep the primary choices few, put frequent
  actions where they are seen, add search once the setting count is large
  ([task-based navigation](https://medium.com/@marketingtd64/what-is-task-based-navigation-and-when-should-you-use-it-e73bd7f2eed6),
  [navigation patterns](https://www.eleken.co/blog-posts/ux-navigation-design),
  [Baymard](https://baymard.com/blog/ecommerce-navigation-best-practice)).

### Proposed taxonomy (one table, read by the GUI sidebar and the dashboard)

Five top-level sections named for what the operator is doing, in the order
a new rig meets them:

| Section | What lives there | Notes |
| --- | --- | --- |
| **On Air** | status + transport, meters and the signal-chain strip, what RDS is showing right now, health notes (render load, xruns, device rate), task shortcuts | the landing page; today's Monitoring plus the shortcuts |
| **Setup** | Audio devices and operating mode; Levels and calibration (input gain, output level, line output, DAC peak, the Linux card mixer); Engine (sample rate, block size); Remote access (control server, key); Test Tone | everything done once per rig; today spread over Tools / Audio I/O / the GUI Settings window |
| **Sound** | Format Profile ("start here"), then the stages **grouped by function in signal order**: Input (Core, Phase Rotator, Expander) -- Levelling (AGC, Advanced Dynamics) -- Tone (Parametric EQ, PrimeBass + Mono Bass) -- Dynamics (Multiband, MB Limiter) -- Peak control (Bass Clipper, Audio Clipper, HF Limiter, HF Clipper, Audio Limiter) -- Transmission, MPX Output only (Stereo Coder, Composite Clipper, BS.412, Final Stage) | today's flat Processing list, with headers; the Overview becomes the section's landing page with the clickable chain strip |
| **RDS** | On-air text (what listeners see, editable) -- Identity -- Radiotext -- Long PS -- Alternative frequencies -- Schedule -- Subcarrier (expert) | same pages, ordered by how often they are touched |
| **Presets and System** | the eight preset slots (save / load / import / export), About and version, diagnostics (stream health detail, telemetry, logs) | today's Presets, Advanced, About |

Rules the tree follows: at most two disclosure levels (section > page, and a
collapsed **Advanced** card inside a page); mode gating removes whole groups
(outside MPX Output the Transmission group and the RDS section vanish, as
they do now); labels use outcome language and keep established broadcast
terms (a rename table decides the few engine names that remain: Core ->
Input, Final Stage -> Loudness and Output, MB Limiter -> Band Limiter; PEQ,
AGC, BS.412, Composite Clipper stay).

### Inside a page

- Top: the enable toggle, a one-line "what this does for the sound", the
  reset button, and the stage's one telling meter (already on the Overview).
- The controls an operator actually moves, first (Multiband: the five band
  thresholds and the drive; Composite Clipper: ceiling and the guards).
- **Advanced** (collapsed): time constants, topology choices, restart-class
  engine options. One flag per widget in `schema.json` (`"advanced": true`);
  the GUI's `DisclosureGroup`s read the same list, so both front ends fold
  the same controls.

### Navigation aids

- **Search / filter** over the schema (label, INI key, help text): 222
  entries is exactly the size where search beats browsing; typing "pilot"
  lists Pilot Level, Protect Stereo Pilot, and jumps to the control
  (`data-key` anchors already exist).
- **Breadcrumb / page title** "Sound > Dynamics > Multiband", and the
  section headers in the sidebar collapsible, remembering their state.
- **Task shortcuts on On Air**: "Set my levels", "Change the station text",
  "Load a preset", "Switch operating mode".
- **Phone layout**: the sidebar becomes a drawer, meters first, sliders get
  a numeric field (a slider on a 390 px screen is unusable for a 0.1 dB
  trim). `check-webui` renders at 390 px as well as desktop.
- **Signal-chain strip as the map**: the pills already exist on Monitoring;
  they become the Sound landing page, coloured by state, one click to the
  stage.

### How it maps onto the code

- `schema.json` `model` gains `sections` and `groups` (id, title, modes,
  pages); `index.html` renders sidebar from them; `check-webui` asserts every
  page sits in exactly one group, that gating never leaves an empty group,
  that every `advanced` widget is inside a collapsed card, and that the 390
  px render has no horizontal overflow.
- One Swift table next to `ChainFeature` in `Control/StageApplicability.swift`
  (`StageGroup`) drives `AppSection` / `ProcessingTab` ordering and the
  sidebar headers in `UI/RootViews.swift`; `ControlSchemaTests` gains a
  parity check that the schema's groups and the Swift table list the same
  stages in the same order.
- The rename table is applied in one commit to schema titles, `ProcessingTab`
  raw values, the inspector, and the manuals (the guide quotes labels
  verbatim -- `scripts/check-doc-anchors.py` catches broken headings).
- `[CONTROL]` keys reach the dashboard's Setup > Remote access page (today
  GUI Settings only); `ControlSchemaTests.deliberatelyUnexposed` shrinks.
- INI keys, REST routes and dispositions are untouched: a saved config or a
  script written against 0.50 keeps working.

### How we will know it is better

- Before coding: a card sort with two or three operators (index cards with
  the 31 page names; ask them to group and name the piles) and a think-aloud
  run of ten task cards on the proposed tree ("make the station louder",
  "change the PS text", "calibrate the exciter", "switch to FM Output", "why
  is Render Load red", "load last week's setup"). Adjust the tree from that,
  not from taste.
- After: clicks-to-complete for the same ten tasks, before vs after;
  `check-webui` green in all four modes and both viewports; the guide's
  table of contents mirrors the taxonomy.

### Phasing (each phase ships on its own, both front ends together)

1. **Structure** -- DONE 2026-09-11: `NavigationSection` / `StageGroup` in
   `StageApplicability.swift`, `schema.json` `model.sections`, both sidebars,
   Go menu Cmd-1..5, breadcrumbs, collapsible sections (dashboard) and
   groups (GUI), parity test + `check-webui` taxonomy assertions. The
   remote-access page stays with phase 4 (it needs a decision on exposing
   `[CONTROL]` over the API it configures).
2. **Labels** -- DONE 2026-09-11: Core -> Basics, MB Limiter -> Band Limiter, Final Stage -> Loudness and Output, in GUI + dashboard + strip + manuals (no screenshots in the docs to update).
3. **Disclosure** -- DONE 2026-09-11: `AdvancedControls.keys` (51 keys) ->
   schema `advanced` flags (parity test) -> dashboard `details.advcard`
   (harness checks placement + closed) and GUI `DisclosureGroup("Advanced")`
   in every stage tab.
4. **Aids** -- DONE 2026-09-11 (dashboard): settings search with jump +
   highlight, task shortcuts on the landing page, chain strip on the Sound
   overview, phone drawer + numeric slider twins; harness drives them. GUI
   counterpart: the sidebar's search field (`.searchable`) filters pages by
   label, group and section -- pages, not individual controls, since GUI
   controls are views, not schema entries.
5. **Operator round** -- the ten-task test on the result; fix what it finds.

Roughly one to two days each. Risk to watch: the parity rule (every change
lands in the GUI and the dashboard in the same commit) and label churn in the
manuals -- hence labels as their own phase, once, with the anchor checker.

## Audio-chain audit (external review of 0.50, 2026-09-11) -- verified findings and fix plan (target 0.60)

An external review of revision `aaf0521` (0.50 as released; `develop/v.060`
has carried only navigation work since) claimed seven P0 chain defects and two
P1 real-time defects. Every claim was re-checked against the code on
2026-09-11. **All nine hold.** Their practical weight differs a lot, so the
plan below orders them by benefit over risk rather than by the review's
numbering. The review itself is not in the repo (non-ASCII punctuation; keep it
out of the tree).

**Picking this up?** Read [docs/audit-handoff.md](audit-handoff.md) first:
what is done, what is left, the traps that cost time, and the working rules.
This section stays the record of findings and evidence.

### Verdicts

| # | Claim | Verdict | Where | Weight |
| --- | --- | --- | --- | --- |
| P0-1 | Live-apply configures the wideband AGC, phase rotator, bass clipper and the crossover resolve at the MPX rate | Confirmed for the three stages, refuted for the crossover resolve -- **FIXED 2026-09-11** | `MPXGenerator.applyRuntimeConfig` passes `sampleRate` at the four sites (about lines 1902, 1939, 2039, 2111); construction and `setSampleRate` pass `audioDomainSampleRate`; the HF clipper / HF limiter live-apply already use it (the 0.45 fix for the same class). `dual_rate_audio_domain_enabled` defaults to True, so the two rates differ by 4x. The crossover resolve is the exception: the CONSTRUCTOR resolves at the MPX rate too (it runs before the dual-rate properties are initialised), so the two paths agree and there is no parity break -- and its Nyquist clamp is unreachable anyway, the schema caps x4 at 12 kHz against a 23.8 kHz clamp. Left as it is, documented. | **High** for any live change on those pages: AGC time constants 4x slower, phase-rotator corner divided by 4, bass-clipper crossover and decimator divided by 4, until restart. Cold start and every baseline are untouched (no gate calls `applyRuntimeConfig`). |
| P0-2 | Bass / HF clipper transfer is discontinuous and non-monotonic | Confirmed | `DSP/AudioClippers.swift`: pass-through while `abs(x * drive) <= threshold`, otherwise `threshold * tanh(x * drive / threshold) / drive`. At the join the output drops from `threshold / drive` to `tanh(1) = 0.76` of it (24 %), then climbs back toward the same ceiling. | **High** for the stations it reaches: `bass_clipper_enabled` defaults True, so a fresh installation has it on, and `music_loud` is the one Format Profile that enables it (the other four switch it off; an earlier note here said "every profile", which was wrong). The HF clipper is off everywhere. The fix moves the composite: all four macOS baselines plus the Linux one. |
| P0-3 | Transient-aware hold is seeded by its lifetime maximum | Confirmed, and worse than claimed -- **FIXED 2026-09-11** | `MonoCompressor.processTransientAwareEnvelope`: `transientDriveObserved = max(transientDriveObserved, heldDrive)`, cleared only by `reset()`. The Advanced Dynamics copy keeps a decaying `heldDrive` -- the correct pattern. | **Low reach, total effect**: the stage is off by default, off in Verification.ini and in no profile -- but when ON it did not work at all. `transientDriveObserved` saturates to 1.0 within a few samples of `configure` no matter what is playing (rmsPower starts at 0, so the first non-silent sample has an unbounded peak-to-RMS ratio), so every hold window for the rest of the run opened at 0.94 instead of tracking the transient. Measured: bursts at 0.6 / 0.8 / 0.95 all held 0.94 before, and 0.19 / 0.48 / 0.69 after. |
| P0-4 | NaN / Inf are not sanitised at the encoder and Meter ingress | Confirmed, and worse than claimed -- **FIXED 2026-09-11** | No `isFinite` on the generator's input path (`renderFromInputInPlace`, the input ring); `AudioOutputEngine` guards only the meter snapshot values; `MeterAnalysis.processBlock` feeds raw samples to the DC tracker, FIR history and detectors. `MPXDecoder` guards itself (0.36). | **High, measured**: a 64-sample Inf burst leaves the composite 8.2 dB down and processed audio 12 dB down PERMANENTLY (8.2 dB at 0.5 s, still 8.2 dB at 7.5 s), output still finite and nothing logged -- it reads as "the station went quiet" with no cause. The Meter's own readouts (pilot, max deviation, MPX power) recovered on their own in the same probe, so its exposure is containment and visibility, not a reproduced sticky fault. |
| P0-5 | Unsynchronised cross-thread state | Confirmed for three of four -- **FIXED 2026-09-11** | `monitorConditioner.gainLinear` written on the main actor (`applyMonitorSettings`), read in `writeMonitorBlock` on the render thread; `ALSAMonitorOutput.setGain` vs its monitor thread; `meteringEnabled` plain Bool written by start/stop/UI, read in the render callback; `MonitorOutput.note` String written by the `.main` device observer. | **Medium**: the conditioner is a STRUCT the render thread mutates every block, so the control-side write was a race on a multi-field value, not just an unsynchronised Float. The note is the sharp one and it is NOT main-actor-only as first thought: on Linux the monitor THREAD writes it on device loss and the headless actor reads it, and a refcounted String read while being replaced can crash. `runningDevice` is refuted -- the monitor thread never touches it, every access is on the control thread. |
| P0-6 | The BS.412 limiter does not implement the labelled standard | Confirmed on every count -- **FIXED 2026-09-11** | `BS412PowerLimiter`: threshold `10^(dB/10)` against the normalised mean square where 1.0 is the configured deviation, so 0 dBr (a 19 kHz sine, `(19/75)^2 / 2 = -14.9 dB`) is not where the scale says; the default "-10 dB" limits at about **+4.9 dBr**. It observes `audioComposite` BEFORE pilot / RDS injection (the pilot alone is -9 dBr of the budget), the window is operator-selectable 30-90 s, history advances only while enabled, `configure()` keeps the gain state. | **Medium**: off by default, off in Verification.ini, enabled by no profile -- but the label promises a compliance the stage cannot deliver. `MeterAnalysis` already defines dBr correctly (uniform 60 s window, 19 kHz sine reference): a ready-made oracle. |
| P0-7 | AM "NRSC" uses the FM 75 us curve | Confirmed, and it reached three places not two -- **FIXED 2026-09-11** | `MPXGenerator` routes `am_preemphasis_us = 75` through the FM `PreemphasisFilter` (the analog `abs(1 + j w tau)` fit). NRSC-1 is the MODIFIED 75 us curve: zero at 2122 Hz, pole at 8700 Hz, +10 dB at 10 kHz. `AMOutputTests.nrscPreemphasisRisesWithFrequency` pins the plain curve at 1 dB (its 7.5 kHz point is +9.6 dB; NRSC-1 gives about +8.0). The monitor de-emphasises with the FM inverse. | **Medium**: AM Output only, no MPX baseline moves -- but the wrong curve reached the encoder filters, the monitor's inverse AND the calibration tone's pre-emphasis compensation, which the audit did not list. Error +3.66 dB at 10 kHz, +2.36 dB at 7.5 kHz relative to 1 kHz. |
| P1-1 | Live-apply does allocation-heavy rebuilds on the render thread | Confirmed | Both engines call `generator.applyRuntimeConfig` from the render thread after the try-lock mailbox. Inside: the BS.412 ring is reallocated on a window change, the multiband / Advanced Dynamics FIR splitters are redesigned on a crossover or enable change (four Kaiser kernels; the code comment calls it a "rare-operator-action allocation"), the composite clipper reconfigures, strings are lowercased. | **Medium, measured 2026-09-12**: a crossover PATCH costs one period at 50.5 % Render Load against a 30.9 % median on the Ryzen box at blocksize 4096 (about 4 ms of rebuild), zero xruns over twelve live PATCHes; it would not fit a 512-frame period. Harmless at the recommended block size; see F8. |
| P1-2 | RDS group generation takes locks, allocates and touches the clock on the audio thread | Confirmed | `buildGroup2`: `currentRTFrame` builds a String plus bytes, `writeSnapshot(rt:)` takes `snapshotLock` (blocking `withLock`) on every 2A group, `currentNowPlayingSnapshot` takes the Now Playing `NSLock`, every `buildGroup*` returns a fresh `[UInt8]`. `Date()` survives only in the CT cache refresh (background queue) and the RT `{time}` macro (justified, documented). | **Low to medium in practice**: one group every 87.7 ms, and zero xruns in every soak so far, including a Linux rig at 95 % render load. Real-time-correctness debt, not an observed fault. |

### Found while fixing, not in the review

- **`deviationKHzPeak` telemetry was wrong at any `mpx_deviation_khz` other
  than 75 -- FIXED 2026-09-12** (`DeviationReadout`, both engines,
  `DeviationReadoutTests` at 50 and 75 kHz; the maintainer chose to fix it).
  The record: The composite (subcarriers included) is scaled by
  `deviationScale = mpx_deviation_khz / 75`, so amplitude 1.0 is 75 kHz by
  construction -- which is what keeps pilot injection at 9 % of full
  deviation at any setting (measured: pilot amplitude 0.09 at 75, 0.06 at
  50). The meter computes `outputPeak * mpx_deviation_khz *
  modulationReferenceScale`, i.e. it multiplies by the configured deviation
  instead of 75, so at 50 kHz it would report 33 kHz for full modulation.
  Agrees exactly at the default 75, which is why nobody has seen it. The
  BS.412 work uses the 1.0 = 75 kHz convention throughout, and so does the
  readout now.
- **The monitor gain published to the audio thread started at unity** rather
  than at `monitor_gain_db`, so the first block ramped away from the
  configured level; on headless macOS, which does not re-apply the runtime
  config after start, it stayed at 0 dB. Introduced by F3 and caught in
  review the same day; fixed by seeding the atomic from
  `MonitorConditioner.publishedGainBitPattern` before anything can render,
  with a regression test at a non-unity startup level (the original
  concurrency test configured both sides at unity, where the mismatch is
  invisible).

### Where the review overreaches (not adopted)

- Its phases 3-6 (tuner / recording hardening, an encoder-to-IQ-to-tuner
  oracle, splitting `MPXGenerator` by orchestration concern, lifecycle
  protocols for every stage, a latency ledger) are a multi-release programme,
  not fixes for the findings above. The generator split in particular collides
  with the standing rule not to refactor `processFinalComposite`
  opportunistically. Parked; nothing below depends on them.
- The "versioned prepared-state handoff" for P1-1 and the full
  producer / consumer split for P1-2 re-architect the two best-tested parts of
  the product. Do the cheap 80 % first (below) and let the measurement decide
  whether the rest is needed.
- Its suggested NaN policy (Inf to a +/-1 sentinel) is fine; NaN and Inf both
  to silence is simpler and equally safe. Pick one in F2 and pin it.

### Fix plan (one commit per item, test first, docs in the same commit)

Order: the four zero-baseline fixes first, then the one composite-moving fix
on its own, then the two labelled-standard fixes, then the two measured
real-time items.

1. **F1 -- P0-1, rate domain. DONE 2026-09-11.** `applyRuntimeConfig` now
   binds `audioRate` / `mpxRate` at the top and every configure call names its
   domain; the AGC, phase rotator and bass clipper moved to the audio rate.
   `LiveApplyRateDomainTests` renders a generator built at A and live-applied
   to B against one built at B and requires bit-identical samples, for those
   three plus the HF stages and the pre-encode limiter as regression, with a
   boundary-disabled control case. Red/green checked: exactly the three fail
   on the pre-fix rate. Full suite 756 green, swiftlint clean,
   `--verify --baseline-strict` exit 0 (zero drift). AGENTS carries the rule.
2. **F2 -- P0-4, non-finite ingress. DONE 2026-09-11.** `sanitizeIngress`
   guards `processSampleDetailed`, `processAudioDomain` and
   `directMonitorStereo`; `MeterAnalysis.processBlock` scans and repairs into
   a preallocated block only on a fault. Non-finite becomes silence, finite
   values pass untouched, both sides count what they replaced.
   `NonFiniteIngressTests` pins containment at block edges AND recovery to
   within 1 dB of a clean render; three of its six tests fail on the
   unguarded code for the measured reason. Full suite 762 green, strict
   baseline unchanged, `--bench` chain cost 17.1-17.5 % (was 17.2 %), so the
   guard costs nothing measurable. Still open, deliberately: the operator
   never SEES the count -- no status note or dashboard field yet, and the
   Meter does not drop its validity flags on a fault. Both are follow-ups,
   not blockers, because nothing sticks any more.
3. **F3 -- P0-5, ownership. DONE 2026-09-11.** The monitor level travels as
   a Float bit pattern in a `ManagedAtomic` owned by each player
   (`AudioOutputEngine`, `ALSAMonitorOutput`) and is adopted by the thread
   that runs `MonitorConditioner`, which now ramps over 10 ms instead of
   stepping; `configure` still sets the level outright so engine start does
   not fade in. `meteringEnabled` is a `ManagedAtomic<Bool>`. Both monitor
   players keep their note in an `OSAllocatedUnfairLock<String?>`, taken off
   the render path (the Linux monitor thread takes it only on the device-loss
   failure line, immediately before stopping). Four new
   `MonitorConditionerTests` pin the ramp shape, monotonicity, settling and
   NaN rejection. Full suite 771 green, strict baseline unchanged, swiftlint
   clean, Linux target compiled in a container (swift:noble, exit 0), and a
   concurrent hand-off test passes under `--sanitize=thread`. `runningDevice`
   needed no change -- see the refutation in the table above. Note the
   limit of that TSAN evidence: the suite is headless by rule, so it
   exercises the hand-off PATTERN, not a live render thread; the engine-
   level check belongs to `scripts/smoke-live.sh` at release time.
4. **F4 -- P0-3, transient hold. DONE 2026-09-11.** `MonoCompressor` keeps a
   decaying `heldDrive` for processing and `transientDriveObserved` as a
   diagnostic peak only, matching `AdvancedDynamicsLeveler`; the decay is a
   time constant (0.337 ms, which IS 0.94 per sample at 48 kHz, so the
   production domain is unchanged) instead of a fixed per-sample factor.
   `TransientHoldTests` pins that the hold tracks transient size, that a
   modest transient does not open a maximum hold, that it expires, and that
   it behaves the same at 48 / 96 / 192 kHz; two of the five fail on the old
   code reading 0.94 flat. Full suite 767 green, strict baseline unchanged,
   swiftlint clean. Follow-ups noted, neither blocking: the drive still
   saturates for the first few milliseconds after `configure` because the RMS
   detector starts at zero (harmless now the hold decays, but it makes
   `MultibandPhase2Tests`' `transientDriveObserved > 0.10` assertion
   vacuous), and `AdvancedDynamicsLeveler` still used the rate-dependent
   0.94 -- DONE 2026-09-12 as `0.94^(48000/sr)`, exactly 0.94 at the 48 kHz
   domain so the armed gates see the same numbers, a time constant at any
   other rate (`AdvancedDynamicsHoldTests`).
5. **F5 -- P0-2, band waveshaper. BUILT AND MEASURED 2026-09-12, landing
   plan below.** The shared curve is in the working tree with nine
   property tests (`BandWaveshaperTests`: continuity in value and slope at
   the join, monotonicity, odd symmetry, untouched below the knee, the same
   asymptote so "Threshold" keeps its meaning, finite output, batched path
   equals scalar, and one confirming the old curve really did step down
   24 %). Two findings from measuring it change how it has to land:

   - **No strict gate reported drift -- but nothing was zero.** `--verify`,
     `--verify-presets` and `--verify-hf-transients` all pass with the new
     curve; every movement stayed inside tolerance, some of it barely
     (`transient_push` deviation -0.25 kHz at 83 % of tolerance; on the long
     sweep `vocal_sibilant` true-peak overshoot at 96 %). The bass clipper (default -3 dB / drive 1.5 /
     150 Hz, enabled by `music_loud` and by the factory default) does not
     engage hard enough in any
     verification scenario to register. Landing is therefore low-risk -- and
     the gates are blind to this stage, which is its own finding (step 3).
   - **Measured through the REAL stage, the knee is not a trade -- it is a
     clear win, and the wide knee wins.** A bare-curve sweep (no decimator)
     had suggested a narrow knee traded light-drive coloration for a
     moderate-drive gain; that was an artefact of leaving the stage's own
     filters out. Through the 4x-oversampled `BassClipper` at the shipped
     point, THD of a 113 Hz tone: old curve -19.6 dB at moderate drive
     (0.65), knee 0.5 -27.5, knee 0.9 **-34.4**; at light drive all read
     -34.0; at hard drive (0.95) old -16.6, 0.5 -19.1, 0.9 -18.0; at drive
     2.5 old -16.5, 0.5 -18.4, 0.9 -17.3. The old curve cut a NOTCH into
     the crest of every over-threshold peak, and moderate drive -- a kick a
     little over threshold, the regime a bass clipper lives in -- is where
     that hurt most. The widest knee removes the notch with the least added
     curvature: never worse than the old curve anywhere, 15 dB better where
     it matters, about a decibel behind the narrow knee only under 2x
     overdrive. `defaultKnee = 0.9` (a knee about 1 dB wide). Also measured
     through the stage: the old curve's output DIPS 0.16 dB as input rises
     through threshold (the 24 % bare-curve step, smeared by the decimator),
     the new one 0.00; broadband splatter above 15 kHz -55.0 vs -56.6 dB.

   Landing plan, each step its own commit:

   1. **Evidence the gates do not have.** A chain-level monotonicity test
      through the REAL oversampled `BassClipper`: sweep a kick-like burst's
      level across the threshold and require output peak to be monotonic in
      input peak. This is the operator-meaningful statement of P0-2 --
      "louder in never means quieter out" -- and the old curve fails it
      exactly at threshold, where a kick's peak lives. Plus alias energy
      (energy folded down through the 4x decimator, old vs new) and a
      single-burst broadband-spill probe. Steady-state THD alone under-
      states a discontinuity's cost; these see it.
   2. **Pick `k` objectively. DONE 2026-09-12: 0.9.** No profile overrides
      the clipper's threshold / drive, so there is one shipped operating
      point; swept 0.5-0.9 through the real stage against the old curve
      (table above). The maintainer's listening pass (step 5) can still
      move it.
   3. **Land** the curve, its tests, the chain-level test, and docs
      (ARCHITECTURE, settings reference for the Threshold / Drive wording,
      CHANGELOG, AGENTS). No baseline recapture -- measured, none moves.
      Red / green: the chain-level monotonicity test fails on the old
      curve.
   4. **Close the coverage hole. DONE 2026-09-12.** `bass_kick` in the
      scenario table: a 55 Hz kick decaying over 80 ms every half second
      with a little 110 Hz body. Chosen by probing candidates through the
      full Verification.ini chain with a same-delay comparison (clipper at
      shipped settings vs settings that cannot clip -- toggling the stage
      itself shifts the whole composite by its latency and fakes a
      difference): the kick engages the clipper about 1.7x harder than
      `wide_bass`, and the 0.60 curve change moves its composite peak by
      1.1 dB and RMS by 0.2 dB against a 0.10 dB peak tolerance, so the
      record is a real guard. Only `default.json` gains a record -- the
      preset and long sweeps filter scenarios by name and do not include
      it; the Linux `default-linux-x86_64.json` gains one through the
      `linux-baseline.yml` workflow, which means one red Linux CI run
      between the push and the artifact commit, as AGENTS documents.
      Learned on the way: the strict compare grades an unseen scenario as
      WARN (`<new>` finding), so the capture must ship with the scenario.
      Landed as d9c852e (scenario + four macOS baselines) and 0fa68b9 (the
      x86_64 artifact from workflow run 34692757580); the Linux CI job was
      red for that one push, as documented.
   5. **Listen** (maintainer): `docs/test-playlist.md` bass tracks on a
      RELEASE build, old vs new. If it sounds worse the knee moves, not the
      curve -- the discontinuity is not coming back.

   Effort: steps 1-3 about a day, step 4 half a day plus the Linux capture,
   step 5 yours. `HFClipper` shares the curve and is off in every profile,
   so nothing shipped changes there.

6. **F6 -- P0-7, NRSC-1. DONE 2026-09-11.** `PreemphasisDesign.nrsc(
   sampleRate:)` fits the modified 75 us curve (zero 2122 Hz, pole 8700 Hz)
   the same least-squares way the FM design is fitted -- a pre-warped
   bilinear was 1.06 dB off at 10 kHz on a 48 kHz domain, measured, so the
   fit is not optional. Rather than two more filter TYPES as the audit
   proposed, the standard is named at the call site through
   `PreemphasisCurve` (`.fm(tauUS:)` / `.nrsc` / `.none`): the failure mode
   was a silent integer argument, not a shared biquad body, and three call
   sites had it wrong -- the encoder filters, the monitor's inverse and the
   calibration tone's compensation, which the audit missed. `NRSCPreemphasis
   Tests` (7) hold the design to the standard's table at every rate, pin the
   inverse cascade flat, prove the curve is NOT the FM one, and pin FM's own
   path bit-identical. `AMOutputTests.nrscPreemphasisRisesWithFrequency`
   asserted the FM figures and called them NRSC; it now asserts the standard
   and fails if AM goes back to the FM curve. 2026-09-11, later the same
   day: NRSC-1-C-2024 was obtained and now sits in `standards/`, and the
   tests assert against its Table 1 verbatim -- all 23 points, magnitude
   AND phase -- instead of against our own expression. The published
   table agrees with the one-zero/one-pole definition to 0.005 dB and
   0.05 deg, so the expression was right; the tests are now anchored to
   the document rather than to us.
   `MonitorConditionerTests.amMonitorRemovesTheNRSCCurve` applied and removed
   the SAME curve, so it was flat whatever happened; it now applies NRSC and
   has a guard proving the FM inverse would not be flat. Full suite 780
   green, strict baseline unchanged, swiftlint clean.
7. **F7 -- P0-6, BS.412. DONE 2026-09-11, corrected the same day.** The
   first pass fixed the MEASUREMENT (complete multiplex, dBr, fixed 60 s,
   always running) but its actuator only converged eventually: from unity a
   steady +6.02 dBr input still averaged about +2.35 dBr across its first
   completed window and rebounded across the ceiling while settling, and the
   full-chain test missed it by checking only the settled tail. Since the
   Recommendation says ANY interval of 60 s, that was not compliance.
   `DSP/BS412Power.swift` now separates three concerns: the reporting meter
   (unchanged in what it measures, plus `windowValid` / `secondsObserved`,
   and it no longer pauses for Test Tone), a FEED-FORWARD `BS412Rider` that
   predicts from pre-control audio so it cannot chase its own gain, and a
   `BS412ComplianceGuard` that is an energy invariant rather than a smoother
   -- it holds the rolling window at or below `ceiling * windowSamples`,
   solves the per-sample audio gain as an interval, and accounts the exact
   emitted sample so the cross term cannot hide an overage. Unobserved slots
   carry a subcarrier reserve of `(pilotPeak + rdsPeak)^2 / 2` so an early
   burst cannot spend budget that later pilot-only samples need. Test Tone
   now measures but suspends control, and says so. Eight status fields reach
   `/api/meters`, the dashboard and the GUI together. Tests check EVERY
   completed window through transitions, not an endpoint; with the guard
   neutered the cross-term case overshoots 2.9 dB and the quiet-to-hot step
   0.06 dB, so both layers earn their place. Full suite 798 green,
   MPXPRIME_DEEP BS.412 suite 19 green, strict baseline unchanged, swiftlint
   and check-webui clean. Remaining gap: no live on-air smoke yet (needs the
   rig and an off-air Meter comparison).

8. **F8 -- P1-1, measured.** On the Ryzen box: PATCH a crossover, the clipper
   oversampling and (until F7) the BS.412 window while sampling xruns and
   Render Load. Then the cheap fixes: preallocate the BS.412 ring once, design
   FIR kernels producer-side as a prepared field of `RuntimeConfig` (pure
   functions of crossovers and rate), lowercase strings in
   `makeRuntimeConfig`. Acceptance: `scripts/ab-music-live.sh` already asserts
   "every toggle applied live without a spike"; add the crossover toggle to it.
   **Measured 2026-09-12** (Ryzen 5 PRO 2400GE, 192 kHz, blocksize 4096,
   Advanced Dynamics on, quiet input, `/api/meters/stream` at 30 Hz, twelve
   live PATCHes in 20 s): **zero xruns**. Render Load median 30.9 %, and the
   worst period of the run was the crossover redesign at **50.5 %** (about
   +20 points over the median, roughly 4 ms of one 21.3 ms period); the
   BS.412 enable / disable peaked at 42 % and the bass clipper toggle at
   38 %; the multiband enable toggle did not stand out. Reading: at 4096 the
   rebuild is harmless with headroom to spare, but a 4 ms rebuild does not
   fit a 512-frame period (2.7 ms) -- an operator who runs small blocks and
   moves a crossover on air would drop a buffer. Keep 4096 the Linux
   recommendation; the producer-side FIR design stays the fix IF small
   blocks on air become a requirement. Not started.
9. **F9 -- P1-2, measured.** Remove the two locks from the group build:
   publish the RT segment / PS index as an atomic the API side resolves to
   text, consume the Now Playing snapshot through a preallocated double buffer
   with a sequence counter (never releasing a Swift object on the render
   thread), reuse one fixed 104-bit buffer for the group (make
   `RDSBitBufferReuseTests` prove storage reuse). The pre-encoded group bank
   only if F8's instrumentation shows deadline misses.

Effort: F1-F4 about a day together; F5 two to three days including listening
and the Linux recapture; F6 a day; F7 two to three days; F8 / F9 half a day of
measurement each, then one to three days depending on what it shows. Every
commit: fast suite, swiftlint, `--verify --baseline-strict` unchanged (F5
excepted, deliberately), CHANGELOG 0.60 bullet.

## HF transients (hi-hats / cymbals) -- open remainders of the 2026-08-29 campaign

The dominant cause (final-stage order; the 1x shaper clipped before the
composite clipper) is fixed and gated by `--verify-hf-transients`; the HF
limiter is default-on in every profile. Still open, lowest effort first:

- `mpx_clipper_cancel_audio` low-band-only variant -- measured no effect once
  the HF clipper is out of the path; low priority.
- Band-limit the HF clipper's residual (opt-in stage only now).
- Pre-encode limiter: half-cosine attack + HF-only gain path (see
  enterprise item B5 below).
- `hf_limiter_stereo_link` -- Orban prefers UN-linked fast HF limiters; A/B
  against the image metrics.
- L/R 15-19 kHz residual of the pre-encode limiter's tanh ceiling (the last
  L/R nonlinearity sits after the 15 kHz FIR, Orban band-limits the
  "clippings" of that stage, US 6,337,999): gate = 15-19 kHz energy at the
  encoder input on dense program; the fix, if it shows, is a differential /
  band-limited residual, NOT a post-limiter LPF.
- Enhancer placement: every vendor places the bass enhancer BEFORE the
  multiband so it controls the energy it adds; ours sits after (mitigated by
  the bass clipper + stereo-image protection). Step 7 below.
- Dynamic pre-emphasis load manager (an HF-excess sidechain that relaxes a
  little pre-emphasis gain ahead of the limiter on bright transients, never
  switching the curve): the unwired 0.44 attempt was removed in 0.45; only
  worth revisiting through the `--verify-hf-transients` gate.
- Stereo Tool's recipe for bright program (no HF gain rider; raise the HF
  compressor / lower the HF limiter) -- try as a Music - Loud preset tweak.
- Advanced Dynamics on hats: ~2 dB of its cost is gain structure (per-profile
  AD tuning), ~2 dB intrinsic to leveling burst HF with the current
  detector / smoother; every single-knob hypothesis is refuted (offset, speed,
  transient weight, target, clipper). The default flip stays BLOCKED on a
  go / no-go: deeper DSP work (burst-material leveling, likely band coupling,
  Step 7) or a maintainer-signed lower AD threshold informed by the
  real-music `--verify-program-ab` results.

## Chain design review (approved 2026-08-30) -- remaining steps

Steps 1-4a (stereo polarity, receiver-side HF response, multiband splitter,
stereo-guard share), the enterprise items A1 / A1b / B1 / B2, the FIR-seeding
and processed-audio-rate defects are shipped; CHANGELOG has the measurements.
Left, in the approved order:

- **Step 0 -- measurement first (remaining):** end-to-end latency
  (`totalChainDelaySamples`, impulse test, `--verify` + `/api/status`);
  protection in dB re subcarrier (pilot / RDS / 38 kHz / SCA); RDS BLER under
  load; THD / SMPTE / CCIF of decoded audio; BS.1770 + BS.412 on the verifier
  output; verifier <-> Meter cross-check; stale tests moved to the 48 kHz
  audio rate (`MultibandFIRSplitterTests`, `EncoderBandwidthTests`,
  `DualRateHFResponseTests` tolerances). A WORKING program-separation metric
  (the decoded hard-panned side/mid column read -114 dB and was removed).
- **Step 4b -- remaining clipper items:** 1-2 POCS re-projection passes
  (measure the bound probe and the hot-config ride with them); final limiter
  150-200 ms release + GR > 0.5 dB telemetry warning once the ride is
  understood; knee default -0.5 / -0.3 dB after an HF-SINAD A/B; bandwidth FIR
  53 kHz / 2 kHz transition. Lead: the clipper's own 2 ms look-ahead cuts the
  final ride to 0.08 dB on the hot chain -- evaluate enabling it in Music -
  Loud with the HF gate (it trades clipper density for a gain ride).
- **Step 5 -- dynamics practice gaps (remaining):** pre-encode limiter
  full-band look-ahead with attack ~ look-ahead, partial-link experiment vs
  the hard-panned case (B5).
- **Step 6 -- budget hygiene + defaults:** margin 0.02 -> 0.005,
  `limitThreshold` 0.99, reservation from the delayed subcarriers, pilot
  default 9 % (new installs), document 3 kHz RDS as the field choice. The
  Thimeo-style post-injection pilot-aware clipper (~0.5-1 dB realised) waits
  until steps 4-5 are measured.
- **Step 7 -- optional structure:** Omnia-style band sync (clamp gain
  disparity to a master band), switchable PrimeBass placement (enhancers
  BEFORE the multiband), speech detector easing clipper drive, per-band
  `BandLimiter` on `music_loud` as the density path before more clipping.
- Hardware confirmation of the Step 1 polarity fix on a car radio (operator).

### Enterprise-parity roadmap (approved 2026-08-30) -- remaining items

Rating vs Orban 8600 / Omnia.11 / Stereo Tool: encoder side professional-grade;
processor side mid-tier with untuned dynamics. Payoff per effort, each item
measured before it is heard:

- **A2** POCS re-projection passes (`mpx_clipper_iterations` 1-3, cascade of
  `CompositeClipperPass`, delay summed into `recomputeSubcarrierDelay`);
  default 1, Music - Loud -> 2 after the table.
- **B4** per-band `BandLimiter` as the density path on Music - Loud (5 ms hold,
  HF tilt, profile fields).
- **B3** Omnia-style band sync (`multiband_sync_db`, clamp target GR to master
  +/- D) -- also the cure for the Advanced Dynamics crossover-skirt lift.
- **B5** pre-encode limiter attack = look-ahead / 4, sliding-window-max
  detector (the A1b detector, applied to the L/R limiter), look-ahead 2-3 ms.
- **A3** clipper knee -0.5 / -0.3, bandwidth FIR 53 / 2 kHz, margin 0.005 +
  `limitThreshold` 0.99, pilot 9 % for new installs.
- **B6** speech / music detector easing clipper drive (`mpx_speech_drive_ease_db`).
- **C** measurement the vendors publish (Step 0 list above).
- **B7** clip-detection metric only (no declipper this cycle); **D** optional
  structure (enhancer placement, AGC window, density macro, x1 120 Hz).
- Relabel the receiver report's "Pilot ... Phase 45.4 deg" (it is the pilot's
  absolute phase at the analysis window, not pilot-to-RDS); explain the 10 kHz
  PLL-path separation (~51-54 dB vs 95 dB at 1 / 14 kHz -- a decoder-PLL
  artefact); give `processEncoderHFGuard` named constants + a test.

## Meter -- open items

The 2026-08-31 Meter audit and the RTL-SDR bench are closed; their history is
in CHANGELOG. The open remainder (tuner channel-filter fix blocked on a second
dongle, the Meter-integrated calibration loop, the maintainer's hardware
validation queue, parked items) lives in [meter-roadmap.md](meter-roadmap.md).

## Next up

1. **Anti-aliased clipping kernel (US 6,937,912).** Phase A/B landed opt-in
   (`pre_encode_bandlimited_residual_enabled`). Remaining: A/B real program
   with it on, decide whether any loud preset enables it; optional Phase C
   applies the primitive to `softClipSafety`.
2. **Tune/validate composite clipper look-ahead.** `mpx_clipper_lookahead_ms`
   shipped; dense real-program A/B at 0.5 / 1 / 2 ms, verify pilot/RDS guard
   cleanliness, decide loud-preset default (see Step 4b: it also removes the
   final-limiter ride). Capture via `MPXPRIME_AUDIT_CAPTURE=1`.
3. **Smoke-test pass.** Live-apply vs restart-required on difficult real
   material; catch transients / clicks / dropouts on toggle. New RDS live-apply
   paths (PI / PTY / flags / AF / scheduler) need real-receiver checks beyond
   the bit-stream tests.

## Operating modes: one four-way choice, stages gated per mode -- LANDED 2026-09-05

Operator direction (issues list, 2026-09-05): the output shape should be ONE
choice with four values, and every control, stage and side service should
exist only where it has a function in that mode. Web and GUI on par.

**Landed:** `operating_mode` (`mpx` | `fm` | `hd` | `am`) with load-time
migration from the two booleans and REST aliases for them; the `ChainFeature`
applicability table driving the engine, the GUI sidebar, the dashboard schema
(page- and widget-level `modes`) and the tests; RDS, the Now Playing poller and
SSB inert outside MPX; the AM Output mode (mono sum, NRSC pre-emphasis and
band limit, asymmetric peaks through the existing peak guard); the dashboard's
bypass confirmation removed; and an unrecognised CLI argument turned into a
usage error. `ModeGatingTests` + `AMOutputTests` pin it; all five gates
zero-drift.

**Follow-up 2026-09-06 (same operator report, "still an issue"):** the
dashboard's landing page was throwing in every mode -- a helper deleted during
the mode work with two call sites left behind, invisible to every test we had.
Fixed, plus the Overview grid / signal chain / Headroom card gating and four
more controls that do nothing in a mode. The durable part is
`scripts/check-webui.sh`: the dashboard is now RENDERED in CI, in all four
modes, and a stale reference or an out-of-mode control fails the build.

**Remaining from the operator's list:**

- **AM verification against hardware.** The mode is measured (mono sum, the
  75 us curve, the band limit, both peak cases) but has never been checked on
  a modulation monitor with a real AM transmitter. Until then it is a
  first implementation, and the docs say so.
- **AM processing tuning.** The chain's defaults are FM-shaped: an AM Format
  Profile (denser, narrower, heavier low-mid control, no HF sizzle) is the
  natural follow-up, and wants the same treatment the digital profile is
  waiting for.
- **The Advanced page is deliberately un-gated.** It is the raw INI editor and
  shows every key in every mode by design; a mode-aware view there would hide
  keys an operator may need to fix by hand.
- **A "what would this mode change?" preview** before a restart-class mode
  switch (the operator sees the new controls only after the restart today).

## Digital delivery target for Processed Audio (streaming / DAB) -- CORE LANDED 2026-09-05

**Landed:** the two INI keys (`processed_audio_target`,
`processed_audio_ceiling_dbtp`), the one-place resolver
(`AppConfig.processedAudioDigitalDelivery`, seeded into `MPXGenerator` at
init), all five generator differences in the table below, the segmented
Delivery control plus the ceiling slider in BOTH front ends, and seven tests
in `ProcessedAudioOutputTests`. All four strict baselines zero-drift, full
suite green. Two defects the tests found on the way: the pre-encode limiter's
decimator carried a hard-coded 15 kHz band limit that survived the target
switch, and mapping the limiter's THRESHOLD (rather than its ceiling) onto the
dBTP target read 1.3 dB hot -- the ceiling rule is now one shared function.

**Still open from this plan:**

- **BS.1770-4 loudness metering** (momentary / short-term / integrated LUFS +
  true-peak max) on the Monitoring dashboard and `/api/meters`, with the EBU
  Tech 3341 gating vectors as its test. Without it the operator sets loudness
  by the AGC target and an external meter.
- **A "Digital -- Streaming / DAB" Format Profile** (AGC target for -16 LUFS
  music, light multiband, PrimeBass off), which wants the meter first so the
  target can be verified rather than asserted.
- **A separate digital clipper drive** defaulting to off (Thimeo's
  "Web/HD/DAB clipper drive" model). Today the final clipper is simply
  inactive for the digital target, which is the right default but not the
  full control.
- **Codec conditioning** stays out of scope, gated on the measurement
  described under "Codec conditioning prior art".

The rest of this section is the original plan and the research behind it.

## Digital delivery target -- original plan (2026-09-05)

**Question asked:** do we need a special mode for the audio processor without
MPX, so the 15 kHz filtering and every other FM-specific stage can be switched
off? **Answer: yes, but as a delivery TARGET inside the existing Processed Audio
operating mode, not a fourth operating mode.** Processed Audio already skips the
composite stages; what it still does is shaped for an FM stereo coder. The
operator should not have to know which six keys are FM-only, and the UI must be
able to hide the FM-only controls, so the target has to be one explicit choice
that the mode resolver, the generator and both front ends all read.

### What Processed Audio still does that is FM-specific (code facts)

| Stage / behaviour | Where | FM reason | Digital verdict |
|---|---|---|---|
| Program lowpass clamped to 16 kHz (`program_lowpass_hz`, `AppConfig.validate`) and the encoder bandwidth FIR / Butterworth at that frequency (`encoderProgramFIR` / `encoderProgramLP`, ahead of pre-emphasis) | `AppConfig.swift` clamp; `MPXGenerator.processAudioDomain` "Final encoder-facing bandwidth guard" | 15 kHz audio bandwidth of the FM multiplex (pilot at 19 kHz) | Bypass or widen to 20 kHz: DAB+ and stream codecs carry 16-20 kHz |
| Encoder HF guard (`processEncoderHFGuard`, fixed 2 dB HF duck) | `MPXGenerator.swift:1039` -- ALREADY off when `preemphasis_us = 0` | protects receiver-side HF separation against composite-clipper IM | Nothing to do once pre-emphasis is forced off |
| Pre-emphasis 50/75 us + HF limiter (rides the boost only) + HF clipper | `PreemphasisFilter`, `HFLimiter`, `HFClipper` | FM transmission curve | Force `preemphasis_us = 0`; the HF limiter then has zero boost to ride (idle); hide the pre-emphasis picker and the HF Limiter / Clipper tab |
| Stereo-image protector (`configureStereoImage`, `processStereoImageStage`: limits side/mid expansion) | `MPXGenerator.swift` | deviation and multipath on FM | Bypass (digital carries the full image); Mono Bass stays available as a taste control |
| Output make-up normalises the limiter ceiling to full scale (peaks ~0 dBFS) | `audioOnlyOutputMakeup` | analog / AES3 feed to a coder with its own clipper | Replace by a true-peak CEILING (default -1 dBTP; EBU R128 s1 / streaming platforms); no normalisation |
| Optional processed-audio final clipper (`processed_audio_coder_has_clipper = False`) | `processedAudioFinalClipper` | FM loudness when the coder has no clipper | Keep the control, give digital its own drive value defaulting to OFF (Thimeo ships a separate "Web/HD/DAB clipper drive" because streams want far less clipping than FM); the true-peak limiter is the peak controller |
| AGC target / multiband drive / Format Profiles tuned for FM density | `PresetCatalog` | competitive FM loudness | New profile "Digital -- Streaming / DAB": gentler drive, AGC target chosen for a LUFS goal, PrimeBass off |
| Pre-encode limiter: 4x oversampled true-peak with tanh ceiling, look-ahead | `StereoLinkedOversampledPeakLimiter` | generic | KEEP -- it is already a true-peak limiter; its threshold becomes the ceiling |
| No loudness readout (AGC shows dB K-weighted "dBLU") | `WidebandAGCRider` uses `KWeightingFilter` | FM meters are deviation | Add EBU R128 momentary / short-term / integrated LUFS + true-peak max readouts for this target (reuse `KWeightingFilter`; gating per ITU-R BS.1770-4) |

Everything else in the audio-domain chain (input gain, HPF, AGC, PEQ,
multiband / Advanced Dynamics, expander, MB limiter, PrimeBass, bass / DC
clippers, mono bass) is codec-agnostic and stays.

### How the established processors do it (web research 2026-09-05)

Checked against Orban, Telos/Omnia, Thimeo and the loudness recommendations,
to see whether "a target inside Processed Audio" is the right shape and what
the defaults should be. Sources at the end of this subsection.

- **Everyone splits the chain, and they split it late.** Orban's 8600 runs the
  digital-radio path from after the AGC, giving the HD chain its own EQ and
  five-band settings, then its own peak limiter; the analog FM path keeps
  pre-emphasis, the composite limiter and composite clipping, which the HD
  path does not have at all. Omnia.11 describes the same shape as a "parallel
  HD processing path with its own final mixer and look-ahead limiter".
  CONFIRMS our design: everything up to the multiband is codec-agnostic and
  shared; what changes is the final stage.
- **The digital path is 20 kHz and flat.** Orban states 20 kHz audio bandwidth
  and no pre-emphasis on the HD chain. CONFIRMS lifting the 16 kHz clamp and
  forcing `preemphasis_us = 0`.
- **Peak control becomes true-peak look-ahead limiting, not clipping.** Orban
  predicts true peak "to an accuracy of better than 0.5 dB" on the HD path to
  protect the D/A in playback devices; Omnia sells "ultra-low-distortion
  look-ahead final limiting optimized for HD and other lossy codecs".
  CONFIRMS reusing our existing 4x oversampled true-peak limiter as the
  ceiling, rather than the FM-style clipper.
- **CORRECTION -- do not hide the final clipper, give it a lower drive.**
  Thimeo exposes a separate "Web/HD/DAB clipper drive" precisely because
  "audio for FM needs to be clipped much harder than streams". So digital gets
  its own drive value, defaulting to OFF, instead of the control disappearing:
  an operator who wants a little density on a stream should not have to switch
  the delivery target to get it.
- **CORRECTION -- the ceiling default needs a codec caveat.** -1 dBTP is the
  common recommendation (EBU R128, AES TD1008, and every major streaming
  platform), so it stays our default, but EBU production guidance asks for
  -2 dBTP ahead of a data-reduction codec, because lossy encoding pushes
  inter-sample peaks up. The manual must say: -1 for a linear feed, -2 when
  the next box is a DAB+ or AAC encoder.
- **CORRECTION -- name the loudness targets properly.** AES TD1008 recommends
  DELIVERING -16 LUFS for music, -18 for speech, -17 where one chain carries
  both; EBU R128 broadcast (the DAB case in Europe) is -23 LUFS. The -14 LUFS
  figure that circulates for Spotify / YouTube / Tidal is a PLAYBACK
  normalisation level, not a delivery spec, and the Digital Format Profile
  should not chase it. Profile aims at -16 with the AGC target, and the manual
  gives -23 for EBU-compliant DAB.
- **The codec-conditioning method is free to use** (patent check 2026-09-05,
  detail under "Codec conditioning prior art" in the guardrails): the one
  filing that claims simulate-the-codec-then-precondition was **never
  granted** anywhere, so there is no obstacle if we ever build it -- and its
  publication is prior art against anyone else claiming it now.
- **GAP we are not closing in v1: codec conditioning.** All three vendors
  pre-condition audio for the encoder -- Omnia's "Sensus" analyses content and
  adapts processing for the target encoder, Thimeo has a "Prepare for lossy
  compression (MP3/AAC/OGG)" mode built on a pre/de-emphasis pair around the
  codec, and the published patent art describes estimating quantisation
  artifacts before encoding. We do none of this, and it is a genuine
  difference in kind, not degree. v1 scope stays: leave the codec real
  headroom (the true-peak ceiling) and stop clipping into it. Record
  codec conditioning as a separate future item, gated on being able to
  MEASURE artifacts (encode the verifier scenarios through an AAC encoder and
  score the decode) rather than shipping a knob on faith.
- **Deliberate limitation to document: no simultaneous FM + digital.** The
  vendors run both chains at once, with up to 12 s of diversity delay to
  align an HD1 stream against the analog signal. One MPX Prime instance emits
  one thing; an operator who needs both runs two instances. Diversity delay is
  out of scope.

Sources: Orban OPTIMOD 8600 in-depth description
(<https://www.orban.com/indepth-optimodfm8600>), Telos Alliance Omnia.11
(<https://telosalliance.com/radio-processing/radio-processors/omnia11>) and
Omnia VOLT HD-Pro (<https://bgs.cc/omnia-volt-hd-pro/>), Thimeo Stereo Tool
documentation on limiting and clipping
(<https://www.thimeo.com/documentation/limiting_and_clipping.html>),
EBU R 128 (<https://tech.ebu.ch/docs/r/r128.pdf>), AES TD1008
(<https://aes2.org/wp-content/uploads/2024/01/20210924_TD1008_v3.13.pdf>),
Telos Alliance on streaming loudness
(<https://docs.telosalliance.com/docs/understanding-loudness-for-streaming-audio>).

### Design

- **One new INI key** `processed_audio_target = fm_coder | digital` (`[INTERFACES]`,
  default `fm_coder` so every existing INI is unchanged; restart-class like the
  operating mode because it changes filtering and the make-up). **One new level
  key** `processed_audio_ceiling_dbtp` (`[MPX]`, default -1.0, range -6..0,
  live-apply; only read for the digital target -- -1 dBTP matches EBU R128 /
  AES TD1008 / the streaming platforms, and the manual tells operators to use
  -2 when the next box is a DAB+ or AAC encoder). Both get a schema.json widget
  (`ControlSchemaTests`), and `installationPreservedKeysBySection` gains the
  target (it is wiring, like the mode).
- **Resolver**: `AppConfig.resolvedOutputMode` stays three-valued; a new
  `AppConfig.processedAudioTarget` enum + `MPXGenerator.digitalDelivery: Bool`
  seeded at init from the config (same seeding rule as `audioOutputOnly`, so
  the verifier and the Linux ALSA engine see it too). No new
  `AudioOutputMode` case: the engines already run the audio-only render path.
- **Generator, when digital**: `effectiveProgramLowpassHz` / `effectiveEncoderLowpassHz`
  get a `digital` argument that lifts the 16 kHz clamp to `min(configured, 0.45 x
  audioDomainRate)` (20 kHz at 48 kHz) -- or bypasses the encoder FIR entirely
  when `program_lowpass_hz` >= 20 kHz; `preemphasisUS` forced 0 in the derived
  runtime config (the INI value is kept for when the operator switches back);
  `processStereoImageStage` bypassed; `audioOnlyOutputMakeup` returns
  `outputGain` only and the pre-encode limiter threshold is set from
  `processed_audio_ceiling_dbtp` (0.891 for -1 dBTP; the limiter is already
  true-peak so the ceiling is honoured on inter-sample peaks -- pin it with a
  4x-oversampled measurement in the test); final clipper inactive.
- **Metering**: new `LoudnessMeter` in `DSP/` (K-weighting -> 400 ms / 3 s
  windows -> BS.1770-4 absolute -70 LUFS and relative -10 LU gating ->
  integrated; plus true-peak max from the existing 4x path) fed from the
  audio-only render path; published through `LiveTelemetry` (`@Observable`,
  Canvas readout) and `/api/meters` (`lufsMomentary`, `lufsShortTerm`,
  `lufsIntegrated`, `truePeakDBTP`), with a Reset. Shown on the Monitoring
  dashboard in place of the MOD meter when the target is digital (the
  composite readouts are already hidden in Processed Audio).
- **UI (both front ends, same change)**: Audio I/O -> Operating Mode card gains
  a "Delivery" segmented control under Processed Audio: "FM stereo coder" /
  "Digital (streaming / DAB)". Digital hides the pre-emphasis picker, the
  coder-has-clipper toggle and the Final Clipper Drive slider, and shows the
  ceiling slider; the Processing sidebar hides the HF Limiter / Clipper tab
  (nothing to ride); the status bar reads `MODE: PROC AUDIO / DIGITAL`. The
  web dashboard mirrors it on the Audio I/O page and the Headroom card.
- **Format Profile** "Digital -- Streaming / DAB" (`PresetCatalog`): AGC
  target -18, multiband `5_jazz`-class intensity light, PrimeBass off, bass
  clipper off, HF limiter irrelevant, drive low; documented as a starting
  point for -16 LUFS music / -17 mixed (AES TD1008 DELIVERY levels) with a
  note on -23 LUFS for EBU R128 DAB, set via the AGC target. The -14 LUFS
  figure quoted for Spotify / YouTube is a playback normalisation level, not
  a delivery target, and the profile deliberately does not chase it. Profiles are FM-tuned today, so this is the first
  non-FM one; `FormatProfileTests` pin its keys.

### Verification (metric-first, per AGENTS.md)

- `ProcessedAudioOutputTests` additions: digital target passes 18 kHz
  (currently `processedAudioBandLimitsAboveFifteenK` pins the opposite for
  the FM target -- both must hold, one per target); no pre-emphasis curve
  (flat within 0.1 dB to 18 kHz); true-peak never exceeds the ceiling by
  more than 0.1 dB on the adversarial programs (4x-oversampled measurement);
  stereo image passes unmodified (side/mid ratio of a hard-panned source
  equals the input's); final clipper inactive even with
  `processed_audio_coder_has_clipper = False`; config round-trip of the two
  keys; INI without the keys = FM target (zero drift for existing users).
- New `LoudnessMeterTests`: BS.1770-4 known-answer signals (-23 LUFS 1 kHz
  sine reads -23.0 +/- 0.1; the EBU Tech 3341 gating test sequences).
- Strict baselines: untouched by construction (composite path unchanged;
  `--verify --baseline-strict` on all four + Linux must be zero-drift).
- Deep suite untouched-areas sanity; swiftlint 0; `ControlSchemaTests` for
  the two keys; `SectionNavigationTests` for the hidden tab.
- Listening (release build, BlackHole -> a stream encoder or a DAB+ codec
  file): confirm the 16-20 kHz air is back and no codec overs.

### Docs (same commit series)

studio-operator-guide.md "Processed audio instead of MPX" gets a "Delivery target" subsection
(what digital turns off and why, the ceiling, the LUFS readout, the new
profile), the Audio I/O section names the control, the Format Profile table
gains the row; ARCHITECTURE output-modes section + the audio-domain stage
list note the digital bypasses; README feature bullet ("also a plain stereo
processor for streaming / DAB with a true-peak ceiling and LUFS metering");
AGENTS: the resolver / seeding rule and the "profiles are FM-tuned except
Digital" note; CHANGELOG.

### Effort and risks

- Size: medium. Generator changes are small and gated (a handful of `if
  digitalDelivery` sites); the loudness meter is the largest new piece (~300
  lines + tests); UI x2 and docs are routine. Roughly two days of work plus a
  listening pass.
- Risk 1: the 16 kHz clamp is also what keeps the FM target safe; the lift
  must be strictly target-conditional (test both).
- Risk 2: the limiter's tanh ceiling has a soft knee; verify the true-peak
  bound with the oversampled measurement rather than assuming threshold =
  ceiling, and document the residual (expected < 0.1 dB).
- Risk 3: LUFS gating edge cases (silence, very short programme) -- follow
  BS.1770-4 exactly and pin with the EBU test vectors before showing the
  integrated number; publish validity flags like the Meter does.
- Out of scope: a true broadcast loudness NORMALISER (automatic gain to a
  LUFS target over a whole programme) -- the AGC target is the operator's
  lever for now; revisit after the meter exists.

## Opt-in advanced stages -- validate + decide default

Highest-leverage audible-gap closer vs the enterprise tier: these stages are implemented and shipped but **default-off and not preset-validated**, so a fresh install runs below the chain's real capability. Each needs a verifier/listening A/B -> a per-preset enablement decision. OFF must stay bit-identical (`--verify --baseline-strict` green); ON validated via `--verify-receiver` (separation + pilot/RDS guards unchanged).

1. **Pre-emphasis-aware HF clipper** (`hf_clipper_*`): opt-in last resort since the HF limiter went default-on (it measured 17 dB worse hat SINAD). Decide in a later release whether it stays at all.
2. **Multiband Phase 2 -- transient-aware attack** (`multiband_transient_aware_attack_enabled`). Verifier + dense-percussive listening A/B; preset decision.
3. **Multiband inter-band coupling** (`multiband_inter_band_coupling_enabled`, `--verify-multiband-coupling`). "Loud bass softens highs" -- listening A/B; preset decision.
4. **Anti-aliased residual clipping** (`pre_encode_bandlimited_residual_enabled`) -- see Next up #1.

## Experimental candidates -- composite-processing ideas (parked 2026-08-01, user decision)

Analysis of a third-party processor's press release (loudness/cleanliness claims) mapped onto our chain; all would ship off-by-default and verifier-gated. We cannot know the vendor's actual method -- these are our own defensible readings backed by the interleaving math.

1. **`pre_encode_stereo_link` blend (small).** The audio composite is bounded by `max(|L|,|R|)` at every instant (convex-combination identity), but `StereoLinkedOversampledPeakLimiter` rides ONE shared gain from `max(|L|,|R|)` -- needlessly attenuating the quiet channel whenever the loud one limits. A link factor 0..1 (1 = current linked behavior) recovers ~2-3 dB integrated loudness on wide program at IDENTICAL composite peak, distortion-free (gain riding, not clipping); cost is momentary image shift toward the limited side. The shared-envelope code already exists; the experiment is the blend + an image-stability verifier scenario.
2. **`mpx_clipper_iterations` (moderate).** POCS-style iterative clip -> re-project (bandlimit + protected bands) composite peak control; our differential clipper + guard-band cancellation is one iteration of exactly this. 2-4 iterations at OS rate, CPU-gated by `DSPThroughputTests`, measured by guard-band depth / >60k leakage / receiver separation.
3. **Studio<->Meter closed-loop RF trim (large).** Their "analyzes RF bandwidth after the exciter" loop; the Meter's RF spectrum (0.43) is the sensor. Auto-trim clipper drive against occupied-bandwidth targets. Needs the control API on the Studio side + a Meter export path first.
4. **Composite peak-to-RMS governor (from the retired FUTURE.md).** A slow
   loudness governor on the audio composite that holds a target peak-to-RMS
   ratio (density) rather than a peak, so Final Drive stops being the only
   loudness lever; verifier metric first (composite RMS / peak per scenario),
   then an opt-in stage. Sketch: `crestDB = 20 log10(peak / rms)` over a
   rolling window, `driveTrimDB = -k * max(0, crestDB - targetCrestDB)`
   applied with 1-3 s attack / 5-10 s release (an automatic preset guardrail,
   not a limiter). Composite peak-to-RMS also drives FM multipath rejection at
   the receiver, and nothing in the chain tracks it yet. Compare with the
   existing BS.412 limiter, which already bounds MPX power.

## Broadcast-tier follow-ups

- **Multiband Phase 3 -- per-band look-ahead.** Reuse `LookaheadLimiter` ring-buffer per band. Largely redundant with Phase 2; skip unless dense percussive listening shows Phase 2 isn't enough. ~3-5 d.
- **Stereo-band cancellation depth via FIR bandpass.** Optional/depth-only. Delta substitution gets ~5-10 dB in the stereo subband (LR4 phase-bounded); linear-phase FIR bandpass would push to 20+ dB. Only if listening (Next-up #1) says residual cross-domain IM is audible at amateur drive.
- **Audio-clipper oversampling bump.** `BassClipper` 4x->16x, `DistortionCancelledClipper` 8x->16-32x, likely swapping `BiquadCascade6` decimation for `LinearPhaseFIRDecimator`. Polish (aliasing already inaudible at amateur drive); ~1-2 d each + baseline refresh. Aliasing gate: `DistortionCancelledClipperTests.aliasingEnergy` (-38 dBFS now; pro chains push past -75).

## Open gaps

1. **Calibration workflow** -- exciter-facing guidance + long-run operational hardening.
2. **AGC validation** -- density-scaling tuning on real program; decide whether a lookahead path is worth the latency.
3. **Stereo image validation** -- mono bass / PrimeBass / multiband interaction on difficult real program.
4. **Live-apply smoke testing** -- TA-edge auto-injection and AF Method B switching in particular.

## Pre-encode limiter interpolator response (found 2026-09-05)

`StereoLinkedOversampledPeakLimiter` upsamples 4x with a ONE-SIDED Lagrange-4
interpolator (`interpolateLagrange4`: points at -2, -1, 0, +1 host samples,
evaluated at t = 0.25 / 0.5 / 0.75 between the last two). Its polyphase
magnitude is not flat: +0.01 dB at fs/12, +0.15 at fs/6, **+0.32 at fs/4**,
+0.19 at 5fs/16, -0.14 at 17/48 fs, **-0.41 at 3fs/8** -- measured on the
digital delivery target at 48 kHz (limiter on vs off is the whole difference;
the analytic polyphase sum reproduces every figure to 0.02 dB). At the FM
chain's 48 kHz audio domain that is +0.32 dB at 12 kHz on air, inside the
`productionChainFollowsTheAnalogPreemphasisCurve` 0.5 dB tolerance, which is
why it went unnoticed. Fix candidates: a symmetric Lagrange-4 (points -1..+2,
one host sample of extra delay in the OS path, droop only, no bump) or a
short linear-phase FIR interpolator like the guard's. Either moves the
composite output of every scenario, so it is a deliberate chain change with
all four macOS baselines plus the Linux baseline recaptured in one commit,
and the `DualRateHFResponseTests` tolerance tightened to hold the gain.

## Live-apply gaps found while verifying the digital target (2026-09-05)

- **`program_lowpass_hz` is reported `live` by the REST API but never reaches a
  running engine.** `RuntimeConfig` carries the field, so `ConfigPatch` derives
  a `live` disposition from the diff, yet `MPXGenerator.programLowpassHz` is a
  `let` and `applyEncoderComplianceConfiguration` runs only at init and on a
  sample-rate change -- a PATCH changes the INI and nothing else until restart.
  The GUI binds the same slider as restart-class (badge shown), so the two
  front ends disagree about the key. Fix is one of: make the generator store
  the value and re-run the compliance configuration on change (true live), or
  drop the field from `RuntimeConfig` so the derived disposition says
  `restartRequired` honestly. Pin with a test either way (the derivation rule
  "disposition follows the RuntimeConfig diff" assumed every carried field is
  applied).

## Verifier coverage follow-ups

1. **Tighten bandwidth baseline tolerance** (+/-1.0 -> +/-0.5 dB) with a multi-frame averaged FFT to cut spectral leakage in the `>60k/>67k` ratios.
2. **BS.412 full-chain long-run scenario** -- component limiter is unit-tested (`BS412PowerLimiterTests`); a `--verify-long`-style full-chain check over 30+ s is still uncovered (deferred for render cost).

## Tactical backlog

**Sprint:** validate PrimeBass / mono bass / multiband on difficult real material; refine calibration workflow where real operator friction exists; per-Format-Profile clipper-drive A/B (eight 0.30 profiles).

**Medium-term:** dedupe biquad/crossover filter-config logic; name DSP magic numbers; deterministic RDS-scheduler tests; more AGC / filter-primitive unit tests.

## Code-quality priorities

### P0 -- confidence/safety

1. Deterministic primitive tests: Biquad/BiquadCascade6/LR4/Lagrange/FIR decimator (`FilterPrimitiveTests`), AGC envelope (`AGCDetectorTests`), and Preemphasis/Deemphasis (`PreemphasisFilterTests`, added v.037) are all covered. Remaining low-value gaps only: an isolated M/S encode round-trip (algebra is trivial; chain separation tests already exercise it) and a focused bypass-null contract (the `DeepDSPTests` "Silence" input already covers it at chain level). Effectively done.
2. Fix verifier bandwidth metric so RDS doesn't skew occupied-width (`bright_dense` occ999 reads differently with `en_rds` on/off). NOTE: this is a metric *redefinition* (exclude the 57 kHz RDS band from the occupied-width / above-60k/67k power sums), not an active bug -- the threshold + baseline already account for RDS. Cascades into 3 baselined bandwidth fields -> recapture. Decide the metric's intended meaning (audio-only width vs total composite) before doing it.

**P1 -- modularization** (MPXPrimeCore is the forcing function; companion-app needs the same boundaries)

- extract the RDS subcarrier front-end (57 kHz mixdown -> biphase symbol+clock recovery -> differential decode) feeding `RDSStreamDecoder`, and an `MPXAnalysisTap`/FFT helper; split `MPXGenerator.swift` into stage files; split `AudioOutputEngine.swift` by concern; split `SwiftUIControlApp.swift` one-card-per-file; reduce engine/config/generator/UI coupling.

**P2 -- harden behavior:** stronger `AppConfig` validation; `sum_level` 1.0->0.9 investigation; device/routing edge cases; structured error reporting.

**P3 -- performance:** more vDSP where profiling shows value; cache RDS byte prep; hot-path benchmarks; keep an Instruments baseline.

## UX / accessibility polish

Open items after the 0.37 HIG pass:

Meter accessibility (the old item 3) and dense-tab DisclosureGroups (old item 4, started 0.35) are done. Remaining, lower-priority:

1. **Format-profile drift indicator.** When the config drifts from the selected Format Profile, show the picker as "edited". Real feature but needs `applyFormatProfile` refactored into a pure function + a decision on which fields count as drift; the model author deferred it ("no dirty indicator in v1"). A half-correct version gives false "edited" flags, so do it properly or not at all.
2. **Prose-to-tooltip sweep.** Mostly already appropriate -- the house rule keeps *distinct actionable guidance* inline; little remains safe to move. Low value.
3. **Dynamic Type pass.** Manual: launch with large system text, verify no clipping/overlap across tabs (fonts are already semantic, so likely nothing to fix). Eyes-on, not a code task.
4. **Sidebar-row enabled affordance.** Overview cards now carry status dots; the `StageSidebarRow` 6 pt dot is unchanged -- optional native status badge / contrast check.

## RDS enterprise tier (stretch -- only if direction shifts to multi-station)

1. **UECP SPB 490 minimal subset over TCP/IP** (port 5570, DLE framing, MEC parse for PI/PS/PTY/RT/AF/TA/scheduler/master-enable, address fields). Hooks into `applyRDSRuntimeConfig`. ~1-2 wk, new `UECPServer.swift`.
2. **EON (14A/14B)** -- linked-network PI/PS/AF/TP/TA mirroring across PSNs. ~3-5 d.
3. **Multi-PSN / Data Sets** -- per-PSN `RDSRuntimeConfig`, boundary switchover without PI flap. ~1 wk, builds on UECP.
4. **Ops: SNMP MIB + watchdog + time-of-day scheduler + on-air loopback verify.** ~2-3 wk.

- Deferred standards item: Group 15A UTF-8 Long PS toggle bit (IEC 62106-2:2018 sec. 6.8; ASCII Long PS is correct for amateur use today).

## Linux port -- remaining / possible follow-ups

- JACK backend behind an `AudioBackend` protocol (today ALSA-only); Pi 4/5
  real-time budget still unmeasured.
- Meter CLI on Linux (the tuner C++ is already portable; SDRplay dlopen
  needs `.so` names).
- ALSA output device enumeration is in the dashboard picker; a headless
  `--list-devices` equivalent could mirror it.

### arm64 SIMD kernels for Linux (long-term, not started)

Worth doing only for **Linux on arm64** -- a Pi 5, an Ampere box, an arm64
VM. macOS on Apple Silicon needs nothing: `MPXPrimeAcceleration` compiles
EMPTY there and the hot kernels are Accelerate's own `vDSP_dotpr` /
`vDSP_conv` / `vvtanhf`, which are already hand-tuned for the part. The C
kernels in `MPXPrimeNative/MPXPrimeSIMD.c` are x86-only today (SSE2 default
plus an AVX2 clone behind a glibc ifunc), so an arm64 Linux build falls back
to the portable Swift reference (`mpxReferenceDot` / `mpxReferenceTanh`) and
runs the chain unaccelerated. Nobody has measured what that costs -- that
measurement is step one, not the kernels.

What it would take, in order:

1. **Measure first.** `--bench` on arm64 Linux (an arm64 container on an
   Apple Silicon Mac runs natively and is enough for a first number, a real
   Pi 5 for a decision). If the reference path already fits the budget, stop:
   the kernels are not worth a third numerics path.
2. **NEON variants** of the same two kernels, selected at load the way the
   x86 ones are -- except every arm64 CPU that matters has NEON, so this is a
   compile-time target rather than an ifunc.
3. **The bit-parity contract is the hard part.** One Linux baseline is valid
   for every CPU only because AVX2 and SSE2 compute bit-identical results:
   same 8-lane vectors, same accumulation and reduction ORDER, and FMA
   contraction off (`#pragma clang fp contract(off)`). NEON must meet the
   same three conditions or Linux needs a baseline per architecture, which is
   a policy change, not a flag. NEON's fused multiply-add is exactly the trap
   -- `vfmaq_f32` would silently change results. `AccelerateShimTests` holds
   the C kernels to the Swift reference bit for bit and is the gate.
4. **Decide the baseline question deliberately.** There is no
   `default-linux-aarch64.json` today and nothing looks for one. Adding arm64
   as a supported Linux target means either proving bit-parity with the
   x86_64 capture (preferred) or accepting a second stored baseline and a
   second CI leg.

**Verification note, because it is easy to get wrong:** an **amd64** Docker
image cannot test any of this. On an Apple Silicon Mac an amd64 image runs
under emulation, executing x86 instructions -- it exercises the SSE2 path,
not NEON. Use a NATIVE arm64 Linux container (`swift:noble` on this Mac runs
arm64 at full speed) for correctness and bit-parity, and real arm64 hardware
for any timing claim; an emulated container's timings are meaningless.
Conversely the x86_64 strict baseline cannot be checked in an arm64
container either -- it looks for a per-architecture file, finds none, and
reports "Baseline: none", which is why the x86_64 comparison stays CI's job.

---

# Anti-rework guardrails -- do not re-plan / re-implement

## Active patent backlog

| Priority | Patent | Title | Expires | Stage | Why |
| -------- | ------ | ----- | ------- | ----- | --- |
| **P0 -- validate / Phase C** | [US 6,937,912](https://patents.google.com/patent/US6937912B1/en) | Anti-aliased clipping with band-limited step functions | 2025-09 | `OversampledPeakLimiter` (pre-encode L/R) landed opt-in; `audioCompositeSoftClipEnabled` shaper still candidate | Phase A/B landed opt-in via `pre_encode_bandlimited_residual_enabled`. Remaining: program validation, then optional Phase C on the audio-composite shaper. |
| **P1** | [US 6,434,241](https://patents.google.com/patent/US6434241B1/en) | Half-cosine signal peak control | 2014-08 (lapsed) | Same stages as P0, alternative kernel | Continuous-first-derivative half-cosine peak; overshoot ~10% -> 0.1-0.2%. Less IM rejection than US 6,937,912 but lower CPU. Selectable kernel / fallback. |
| **P3** | [US 5,892,833](https://patents.google.com/patent/US5892833A/en) | Gain calibration for audio compressors | Expired | `MonoCompressor` makeup stage | Track average GR to keep makeup roughly compensating. Polish, low priority. |
| **P6** | [US 7,076,071](https://patents.google.com/patent/US7076071B2/en) | Ambience/imaging enhancement (mono-null bus) | Expired | Stereo widener | Invariant: any enhancement term must cancel in `L+R`. Land first as a verifier metric (mono-sum delta widener on/off), then constrain the widener to meet it. FM-safe answer to Open-gaps #3. |
| **P7** | [US 4,567,607](https://patents.google.com/patent/US4567607A/en) | Stereo image recovery (frequency-bounded crossfeed) | Expired 2003-01-28 | Stereo widener | Crossfeed below ~1-5 kHz, bounded phase difference, shaped mono dip ~200-900 Hz. Pairs with P6 as widener guardrails. |

P4 (US 4,249,042) + P5 (US 3,790,896) landed in 0.34 as the bass-desensitised wideband AGC (`wideband_agc_bass_desensitize`, opt-in). Optional extension: **silence-sense freeze** ([US 4,500,753](https://patents.google.com/patent/US4500753A/en), Gentner, expired 2003) -- freeze AGC recovery during near-silence.

## HF transient / pre-emphasis limiting prior art (survey 2026-08-29)

Backs "Next up (0): hi-hats / cymbals". Verdict: every classic HF-limiter,
sliding-band, dynamic-pre-emphasis and automatic-threshold technique is
EXPIRED and free to implement; three ACTIVE patents overlap the space and are
listed with design-arounds. Orban's MX limiter (8600, 2010) has no located
patent -- treat as trade secret, not as a constraint. US term rule used: in
force on 1995-06-08 -> later of 17 y from grant / 20 y from filing; filed
after -> 20 y from filing.

| Fix idea | Patent / publication | Status | What it covers, how it maps |
| -------- | -------------------- | ------ | --------------------------- |
| **HF limiter (Step 2 #2, primary actuator)** | [US 4,103,243](https://patents.google.com/patent/US4103243A/en) Orban, "Controlling peak signal levels in a bandlimited ... system employing HF pre-emphasis" (Optimod-FM 8100 HF limiter) | Expired 1997 | Split path: direct + bandpassed HF (peak ~+21.6 dB near 19.5 kHz, Q 1.09) through a VCA, summed; VCA gain from dual comparators on the SUMMED output, ~3 ms attack / ~10 ms recovery. The pre-emphasis boost itself is program-controlled: `y = x + g(t) * BP(x)`. Clipper follows, then a shelving overshoot filter. This is the topology to implement between stage 17 and 19. |
| HF limiter (sidechain) | [US 5,574,791](https://patents.google.com/patent/US5574791A/en) Orban/AKG, combined de-esser + HF enhancer | Expired 2014-06 | HF power vs loudness-weighted total power as a LOG RATIO drives HF reduction -- engage only when HF dominates the frame (a lone cymbal crash), not merely when the mix is loud. Use as the detector for the 4,103,243 actuator. |
| HF limiter (historical baseline) | [US 3,529,244](https://patents.google.com/patent/US3529244A/en) CBS Labs (Torick/Allen), FM Volumax "frequency sensitive amplitude limiting" | Expired 1987 | Program-controlled 6 dB/oct shelf between limiter and clipper. Simplest form; colours everything above the corner, so prefer 4,103,243's bandpass form. |
| HF limiter (supporting) | [US 3,621,151](https://patents.google.com/patent/US3621151) GRT, frequency-selective audio limiter | Expired 1988 | Resonant detector tuned to the saturation-prone HF region drives a frequency-selective attenuator; explicitly contrasted with clipping. |
| **Sliding-band variant (Step 2 #2 phase 2)** | [US 3,631,365](https://patents.google.com/patent/US3631365A/en) / [Re 28,426](https://patents.google.com/patent/USRE28426E/en) Dolby, "Signal compressors and expanders" (Dolby B); [US 3,846,719](https://patents.google.com/patent/US3846719A/en) Dolby, "Noise reduction systems" | Expired 1988 / 1991 | Side path HP + variable filter whose cutoff slides UP as HF amplitude rises, so only the region above the dominant HF component is compressed -- mids/vocals untouched while 8-15 kHz is reduced. Dolby FM applied exactly this to FM. |
| Sliding-band refinements | [US 4,490,691](https://patents.google.com/patent/US4490691A/en) Dolby (spectral skewing + anti-saturation); [US 4,498,055](https://patents.google.com/patent/US4498055A/en) Dolby (modulation control); [US 4,736,433](https://patents.google.com/patent/US4736433) Dolby (action substitution, SR/S) | Expired 2001 / 2002 / 2005 | Skewing: weight the HF detector so 15 kHz shimmer does not drive more GR than the 5-10 kHz region. Anti-saturation IS dynamic pre-emphasis for a saturating medium. Modulation control: stop mid/bass energy pumping the HF band. Action substitution: `max(sliding-band GR, fixed HF-band GR)` keeps control when a cymbal sits just below the slid cutoff. |
| Dynamic / distributed pre-emphasis (Step 2 #6) | [US 5,848,167](https://patents.google.com/patent/US5848167A/en) Aphex (Werrbach), distributed pre-emphasis equalizer; [US 4,112,254](https://patents.google.com/patent/US4112254A/en) dbx (Blackmer), signal compander | Lapsed 2006 / expired ~1996 | Split the 75 us curve: partial (75/50 us quotient) before the limiter, final 50 us after, so the limiter "sees 50 us" while the air curve stays 75 us; the post-limiter EQ re-grows peaks, so the composite clipper must follow. dbx: pole-zero weighting in the level-sensing path so detection tracks what overloads the channel. |
| Automatic-threshold HF band limiting | [US 4,843,626](https://patents.google.com/patent/US4843626A/en) Aphex Dominator (Werrbach), multiband limiter with ALT | Expired 2006-07 | Per-band limiters to a common reference; the summed output sets all bands' thresholds so the recombined signal fills the ceiling without pumping -- a lone hi-hat gets the full ceiling, bass + hi-hat lowers the HF threshold just enough. Keep parallel-bands + ONE final limiter (see active E3 below). |
| Clip-product monitor | [US 5,737,432](https://patents.google.com/patent/US5737432A/en) Aphex, split-band clipper | Expired 2016-11 | Watches the band NOT being clipped for the clipper's IM products and backs off clip depth. Reusable inverted: monitor 0-5 kHz for difference-frequency IM while clipping pre-emphasised HF. |
| Tonality-gated clip depth | [US 4,241,266](https://patents.google.com/patent/US4241266A/en) Orban, peak-limiting apparatus | Expired 1999 | Clip depth from waveform predictability: noise-like program (cymbals) may be clipped harder, periodic program less; less clipping when no LF masks IM. Candidate gate for HF clipper vs HF gain-ride routing. |
| Published (no patent needed) | Orban, "Transmission Audio Processing" ([PDF](https://static1.squarespace.com/static/58f8d954b8a79b4ccf726c3b/t/5996db51f5e231b4a279db2f/1503058769976/Broadcast+Transmission+Audio+Processing.pdf)); Orban/Foti AES 5469 (2001, [reprint](https://static1.squarespace.com/static/58f8d954b8a79b4ccf726c3b/t/5996dc63d7bdceeb0f5bc325/1503059043905/The+Truth+about+Audio+Processing+in+Radio.pdf)); Optimod 8200 manual ([archive.org](https://archive.org/download/orban_8200_Section_1/8200_Section_1.pdf)); Optimod 8100A manual 1986 ([scan](https://www.worldradiohistory.com/Archive-Catalogs/Orban/Optimod-8100A-Manual-1986.pdf)) | Prior art | "Placing a wide-band peak limiter after the pre-emphasis filter proved unsatisfactory ... cymbal crashes would cause the sound to literally collapse"; "HF limiting is usually performed partially by HF gain reduction and partially by distortion-cancelled clipping"; "simple clipping ... produces difference-frequency IM distortion which the de-emphasis in the radio then exaggerates ... particularly offensive on cymbals and sibilance"; HF limiters "sound best when operated independently (without stereo coupling)". 8200: explicit HF LIMITER (OFF..150 us) plus bands 4/5 coupled to band 3 acting as HF limiter. |

**ACTIVE -- design around, do not copy:**

| Patent | Holder | Expires | Claim gist | Our design-around |
| ------ | ------ | ------- | ---------- | ----------------- |
| [US 9,762,198](https://patents.google.com/patent/US9762198B2/en) | Dolby (Seefeldt), frequency band compression with dynamic thresholds | ~2034-04 | Per-band compressor thresholds made TIME-VARYING by a distortion-audibility (masking) model. | Keep thresholds fixed. If a masking model is ever used, let it act on the clipper's distortion RESIDUAL (how much to cancel / which band's residual to substitute -- the US 6,337,999 lineage we already run), never on thresholds. |
| [US 9,385,679](https://patents.google.com/patent/US9385679) | Maxim (Polleros), staggered-Y multiband limiter | ~2034-06 | Band limiters summed pairwise with a "summer limiter" after each summer. | Parallel band limiters + ONE final wideband limiter/clipper (Werrbach 4,843,626 topology = our current chain). No cascaded per-summer limiters. |
| [US 7,991,171](https://patents.google.com/patent/US7991171B1/en) | Wheatstone (Snow), 30+ harmonically related bands | ~2030-05 | Gains chosen jointly across fundamental + harmonic bands. | Peripheral; do not select multiband gains jointly across harmonically related bands. |

Not located / unverified (treat as trade secret): Orban MX limiter (no filing after US 6,618,486 under Orban's name); Telos/Omnia clippers (only Foti's expired composite-filter [US 4,991,212](https://patents.google.com/patent/US4991212A/en) verified); Thimeo/Stereo Tool "Advanced Clipper"; CRL and Texar HF limiters.

Recommended combination for Step 2 #2: 5,574,791's HF/total log-ratio detector with 4,490,691's spectral-skewing weight, driving 4,103,243's `x + g*BP(x)` actuator, sliding cutoff (3,631,365 / 3,846,719) as the phase-2 option, action substitution (4,736,433) if the slid band leaves gaps; per Orban's paper run it per channel (un-linked) and A/B that against the project's stereo-link discipline with the new separation + image metrics.

## Already implemented or structurally equivalent (do not re-implement)

| Patent | Title | Where in code | Note |
| ------ | ----- | ------------- | ---- |
| [US 6,337,999](https://patents.google.com/patent/US6337999B1/en) | Oversampled differential clipper | `CompositeClipper` (commit `d1d8180`, post-0.11) | Differential topology standard; only the clipping residual is decimated. |
| [US 6,618,486](https://patents.google.com/patent/US6618486B2/en) | BS.412 dual-integrator MPX power controller | `BS412PowerLimiter` | Functionally equivalent: power-detect -> rolling 60-s window -> per-block S&H -> gain attack/release -> feedback ride. Flat rolling window instead of leaky integrator (harder, more compliance-predictable). Lapsed 2015-09-09. |
| [US 5,913,152](https://patents.google.com/patent/US5913152A/en) | FM composite processor with pilot extract/re-sum | Different architecture, same end-state | Pilot protected by (1) post-clipper subcarrier injection (project invariant) + (2) RBJ-BPF cancellation in the 17-21 kHz guard inside `CompositeClipper`. Extract/re-sum on top would be redundant. Expired 2015-12-29. |
| [US 4,737,725](https://patents.google.com/patent/US4737725A/en) | Pre-LPF overshoot compensation (Inovonics) | `OversampledPeakLimiter` (4x OS) | The analog clip->phase-lag->re-clip->recover technique is what modern oversampled true-peak limiters do digitally. Expired 1996-04-17. |
| [US 5,737,434](https://patents.google.com/patent/US5737434A/en) | Multi-band compressor with cross-band coupling | `MonoCompressor` per-band logic | Inter-band coupling landed opt-in 0.28 (`multiband_inter_band_coupling_enabled`, `--verify-multiband-coupling`). Listening validation pending. Expired. |
| [US 5,579,404](https://patents.google.com/patent/US5579404A/en) / [EP 0685130 B1](https://patents.google.com/patent/EP0685130B1/en) | Digital audio limiter -- subband-aware look-ahead | `StereoLinkedOversampledPeakLimiter` (pre-encode L/R) | Both phases default-on in 0.30 (textbook delay+detector look-ahead, US 4,208,548 prior art, 1 ms; Dolby split-band 4 kHz HF detector). Dolby; US expired ~2013-11, EP ~2014-02. |

## Bass enhancement (PrimeBass) -- already implemented (do not re-implement)

| Patent | Title | Where in code | Note |
| ------ | ----- | ------------- | ---- |
| [US 5,930,373](https://patents.google.com/patent/US5930373A/en) | Waves MaxxBass -- equal-loudness-weighted harmonic synthesis | `processPrimeBass` + `configurePrimeBassFilters` (`4d4a70f`) | Even (asymmetric squarer) + odd (tanh-difference) generators with per-order weights from an ISO 226 phon-curve approx at 2..5xF0; direct LF gain tapered (`primeBassDirectGainReduction = 0.62`) so perceived bass shifts onto harmonics, buying downstream headroom. |
| [US 4,150,253](https://patents.google.com/patent/US4150253A/en) | Aphex Aural Exciter -- HP-then-clip | `processPrimeBass` (`4d4a70f`) | Adapted: a pre-waveshaper *allpass* at F0 (not HPF) rotates phase ~180 deg without amplitude loss, decorrelating harmonic phase from the direct path so they don't comb-filter at the bass-clipper input. |
| [US 5,424,488](https://patents.google.com/patent/US5424488A/en) | Werrbach transient-discriminate harmonics (Aphex) | `processPrimeBass` Phase 2 (`af7b883`) | Dual-envelope transient detector (fast - slow, normalized) modulates harmonic-band gain 0.7x sustain -> 1.4x peak on onsets. Verified via `transientGainObserved`. |
| [US 5,359,665](https://patents.google.com/patent/US5359665A/en) | Werrbach Big Bottom -- dynamic bass extension (Aphex) | `processPrimeBass` Phase 3 (0.23) | LF-envelope follower (~10 ms attack / ~300 ms release) drives `primeBassAdaptiveGain` -- "envelope duration extension". Verified via `primeBassAdaptiveGain`. |

## Codec conditioning prior art (survey 2026-09-05, for the digital delivery target)

Checked before proposing any "prepare for lossy" feature. Conclusion: the
core idea is free, the neighbouring codec-internal work is not, and the
level-and-bandwidth part was never patentable in the first place.

| What | Reference | Status | Verdict |
| --- | --- | --- | --- |
| Simulate the target codec, compare against the delayed original, pre-condition the input so the predicted artifacts shrink | [WO 2007/098258](https://patents.google.com/patent/WO2007098258A1/en) / US 2007/0239295 (Neural Audio Corp, priority 2006-02-24) | **Never granted**: PCT ceased, US application abandoned | FREE to implement. This is also the published description of what "codec conditioning" means, and it doubles as our measurement method |
| Complementary spectral shaping around a lossy encoder (the "prepare for lossy" idea) | FM pre-emphasis (1930s), Dolby A / B companding (1960s) | Long expired | FREE, but note we control only the encoder INPUT: any half of a complementary pair that would have to run after the codec is not available to us |
| True-peak headroom before the encoder, lower clipper drive on the digital path, band-limiting to the codec's rate | EBU R128, AES TD1008, ITU-R BS.1770 | Standards, not patents | FREE. Parameter choices, not patentable subject matter |
| Transient / pre-echo handling INSIDE the codec (encoder-decoder pairs, side information, post-processors) | [US 10,720,170](https://patents.google.com/patent/US10720170B2/en) and US 11,094,331 (Fraunhofer), [US 2011/0178617](https://patents.google.com/patent/US20110178617) and US 2015/0170668 (Orange) | ACTIVE | DESIGN AROUND: we process the encoder's input only and signal nothing to the decoder. Do not add anything that requires decoder cooperation |
| Orban "PreCode" | Trademark; the published description is deliberately vague ("energy and spectrum aware band detection"), and Orban holds granted patents | Assume protected | Do not reimplement from their marketing copy, and never use the name. Build from the Neural Audio disclosure and our own measurements |

**How this would be gated.** The Neural Audio disclosure describes the same
loop we would need as a TEST: encode a rendered scenario through the target
codec, decode it, time-align against the original, and score the difference.
That gate has to exist and show a real improvement before any conditioning
knob ships -- exactly the rule the rest of this file applies to DSP claims.
Ordering: build the measurement first, and only then decide whether
conditioning earns its place.

## Skipped -- active patents or non-additive (design-around noted)

| Patent | Status | Reason |
| ------ | ------ | ------ |
| [US 9,712,916](https://patents.google.com/patent/US9712916B2/en) DTS "Bass Enhancement System" | **ACTIVE** to ~2032-12-19 | Headroom-coupled adaptive gain on MaxxBass. Design-around: fixed/program-dependent gain not driven by instantaneous headroom. |
| [US 9,319,789](https://patents.google.com/patent/US9319789B1/en) Music Tribe "Bass Substitution Filter" | **ACTIVE (reinstated)** to ~2032-02-11 | Level-tracking centre-frequency modulation of the harmonic filter. Design-around: fixed centre frequency, amplitude-only modulation. |
| [US 4,482,866](https://patents.google.com/patent/US4482866A/en) BBE Sonic Maximizer | Expired 2002-02-26 | Frequency-dependent group-delay correction -- actively harmful in FM (breaks pilot/subcarrier coherence). |
| [US 4,748,669](https://patents.google.com/patent/US4748669A/en) SRS / Hughes | Expired | Stereo enhancement via L-R, not bass. Misclassified in earlier surveys. |

## Skipped -- evaluated and rejected

| Patent | Title | Status | Reason |
| ------ | ----- | ------ | ------ |
| [US 7,295,628](https://patents.google.com/patent/US7295628B2/en) | DSP MPX with sample-frequency-aligned vestigial sideband | Expired 2024-07-30 | Requires `fs = 2 x fmod` (76 kHz chain). Our chain runs 192 kHz throughout; adopting means a full chain-rate refactor. Niche AM/SSB technique; FM's DSB-SC is what receivers expect / IEC 62106 mandates. |
| [WO 2017/186756](https://patents.google.com/patent/WO2017186756A1/en) | Frequency-domain L+R/L-R protector | PCT ceased; **CA3021918 possibly enforceable to 2037** | Legal: verify before any CA distribution. Technical: per-block FFT of M and S is CPU-expensive + adds OLA latency; M/S-domain dynamic L-R limiter achieves similar mono-compat without FFTs. |
| [US 4,412,100](https://patents.google.com/patent/US4412100A/en) | Multiband signal processor (Orban) | Expired 2001-09-21 | 1981 distributed-crossover multiband+clippers -- structurally the prior art for what we already ship (FIR multiband + per-band `MonoCompressor` + differential composite clipper), at a less modern level. Nothing to adopt. |
| [US 7,587,254](https://patents.google.com/patent/US7587254B2/en) | DR processor with auxiliary decorrelation in L+R limiter sidechain | ~2029 | Filed 2004; not yet expired. Revisit post-2029. |

## Settled findings

**Pre-emphasis placement.** Ships in L/R immediately upstream of the pre-encode limiter (`preL`/`preR` in `processSampleDetailed`; canonical Optimod/Stereotool). The b806053 cost regression that reverted this in 0.10 is no longer reproducible post-0.24 (vvtanhf / vDSP_dotpr / FIR multiband / differential clipper cut chain cost ~95% -> ~28% RT, absorbing the ~7% relative increase). Do not relocate to M/S.

**MPXDecoder has no pre-demod pilot/RDS notch (do not re-add).** The decoder used to notch the 19 kHz pilot and 57 kHz RDS on the common signal before the M/S split; the notch skirts asymmetrically attenuated the S-channel DSB-SC sidebands (38 +/- f), the dominant HF stereo-separation limiter (14 kHz capped ~44 dB). Removed on develop/v.037 -> 97 dB at 14 kHz. Pilot/RDS are handled by the 15.5 kHz M-path lowpass + S-path `diffLP` + the post-recombination `pilotNotchL/R`. The decoder only sees the app's own clean composite (monitor path + `--verify-receiver`), so there is no off-air noise the notches protected against. If `MPXPrimeMeter` later decodes noisy off-air composite, add input conditioning *there*, not back in the shared decoder.

**Composite-clipper guard cancellation depth (measured, not a defect).** v.036 measured the clipper's guard cancellation in isolation (upstream nonlinearities off, clipper driven hard): pilot guard ~11.8 dB, RDS guard ~12.7 dB, residual IM ~-50 dBFS in both -- clean in absolute terms. Aligning the decimator group delay to an exact integer host-sample count (removing the ~2 OS-sample bypass/residual offset) was implemented and measured: **no change** to depth or residual, at ~10% more clipper taps -> reverted. The misalignment noted in `LinearPhaseFIRDecimator.groupDelayHostSamples` is confirmed negligible. If depth ever needs to go deeper, the binding constraint is the guard bandpass Q / delta-substitution match, not decimator alignment.

## Design constraints

- Realtime callbacks stay lock-free / allocation-free. Cross-thread audio-thread comms use `OSAllocatedUnfairLock` (priority-inheriting) or an atomic -- never `NSLock`.
- No shell/file/network work in DSP paths.
- Preserve integrated RDS + monitoring workflow; keep monitor-output latency separate from transmit-path quality.
- Subcarriers (19 kHz pilot, 57 kHz RDS) injected after all peak-control stages; pre-emphasis in L/R before the pre-encode limiter. (Full invariants in CLAUDE.md.)

## References

- [US 4,460,871 -- Variable-frequency-shift demodulator (Orban)](https://patents.google.com/patent/US4460871A/en) | [US 5,168,526 -- Distortion-cancellation circuit (Orban)](https://patents.google.com/patent/US5168526A/en)
- [Stereotool -- Limiting and Clipping](https://www.thimeo.com/documentation/limiting_and_clipping.html) | [Telos RDS guidance](https://docs.telosalliance.com/docs/rds)
- Anti-aliasing background: Valimaki "Discrete-Time Modelling..." (1995), Brandt "Hard Sync without Aliasing" (2001), Stilson/Smith "Alias-Free Digital Synthesis..." (1996).
- Open-source peer set: `mpxgen` (no processing), `PiFmRds` (Pi-only), Stereotool free (closed-source); Liquidsoap is the common amateur-station backbone / future JACK target.
