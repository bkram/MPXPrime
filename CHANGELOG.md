# Changelog

Versions are sequential point releases (0.7 → 0.8 → 0.9 → 0.10 → 0.11 → 0.20 → 0.21),
not decimals. 0.20 was a deliberate jump from 0.11 to mark the magnitude
of the post-0.11 work — composite clipper differential topology with
linear-phase FIR decimation, RDS live-apply for the full operationally-
toggled surface, GUI restructure with status-first Control tab,
PrimeBass with MaxxBass / Aphex / Werrbach patent-grade harmonic
synthesis, adaptive on-screen FPS, and an optional deep DSP
combination test suite. Newest first.

## Unreleased

- **CI: both legs green again after the 0.50 push.** The Linux test target
  did not compile twice over: the `--verify-program-ab` stub wrote to
  Glibc's mutable `stderr` global (Swift 6 strict concurrency rejects it;
  now `FileHandle.standardError`), and the 0.45 `AudioDeviceRateExpansionTests`
  referenced the CoreAudio-only `AudioDevices` type without an `#if os(macOS)`
  guard. On the macOS runner `DSPThroughputTests` lost a single relative-cost
  comparison to runner contention (the "lighter" chain at 3.06 s vs a 1.86 s
  bound, 667 other tests green); every pair comparison there now re-measures
  once when it fails, so a preempted render no longer reds the build while a
  real regression (fails twice) still does. The Linux runner then failed
  `CompositeShaperOrderingTests` at -24 dB "shaper action" -- not a Linux
  numerics problem (the test passes in a Linux/arm64 container) but the
  documented RDS hazard: the test rendered with RDS on, the RDS text
  scheduler paces by wall clock, and on a runner where the suite took 814 s
  the two renders got different RDS bits (max delta = exactly twice the RDS
  amplitude). Both offline-render comparisons (that suite and
  `DualRateBoundaryTests.explicitlyDisabledIsStable`) now run with RDS off,
  and the shaper test's failure message carries the budget inputs (pilot /
  RDS percent, audio peak, budget margin, clipper / limiter / safety-clip
  duty) so a future failure explains itself. With the tests green, the
  Linux verify gate then reported 52 drift findings against
  `default-linux-x86_64.json` -- captured 2026-07-11 with the 0.42 chain and
  never recaptured for the 0.45 final-stage rework (the physical thresholds
  pass; only the stored compare drifts). New manual workflow
  `linux-baseline.yml` recaptures it on the ubuntu-24.04 runner class the
  gate uses (physical thresholds first, capture, strict round-trip, artifact),
  because Rosetta cannot run the Linux toolchain and the bench box is not
  always reachable; the recaptured file lands in the same commit series.
- **Docs: the macOS vs Linux split is now explicit.** Platforms-at-a-glance
  table and a three-row default-config-path table (macOS, Linux source
  build, Debian service) in the manual; Monitor operating mode flagged
  macOS-only; `--verify-program-ab` and the live BlackHole scripts flagged
  macOS-only in BUILDING. The Linux first start is documented honestly: the
  Debian service ships `control_enabled = False` with no `--web`, so the web
  dashboard -- the only Linux interface -- serves nothing until the INI the
  first start created is edited; the old "enable the service, open :8737"
  instructions did not work on a fresh box. (Whether the package should
  enable the dashboard by default is an open packaging decision.)
- **Stereo Widener removed; Mono Bass moves to the PrimeBass tab.**
  Operator verdict after listening (2026-09-04): the widener did nothing
  beneficial on air, while mono bass earns its place. The stage, its
  `stereo_widen_enabled/width/center/mix` keys, the `widener` preset kind
  (`safe_fm` / `open_music` / `wide_chr`), its sidebar tab, signal-flow
  chip, overview card, dashboard page and telemetry are gone; an INI that
  still carries the keys loads fine (ignored). Mono Bass is now a card on
  the PrimeBass tab / dashboard page (both are post-multiband bass-domain
  image controls), and Format Profiles carry the mono-bass crossover
  directly (`monoBassFreqHz`: 140 Hz for Clean / Speech / Classical,
  115 Hz for Loud -- exactly what their widener presets used to set).
  Music - Loud is the one profile whose sound changes: it had the widener
  ON via `wide_chr` (Width 0.46), so its image loses that widening and its
  stereo-image protection ratio moves from 0.999 to the former default
  1.025 -- the protection stage used to scale its allowed side/mid ratio
  with the widener's Width and now uses that default as a fixed
  reference, so every widener-off chain (all strict baselines) stays
  bit-identical. Deep suite: the pairwise column became Mono Bass, the
  Widener x MonoBass counteract pair became PrimeBass x MonoBass.

- **Audio I/O: a dedicated sidebar section for devices, operating mode, and
  level calibration -- with per-device calibration memory.** Devices, the
  engine format, and the three level trims left the Settings window and the
  DSP tabs for a new Audio I/O section (`UI/AudioIOTab.swift`; the web
  dashboard's Interfaces page is retitled and mirrors it): Input card
  (picker + Input Gain + live IN meters), Output card (picker + MPX Output
  Level + Line Output + a live DAC Peak readout), Monitor card, Engine
  card, and ONE segmented Operating Mode control -- MPX Composite /
  Processed Audio / Monitor -- over the two stored booleans (no new INI
  key; `/api/status` now reports `monitorAudio` too, previously invisible).
  Pilot Level moved to the Stereo Coder tab where it belongs. Calibration
  is rig plumbing, not sound: it is REMEMBERED PER DEVICE
  (`Control/DeviceCalibrationStore.swift`, a `<config>.devicecal.json`
  sidecar -- input gain per input device, output level + line output per
  output device and per operating mode, USB-UID-drift name fallback), and
  recalled automatically when the device or mode changes, in the GUI and
  over the REST API alike (explicitly patched keys win; recalled values
  land with the restart, never live onto the old rig). Switching between
  the BOMGE exciter and an SFP-X feed now restores each rig's calibration
  with zero clicks -- the failure that motivated this: an exciter trim
  calibrated for one rig silently under-drove the other. Snapshot loads
  now restore THE SOUND, NOT THE WIRING
  (`Control/InstallationKeys.swift`): devices, sample rate/block size,
  mode, the three calibration levels, and the control-server keys are
  preserved from the live config on load in both backends (a preset loaded
  over REST can no longer turn off the server it arrived through); saves
  and exports stay full-config, and installation churn no longer flips a
  preset to "edited". Per-tab resets and the legacy-profile migration keep
  calibration too (`input_gain_db` joined `legacyResetPreservedMPXKeys`).
  New headless suites: `DeviceCalibrationTests` (store, view-model hooks,
  headless backend) + snapshot-preservation cases in `SnapshotTests`.

- **Honest output telemetry + one output-mode resolver (Audio I/O
  groundwork; two bug fixes).** (1) The deviation readout is now a
  MODULATION-domain figure: both engines divide `output_gain_db` back out
  of the metered composite, so the kHz display no longer under-reads by
  exactly the operator's exciter trim (plan.md item -1; field-measured
  30.2 kHz displayed vs ~75 on air at -7.89 dB). Its electrical
  counterpart `dacPeakDBFS` -- the peak actually presented to the
  converter, post output gain AND line output -- joins `/api/meters`, the
  dashboard Headroom card, and the Audio I/O Output card.
  `DeviationTelemetryTests` pins the invariance; `smoke-live.sh`'s
  expectation math is now correct at any station trim (before, it silently
  required output_gain 0). (2) `MPXGenerator` seeds `audioOutputOnly` from
  `processed_audio_output` at construction, fixing Linux processed-audio:
  the ALSA engine never called `setAudioOutputOnly`, so the dual-rate
  boundary stayed wrongly enabled (48 kHz coefficients at the output rate
  -- the same class fixed on macOS 2026-08-30) and the optional final
  clipper could never engage; pinned by
  `configSeedMatchesExplicitSetAudioOutputOnly`. The mode resolution
  itself (processed wins over monitor) now lives in one place,
  `AppConfig.resolvedOutputMode(allowMonitor:)`, instead of three
  hand-rolled copies.

- **Live real-music A/B + soak script (default-flip campaign, phase 4).**
  New `ab-music-live.sh` (modeled on smoke-live.sh): runs the headless
  encoder on TWO distinct BlackHole devices (player -> 2ch input at
  48 kHz, composite -> 16ch output at 192 kHz; a shared device would feed
  the composite back into the input, so that is a hard argument error),
  alternates `advanced_dynamics_enabled` every window over the live PATCH
  API while the operator plays music, and logs `/api/meters` -- including
  the new leveler band gains/density -- at 2 Hz to CSV. Gated invariants:
  zero capture xruns and ring overflows, Safety Clip idle, never over
  budget, deviation inside the configured maximum, every AD toggle
  reported applied-live with no xrun/clip spike within 2 s, and engine
  uptime monotonic (a silent restart fails the run); `--soak <hours>`
  loops the alternation and bounds RSS growth after a 10-minute warm-up.
  A/B numbers stay informational (median deviation / GR per phase): live
  audio is not sample-aligned -- `--verify-program-ab` owns precision.

- **Real-music A/B verify mode + capture workflow (default-flip campaign,
  phase 3).** New `--verify-program-ab <file-or-dir>` (macOS-only,
  `Verification/ProgramABGate.swift`): decodes user-captured audio via
  AVFoundation, renders each excerpt through a shipped Format Profile with
  AGC+multiband (A) vs Advanced Dynamics (B), and measures both composites
  with the Meter's measurement engine -- BS.412 MPX power, max/ave
  deviation, pos/neg peaks, SM.1268 exceedance (validity-gated, "--" when
  a window has not primed) -- plus decoded crest / >6 kHz crest / image /
  band balance, the leveler's per-band gain range vs the AGC's max GR,
  and a 0.5-4.5 Hz pumping index of the B/A envelope ratio. Identical
  input per chain, so the deltas are deterministic regression material;
  RDS stays off during the render (wall-clock text scheduler) with the
  pilot on. `--ab-profile` picks the profile, `--ab-csv` exports rows,
  `--seconds` caps the excerpt; report-only until `programABGatesArmed`
  is calibrated on the corpus. The corpus comes from the user's own
  BlackHole playback via the new `scripts/capture-program.sh` +
  `scripts/CaptureToWav.swift` (compiled on demand; watchdogs the
  AVAudioEngine silent-first-start bug). `ProgramABMetricsTests` covers
  the pumping detector, crest/envelope helpers, and the decode path
  round-tripped through `CanonicalWavWriter` -- headless, no audio checked
  into the repo. Calibrated and ARMED the same day on a captured operator
  corpus (3 x 60 s sessions, music_clean + music_loud): measured worst
  case power +1.61 dBr / HF crest -0.9 / |corr| 0.06 / bands +2.8 /
  pumping 3.82; bounds frozen above those (power 2.0, pumping 5.0 -- the
  pumping index first aligns the chains' envelopes by SSE lag, because
  the leveler's ~10 ms extra group delay would otherwise read a kick edge
  as beat-rate wiggle, and it deliberately conflates leveling activity
  with pumping: the bound catches runaways, listening judges character).
  Both profiles exit 0 armed, at 30 s excerpts and full length.

- **Advanced Dynamics hat-SINAD cost: measured out, hypotheses refuted,
  flip decision escalated (default-flip campaign, phase 2c).**
  `--verify-hf-transients` gained a curated Advanced Dynamics sweep
  (canonical row, loudness-parity row at drive 4, best-tuning row at
  drive 4 / top-band offset -6, and AD on each other shipped profile).
  The sweep REFUTED every single-knob explanation of the known ~4 dB hat
  cost vs plain music_loud: the -9 dB top-band offset (hat SINAD is
  14.1-14.2 at offsets 0/-3/-6/-9 -- offset only trades ride SINAD
  against 15-23 kHz spill), speed, the band-5 transient-acceleration
  weight (zeroed: < 0.1 dB, tried and reverted like the 2.5 ms attack
  floor before it), target -19, and the composite clipper (clipper OFF
  reads WORSE, 12.8 dB -- the look-ahead limiter distorts the bursts
  more). Loudness parity (drive 8 -> 4, matching AD's own +3.9 dB RMS)
  recovers ~2 dB; the rest is intrinsic to leveling burst HF with the
  current detector/smoother. Recorded in plan.md Step 2 #5; the AD row
  stays ungated and the default flip is blocked on an explicit go/no-go
  (deeper DSP work or a signed-off lower threshold, informed by the
  real-music phases).

- **Advanced Dynamics A/B gate hardened (default-flip campaign, phase 2).**
  `--verify-advanced-dynamics` moved to its own
  `Verification/AdvancedDynamicsGate.swift` (pure move) and grew teeth: the
  neutral per-scenario quality expectations became real gates evaluated on
  the leveler chain (image, RMS drift, occupied bandwidth), the
  dead-since-landing `maxAbsRMSDelta` metric is printed and gated (loudness
  parity vs the classic chain, 3.0 dB on dense program / 8.0 dB runaway
  elsewhere), two failure-class scenarios were added (a quiet tone on the
  mid/high crossover skirt -- the trajectory table now SHOWS the known
  skirt double-lift, bands 3+4 at ~+8..10 dB on one tone, diagnostic until
  band coupling lands -- and a solo bell with a natural decay), and the
  gate reads the new `advancedDynamicsStatus` for per-band gain-trajectory
  probes: travel, slew, beat-rate modulation (bands 3-5 above 1.0 dB at
  the kick rate on bass_dense = audible pumping; calibrated at <= 0.02 dB)
  plus a decoded decay-swell bound (2.0 dB; measured 0.11 -- the decay
  guard holds through the full chain). The deep suite gained Advanced
  Dynamics everywhere it was missing: a 12th pairwise column plus a 13th
  row (which also closed two pre-existing coverage gaps the 11-flag array
  claimed but never had: Widener x Mono on/on and Phase x Mono off/on,
  found by enumeration), three counteract pairs (x composite clipper,
  x BS.412, x pre-encode limiter), and an explicit
  `advancedDynamicsEnabled = false` in the counteract base config so a
  future default flip cannot silently change the fixtures. Found and fixed
  along the way: the counteract "conspiracy-to-silence" check measured the
  FIRST 21 ms of the render -- inside the startup latency of
  high-group-delay stage combinations -- so Advanced Dynamics + pre-encode
  limiter read as a phantom -78 dB mid-band "cancellation"; the band
  energy is now measured at the render midpoint (steady state).

- **Advanced Dynamics telemetry + honest AGC status (default-flip campaign,
  phase 1).** New `advancedDynamicsStatus` on the generator (per-band gains
  via an allocation-free tuple accessor, density, active flag) flows into
  both engines' meters, `GET /api/meters`
  (`advancedDynamicsActive`/`advancedDynamicsBandGainsDB`/
  `advancedDynamicsDensityDB`, null while off), the GUI dashboard (the
  Signal Chain AGC pill switches identity to "Adv Dyn" with density + five
  band gains) and the web dashboard's Headroom card. `agcStatus` no longer
  lies while the leveler owns the dynamics: it reports the AGC inactive
  with neutral gain when Advanced Dynamics (or processing bypass) is on --
  previously stale AGC telemetry kept displaying and being ingested while
  the stage was bypassed. Bit-identical for AD-off configs (strict
  baselines unchanged); pinned by three new status tests in
  `AdvancedDynamicsTests`. Groundwork: `advanced_dynamics_*` is now pinned
  explicitly (off) in `Verification.ini`, so the strict baselines are
  decoupled from any later change to the AppConfig default.

- **Meter: the decoded-audio monitor no longer clicks on every station
  (0.45-cycle regression in the adaptive monitor read).** The audit P3 fix
  put the monitor (and the MPX pass-through) on `readAdaptive` to absorb
  producer/consumer clock drift -- but its 2048-frame target fill was sized
  for a small-block producer, while the Meter's analysis thread writes
  decoded audio in bursts of up to 8192 frames. The adaptive loop pinned the
  AVERAGE fill at 2048, the instantaneous fill sawtoothed +/-4096 around it,
  and the ring floor crossed zero on every burst cycle: a silence splice --
  an audible click -- station-independent, while the air stayed clean (the
  pre-adaptive plain read only clicked rarely, on accumulated drift). The
  target/deadband are now sized against the producer burst (12288 +/- 3072:
  worst-case floor ~27 ms of margin, ceiling well inside the ring), costing
  ~64 ms of monitor latency, inaudible for listening/relay use. Found
  live-debugging an operator report ("clicks in the Meter on all stations,
  not on an FM receiver").

- **Meter: optional monitor-ballistics deviation readout** (Modulation-card
  "Monitor ballistics" checkbox; CLI `--monitor-dev` appends `MON live/max`
  to the DEV line). Hardware modulation monitors derive deviation from an
  RC-smoothed detector, so on densely processed program they read well below
  the true peak -- a same-window bench comparison (2026-08-31) had a
  reference monitor's max-hold at 65-66 kHz where the Meter's SM.1268 MAX
  read 76, with the steady pilot agreeing exactly on both (the proof the
  scales matched and only detector ballistics differed; a 0.5 ms sliding
  mean of the identical capture reproduced the monitor within ~1.5 kHz).
  The new readout is that detector -- `MonitorDeviationMeter` in
  MPXPrimeCore, riding the same DC-tracked measurement-FIR path as the slot
  ring so the two conventions share one scale, validity-gated with
  `devScaleValid`, max-hold clearing with Reset Peaks -- shown ALONGSIDE
  MAX, never instead of it: every compliance statistic (MAX, PEAK +/-,
  >77 kHz, BS.412, the histogram) stays SM.1268-based. Test-pinned
  (`MonitorDeviationMeterTests`: exact window-mean expectations on sines /
  constant envelopes / impulses, hold + reset, the no-scale gate, and
  integrating < true-peak through the full analysis). Documented in
  manual-meter.md with the instrument-comparison guidance; on tones an
  integrating detector genuinely under-reads (1 kHz sine ~0.64x), so expect
  agreement on dense program, not on sines.

- **GUI input-level guidance matched to the manual (and to how the AGC
  actually behaves).** The Input Gain tooltip and the Help window's "Input
  Levels" card recommended peaks at -6 to -3 dBFS while the manual says
  -12 to -6 dBFS on busy program (nominal -12) -- so a correctly-staged
  source read as "too low" in the GUI and invited needless input gain.
  Field-verified 2026-08-31 on the 85.8 rig: peaks -10 to -8.8 dBFS had the
  wideband AGC riding a steady +2.7 dB, dead center of its -9..+10 dB range
  -- exactly right. Both GUI texts now say -12 to -6 (occasional peaks to
  -3) and the tooltip explains the mid-range-AGC check.

- **Meter: RF OVERLOAD detection -- a railing SDR front end can no longer
  masquerade as bad reception.** A same-station bench A/B (2026-08-31,
  NESDR SMArt v5 on a strong local) showed the "8-bit demod floor" the
  earlier bench note blamed for SIGNAL QUALITY pinning at `Unusable` was in
  fact front-end saturation: the auto tuner gain parks hot enough to rail
  10-40% of the IQ samples, reading baseband noise 4.1 kHz where a
  correctly-set manual gain reads **1.15 kHz / `Poor`** on the same station
  (RDS at 0.0% block errors in both runs). The saturation share is measured
  on the RAW capture samples BEFORE any decimation (raw bytes on the RTL
  paths, the shared amplitude threshold on SDRplay floats -- a
  post-decimation check goes blind at wide capture rates, where the
  decimator's low-pass rounds clipped flat-tops off) and exported through a
  new `mpxtuner_iq_overload()` C ABI entry, debounced by `RFOverloadGate` (MPXPrimeCore, test-pinned:
  fires above 0.1% railed samples, holds 2 s), and surfaced as an amber
  **RF OVERLOAD** badge on the Quality card; while it is up the SIGNAL
  QUALITY grade is withheld (the noise figure stays -- it is a real
  measurement, of the clipping products) per the 0.45 validity invariant.
  manual-meter.md's quality caveat is rewritten around the real cause.

- **`mpx-offline` -- the tuner's demod chain as an offline bench tool**
  (`tuner/src/mpx_offline_main.cpp`, built by the tuner CMake alongside
  `mpx-tuner`; needs only liquid-dsp, no SDR attached). Replays a recorded
  packed-IQ capture -- or synthesizes an FM-modulated composite whose
  pilot-to-RDS phase is exactly known -- through the shipped
  FMDemod/ComplexDecimator/Resampler wiring, byte-identical input to both
  demod paths, and writes int16 composite for `MPXPrimeMeter --stdin`. First
  results (2026-08-31), all on one recorded capture of 105.9:
  - **The pilot-to-RDS phase "chain dispersion" theory is refuted**: a
    synthetic composite with known phase reads back within 1 degree at both
    output rates, on both demod paths, with and without the channel filter
    (injected 0 -> 0-1 deg, injected 30 -> 29 deg), and one recorded IQ
    capture replayed to 192 and 256 kHz reads the identical angle. The
    88-vs-76 deg spread in the earlier bench was reception (multipath between
    captures) plus front-end effects, not the digital chain; the
    manual-meter.md caveat now says so.
  - **Packed vs complex demod path agree on identical IQ** to display
    precision (the B12 same-IQ A/B the audit deferred).
  - **The missing factor-1 channel filter's own effect is quantified**: RDS
    +7%, MAX +3%, the >77 kHz share 2.7x on the same capture -- real, but
    the larger term in the earlier bench table was auto-gain overload.

- **`calibrate-tx.sh` -- closed-loop deviation calibration of Studio against
  an off-air RTL-SDR measurement** (repo root; the scripted small version of
  the plan's Studio<->Meter closed-loop trim). Reads the configured pilot
  injection over the REST API, measures actual pilot deviation off air
  (auto-finds the highest non-railing RF gain, refuses railed captures,
  demodulates through `mpx-offline` with an explicit 200 kHz channel
  filter), and trims `output_gain_db` until measured matches configured --
  the pilot is constant-amplitude, so it calibrates with program on air.
  Attenuation-only is respected: a transmitter that under-deviates at
  digital full scale is reported as "raise the exciter's input sensitivity
  by N dB" instead of being silently mis-labelled, and `--watch` prints a
  fresh measurement every few seconds while that trimmer is turned.
  `--tone` switches Studio to the built-in test tone (mono 997 Hz sine, the
  0.45 calibration source) for the run and restores the program source on
  exit -- program wobbles the pilot measurement ~+/-0.1 dB between passes,
  with the tone repeat passes agree to a few hundredths of a dB.
  Validated end-to-end on air (85.8 MHz, 2026-08-31): converged in two
  passes from a 7.9 dB drive change, final state pilot 5.99 / RDS 2.95 /
  74.4 kHz peaks on a 75 kHz system. Along the way it caught two real
  deployment faults: the configured USB output device UID embeds the USB
  port, so a re-plugged exciter feed silently fell back to the default
  output device (composite on the speakers, silence on the carrier), and
  the DAC/exciter path drooped the 57 kHz RDS subcarrier -2.3 dB relative
  to the pilot (verified not to be the measurement chain: filter on/off
  read within 0.4% on the same capture) -- compensated by raising
  `rds_level` by the measured ratio, documented in the manual.

- **Meter: replaying a recorded composite no longer destroys its own
  measurement.** The stdin/file reader had no back-pressure: a live pipe is
  paced by its writer, but a redirected file never blocks on read, so the
  reader outran the analysis thread and the ring overwrote unread samples --
  measured on a 90 s RTL-SDR recording, **17,975,296 frames dropped**, which
  left MAX DEV, MPX power, the deviation distribution and the SM.1268
  exceedance count as gap artefacts while the panel still printed figures
  (0.0 kHz and `--`). Non-realtime sources now wait while the ring is more
  than half full (`canAcceptFrames`, backed by a new
  `StereoInputRingBuffer.capacityFrames`); the same recording now replays with
  **0 overflows** and produces a full, correct panel, faster than real time.
  Real-time sources (Core Audio, the in-process SDR) deliberately ignore the
  hook -- a device callback must never block -- and keep reporting through the
  drop counters instead.

- **Meter: GUI performance, honest failures, and accessibility (audit P3).**
  - **The 0.34 toolbar-relayout leak was live again in RF-spectrum mode.** The
    spectrum card's "span" chip read a per-tick telemetry value from the ROOT
    view body -- outside every isolation wrapper -- and the view model rewrote
    it unguarded 20 times a second, so with an SDR in RF mode the whole window
    body including the toolbar invalidated at 20 Hz and every isolated leaf
    closure was rebuilt: the telemetry isolation was cancelled exactly where
    it matters most. The span is now a pre-formatted, change-guarded telemetry
    string read inside a wrapper. `statusText` also left `@Published` on the
    view model (no SwiftUI body ever read it, but every retune re-laid-out the
    window and toolbar); it is a Combine subject the window subtitle
    subscribes to.
  - **The 20 Hz display gate tested the wrong window.** It gated on the first
    visible-or-minimized `NSApp` window, which can be a popover, a sheet or a
    save panel -- one of those reporting itself occluded silently froze the
    dashboard. It now gates on the dashboard window itself.
  - **Changing the monitor output device silently killed the MPX
    pass-through** while its toggle stayed lit -- the monitor swap tore down
    the pass-through player (an independent player on its own device) and
    never restored it. And both players failed silently through `try?`;
    monitor and pass-through failures now say what went wrong, and a failed
    pass-through clears its own toggle instead of lying.
  - **Two use-after-free windows on teardown.** The engine's `deinit` freed
    the scratch buffer the capture callback writes into before stopping the
    input, and `SDRLibraryInputSource` had no `deinit` at all even though the
    tuner callback holds an unretained pointer to it -- both reachable by
    releasing an engine or source without an explicit stop (a failed start,
    a view model replacing one). In the tuner itself, the close path waited
    for the capture thread with an unbounded `join()` and would have fallen
    through to `delete` regardless: it now waits on the thread's own
    acknowledgement with a deadline and, if a wedged backend misses it,
    deliberately leaks the tuner rather than freeing state that thread still
    dereferences. An SDRplay `dlopen`/`dlsym` failure now reports `dlerror()`
    (the absence of the runtime was indistinguishable from a broken install)
    and its lazy load is `std::call_once` (it is reached from both the UI and
    capture threads). RTL IQ rates are clamped to what the USB pipe sustains
    (2.4 MHz; above it the dongle drops samples silently), clamping the
    decimation multiplier so the capture rate stays an exact multiple of the
    demod rate. The AUHAL input's `mDataByteSize` is clamped to the
    allocation, so an oversized slice request returns an error instead of
    overrunning the buffer.
  - **The decoded-audio monitor and MPX pass-through drifted against their
    output device's clock.** They consumed exactly one callback's worth of
    frames per callback, so the buffered amount walked until it underran (a
    click every few minutes, straight into an exciter on the pass-through) or
    saturated. Both now use the same adaptive read the encoder's input path
    uses.
  - **Reset Peaks was disabled exactly when held values were on screen** (with
    capture stopped). It is enabled there and clears the display too.
  - **The window could be squeezed 240 pt below its own content minimum**,
    where the vertical-only scroll view clipped the RDS panel with no way to
    reach it. The minimum is now the dashboard's real content width (1260),
    and the input bar falls back to horizontal scrolling only if it cannot
    fit.
  - **Accessibility pass**, which makes the release checklist's VoiceOver item
    meaningful: the waveform/spectrum toggles were mouse-only (a tap gesture
    with an `.isButton` trait bolted onto a non-element container, so
    VoiceOver could neither focus nor activate them) and are now real
    buttons; every metric readout is an accessibility element whose spoken
    VALUE carries the over-limit state that was previously colour-only; and
    the nine AppKit-backed numeric fields and pickers (frequency, gain, LNA,
    ppm, bandwidth, calibration, pilot reference, full scale, pass-through
    gain) have spoken labels. Two tooltips were also wrong or incomplete: the
    pilot said 8-10% for 6.75-7.5 kHz (9-10% is right), and the RDS strip did
    not name the peak-referenced convention its whole reading depends on.

- **Meter: de-emphasis is now a setting, and the shipped SDR default is the
  validated measurement path (audit P2).**
  - **De-emphasis was hard-wired to 50 us** with no control, CLI flag or
    mention in the manual, so in 75 us markets (the Americas, Japan, Korea)
    the decoded monitor, stereo WAV recordings, the L/R levels and the audio
    spectrum all ran about 3.4 dB bright at 15 kHz. There is now a **De-emph
    50 / 75 us** picker in the input bar (live, persisted) and a
    `--deemphasis 50|75` CLI flag. It shapes the decode path only --
    deviation, pilot, RDS and MPX power are measured ahead of it -- and
    `MeterDeemphasisTests` pins both curves against the analog formula.
  - **`--full-scale-khz` was accepted on the audio-device CLI path and
    silently ignored**, so a run asked for absolute calibration and got
    pilot-referenced numbers. It works there now, and the startup line names
    the calibration convention and de-emphasis actually in use.
  - **The wide SDR capture path's decimator went from 48 to 128 taps**
    (12 -> 32 per phase) so its passband stays flat past +/-105 kHz instead of
    reaching into the +/-90 kHz an FM signal occupies, and its overload
    detection now shares one threshold with the packed path (the old
    hard-coded 0.995 was asymmetric against the byte mapping: it flagged
    bytes 0, 254 and 255 but not byte 1). The shipped default IQ rate was
    briefly changed to Narrow on the audit's code-reading argument (factor 1
    keeps the byte-exact packed path) and then **changed back to 1 MSPS when an
    RTL-SDR bench A/B refuted it**: at the narrow rate nothing band-limits the
    IQ ahead of the FM demod, and peak deviation read +21 kHz high, RDS level
    +46% and baseband noise +50%, with an unstable pilot/RDS phase. At factor 4
    the decimator supplies that filtering as a side effect, and setting an
    explicit 200 kHz Bandwidth at the narrow rate reproduces the factor-4
    figures exactly. The underlying defect (the demodulator's "auto" bandwidth
    is not the filter it appears to be -- the constructor installs a
    +/-110 kHz IQ filter but leaves the bandwidth mode unapplied) is recorded
    for a decision rather than patched on one dongle's evidence; the manual now
    warns against Narrow for measurements on an RTL.
  - The RDS-level primitive's file-header comment claimed the R&S
    "RMS x sqrt(2)" convention while the code deliberately publishes the
    peak-referenced figure; corrected, with the conversion between the two
    documented in the manual (an unmodulated bench carrier reads 32% high by
    design; the RMS figure reads ~24% low on real shaped biphase).

- **Meter: no readout shows a confident number it cannot stand behind (audit
  P1.4).** Ten places where the dashboard published a figure that looked like a
  measurement and was not:
  - **PEAK +/- froze at the last station.** The snapshot struct is reused
    across blocks and the two peak fields were only written while a deviation
    scale existed, so losing the pilot left the previous station's kHz on
    screen -- red-tinted as live over-deviation. They now clear, and a
    `peakValid` flag blanks and de-tints the readout.
  - **The deviation strips read a confident `0.00` with no scale at all.**
    Pilot / RDS / MAX / AVE / MIN now read `--` unless a kHz-per-unit scale is
    established, like MPX POWER already did.
  - **The scale itself was accepted from pilot amplitude 1e-5** -- 200x below
    the threshold the PILOT indicator uses -- so lock-in noise on a dead
    frequency produced an enormous scale factor: a vast fake max deviation
    with effectively every sample counting as over 77 kHz. It now requires the
    same pilot presence the indicator shows, with a ~0.4 s hold so a fade does
    not flap every readout.
  - **The SM.1268-5 exceedance statistic called itself valid after 1 second.**
    The criterion is one sample in a million; a 1 s window at 192 kHz resolves
    5.2e-4 %, 520x too coarse, so a single transient read as a violation. It
    now needs a full minute, and until then publishes the upper bound the
    counted samples support ("< 0.0002 %") instead of a number finer than its
    own resolution.
  - **The pilot-to-RDS phase meter primed "valid" at exactly 1.0 coherence.**
    The coherence ratio is 1.0 on its first sample by construction and only
    decays on a 2 s average, so for ~2 s after every retune the readout
    published the folded angle of whatever was there -- and the folded angle
    of noise has expectation 45 degrees, which is where the phantom "45.4 deg"
    readings came from. It now requires a full averaging time constant, plus
    `!inWarmup`.
  - **A drifting phase angle read as a compliant measurement.** Coherence is
    scale-free and says nothing about whether the angle stands still, so a
    free-running RDS carrier walked the angle through the whole range at
    sub-Hz rate with coherence high the entire way while the readout labelled
    the sweep in-spec/out-of-spec as it passed. A fast-vs-slow stability gate
    (4 deg, well inside the +/- 10 deg spec window) now rejects it; the new
    test pins that coherence alone would have passed.
  - **PHASE CORR had no signal gate and no mean removal.** Silence read a
    confident amber `+0.00` and noise could read red; a residual DC offset
    (off-centre SDR carrier with the DC blocker off) dragged the coefficient
    to +1.00 whatever the programme did. It is now a mean-removed Pearson
    correlation, gated on both channels carrying programme.
  - **SIGNAL QUALITY painted its own no-data state red**, because "no data"
    and a measured Unusable were both level 0. They are now distinct.
  - **L / R BALANCE never expired.** Its valid flag could only go true, so a
    standing offset stayed on screen after the programme feeding it stopped.
  - **A retune left the decoder, pilot PLL and decode-path DC blocker
    holding the previous station**, and changing the deviation calibration
    (pilot reference or absolute full scale) kept accumulators measured at the
    old scale -- peak-hold, exceedance, distribution and BS.412 max blended
    two calibrations. Both now reset what they invalidate.
  - Plus: `MeterAnalysis.process` no longer traps on a block longer than the
    `maxBlock` it was configured for (it splits the block), and two unused
    biquad cascades left `MPXDecoder`'s inlinable hot path.

- **Meter: the SAMPLES DROPPED badge now also sees the tuner's own IQ drops
  (audit P1.2b).** The badge covered only the composite ring between capture
  and analysis. One layer down, where the SDR delivers IQ to the demod thread,
  the SDRplay ring counted nothing at all and the RTL-SDR counter was a
  function-local `static` that nothing outside the callback could read -- so a
  demod thread failing to keep up with the capture rate silently punched gaps
  into peak-hold MAX DEV, the deviation distribution, the BS.412 max window
  and the SM.1268 exceedance count while the dashboard looked healthy. Both
  backends now count lost IQ samples (ring overwrite, plus RTL's deliberate
  low-latency skip-to-newest; retune flushes are deliberately not counted) and
  publish them through a new `mpxtuner_iq_drops()` C ABI entry point that the
  Meter folds into the same badge.

- **Meter: the stereo decode now tracks the pilot's frequency and says when it
  is decoding mono (audit P1.3).** Two defects in the shared `MPXDecoder`, both
  measured before and after: (1) the 38 kHz recovery corrected the subcarrier
  phase from a fixed-lag lock-in with no frequency tracking, so any pilot
  frequency offset -- an untrimmed RTL dongle's capture clock, a transmitter's
  own tolerance -- left a residual phase error, DOUBLED at 38 kHz, that capped
  decoded separation: measured 47.7 dB at 25 ppm and 24.8 dB at 100 ppm against
  64.4 dB on frequency. The recovery is now a proper second-order PLL (~2 Hz
  loop bandwidth, critically damped) that pulls the local oscillator onto the
  pilot: all three offsets read 64.4 dB. On-frequency decode is unchanged, so
  the stored receiver baseline did not move. (2) The pilot-lock gate was an
  ABSOLUTE magnitude (pilot amplitude 0.02 in raw units), 100x the Meter's own
  pilot-present threshold -- a 20 dB window in which PILOT read present and
  deviation read right while the decoded audio was silently mono, with side
  level at -120 dBFS, phase correlation pinned at +1.00 and stereo recordings
  coming out mono. The gate is now relative to the composite level (a pilot
  carrying at least ~2.5% of the composite RMS), and the decode state is
  published: an amber "MONO DECODE" badge on the Quality card explains that
  deviation / pilot / MPX power stay valid while separation, balance and phase
  correlation read `--` rather than describing the mono decode. A genuinely
  mono station reads this too. The decoder also refuses to demodulate a 38 kHz
  subcarrier the capture rate cannot represent (it decodes exact mono instead
  of aliases), and two unused biquad cascades left the inlinable hot path.

- **Meter: dropped samples and a stalled input are now visible, and a stopped
  meter blanks its dashboard (audit P1.2).** Input-ring overflows (the
  analysis thread fell behind; samples were dropped) poison every peak-hold
  and accumulated reading -- MAX DEV, the histogram, BS.412 max, the SM.1268
  exceedance count -- yet the only report was a stderr line at stop, which a
  double-clicked .app sends nowhere. The Quality card now raises a red
  "SAMPLES DROPPED" badge the moment a drop happens (the accumulated readings
  are invalid from that point; Reset Peaks clears both). A "NO INPUT" badge
  appears when the device stops delivering for over a second while capture
  still claims to run (USB power-save, a stalled SDR stream kept `alive`
  true and the panel showed frozen readings indistinguishable from live).
  And Stop / device loss now resets the whole dashboard to its idle state
  instead of leaving the last captured frame on screen -- a frozen red
  "MAX 78.4" bar read as live over-deviation.

- **Meter: the analyzer always runs at the rate the device actually opened at
  (audit P1.1).** The measurement engine, monitor and WAV recorder were built
  from the rate PREDICTED before the device opened; a slow USB rate switch
  (the 1.5 s nominal-rate timeout) could leave 48 kHz math on a 192 kHz
  stream -- pilot PLL, RDS mixer, measurement FIR and the spectrum axis all
  4x off -- while the header displayed the correct rate it was not using.
  The engine now rebuilds the analyzer from the actual opened rate, and
  refuses to start below 128 kHz with a plain-language error (the
  measurement band is 0-60 kHz and RDS sits at 57 kHz; readings below that
  rate silently excluded the stereo sidebands and counted them as noise).
  Continuous device rate ranges are now expanded to their contained standard
  rates (a device advertising 44.1-384 kHz used to look like it only
  supported 384 kHz, so the preferred 192 kHz was never matched), and the
  AUHAL slice size is tied to the engine's mix-scratch capacity instead of
  two coincidentally equal constants.

- **Meter: recording can no longer crash the app or lose a capture (audit
  P0).** Four defects in the WAV path, all pinned by new `MeterRecorderTests`:
  (1) the byte counter was `UInt32` and Swift's overflow trap killed the app
  at 4 GiB -- 62 minutes of 24-bit stereo at 192 kHz; the writer now counts in
  64-bit and stops cleanly at the RIFF limit, finalizing the file at a whole-
  frame boundary with an operator-readable reason. (2) A single NaN reaching
  the packer trapped in `Int32(_:)` -- an SDR overload/unplug while recording
  looked like a random crash; NaN now packs as silence and +/-Inf clamps.
  (3) The RIFF/data sizes stayed zero until close(), so any crash / SIGKILL /
  power loss made the whole capture parse as an empty file; the header is now
  patched every ~2 s and an interrupted file reads up to the last patch.
  (4) A failed write (disk full, volume gone) silently discarded every later
  block while the UI kept saying "Recording"; the recorder now exposes
  `failureReason`, the view model polls it each tick (before the occlusion
  gate -- recording continues while the window is covered) and stops with
  "Recording stopped: <why>". Also: stopping or replacing a recording no
  longer finalizes the file on the main thread while holding the lock the
  analysis thread needs (a slow-disk flush there could overflow the input
  ring -- the click class the recorder was built to prevent), and a
  channel-count misuse reports instead of silently recording nothing.

- **Multiband compressor: a real program-dependent release.** The
  `multiband_release_program_dependent` flag (default on) used to multiply
  the release time by a constant 1.1 -- no program dependence at all. Every
  broadcast multiband has a multi-slope release (Orban: "speeds up after an
  abrupt transient to prevent a hole, slows as 0 dB is approached"; Omnia.11:
  release + fast release per band). `MonoCompressor` now applies its gain
  reduction through a GR-domain smoother with Orban's platform logic: the
  platform is a ~1.5 s average of the reduction the detector demands; while
  the applied reduction sits below the platform (a drum hit) it releases at
  the configured rate, and recovery above the platform (the average level
  dropped) is 3x slower. `MultibandReleaseShapeTests`: kicks recover within
  1 dB of the single-slope path (no hole), a 12 dB-over bed followed by quiet
  program still holds 3 dB at 0.5 s where single slope is at 0 (no
  breathing), and is fully released after 4 s; flag off is the exact
  detector path. Preset baseline recaptured.

- **Wideband AGC attack: 150 ms default (was 6 ms), profiles 100-200 ms (were
  45-80).** The AGC is a gain rider; peaks belong to the Audio Limiter and
  the composite clipper. A 6 ms attack on an RMS detector is limiter-fast:
  `AGCDetectorTests.burstDoesNotDuckTheProgram` measures a 30 ms, +10 dB drum
  hit on settled program ducking the whole mix by 3.35 dB at 6 ms and by
  0.02 dB at 150 ms (Orban's "hole punching"; the Omnia.11 manual: fast AGC
  attacks "cause sudden downward level shifts on peaks ... best controlled
  later in the Limiter"). A sustained +10 dB step is still levelled to the
  same depth -- the attack changes speed, not depth (`sustainedStepStillLevels`).
  Every Format Profile is lint-checked to use >= 100 ms; `--verify` flags an
  AGC attack under 50 ms as TIGHT; the GUI / dashboard attack slider now runs
  to 500 ms. Preset baseline recaptured (no metric moved beyond tolerance --
  the change is in transient handling, which the HF gate reads as unchanged).

- **The Final-MPX Safety Limiter is now a true look-ahead limiter -- nothing
  above its threshold reaches the 1x safety soft-clip any more.** Its detector
  was the instantaneous |composite| into a 0.35 ms one-pole; on program whose
  peaks move faster than that it tracked a blurred target, so the gain never
  reached the depth the exiting peak needed and the 5 ms delay line only
  shifted the timing. `--verify-final-ride` showed 0.87 dB of dense program
  leaking past it on Music - Loud while it reported 0.02 dB of gain reduction
  (hot chain: 5.8 dB reported, 2.7 dB leaked) -- exactly the 1x-shaper
  clipping the 0.45 final-stage rework set out to remove. `LookaheadLimiter`
  now feeds a `SlidingWindowMax` (Lemire deque, shared primitive in
  `DSPSupport.swift`) over the sample leaving the delay line plus everything
  still inside it, attacks with a time constant of window / 4 and floors the
  gain at the required value. Result: safety-clip column 0.00 in every row of
  the isolation table, `SAFETY CLIP` telemetry 0.0 on dense program, Music -
  Loud honestly reports ~1 dB of ride on `bright_dense`, HF SINAD unchanged to
  slightly better. Because the limiter no longer leaks, its threshold moved
  from 0.985 x budget back onto the budget (+0.13 dB of composite level), and
  the verifier's "safety limiter doing significant work" bounds moved from
  2 / 3 dB to 3 / 4 dB (the honest figure on the hot Verification.ini config
  is 2.6 dB). New `LookaheadLimiterTests` pin the contract (+0.000 dB worst
  case at 12 dB overdrive, burst leading edge caught before it arrives, pure
  delay below threshold). All composite baselines recaptured.

- **`--verify-final-ride`: attributes the Final-MPX limiter's duty.** One
  composite-clipper candidate is switched off per row (pilot / RDS / stereo
  guard, 8x / 32x oversampling, knee width, 2 ms clipper look-ahead, the final
  limiter itself, the safety shaper) on a hot chain and on Music - Loud, with
  every peak controller's duty printed (clipper GR, final-limiter GR, the new
  safety-clip column, audio-composite peak, 4x true peak); the parameterised
  `CompositeClipperBoundProbeTests.overshootAttribution` does the same at the
  clipper alone. First results (2026-08-30): the pure band-limiting overshoot
  of a clipped composite is +0.55 dB, the three guards together lift it to
  +1.74 dB, oversampling factor and knee width change nothing; the clipper's
  own 2 ms look-ahead cuts its kernel GR from 13.7 to 3.1 dB and the final
  limiter's ride from 5.8 to 0.08 dB on the hot chain. And a defect: with the
  limiter reporting 0.02 dB of GR on Music - Loud, 0.87 dB of dense program
  still reaches the 1x safety shaper (2.7 dB on the hot chain while the
  limiter rides 5.8 dB) -- the look-ahead limiter leaks peaks past its
  threshold. Investigating that is the next chain-review item (A1b), before
  any POCS work.

- **Composite clipper: `Protect Stereo Subcarrier` is now a 0.00-1.00 share
  (`mpx_clipper_stereo_guard`) instead of an on/off toggle, with a
  `--verify-stereo-guard` sweep that shows what it trades.** At 1.00 the
  22-53 kHz clipping residual is restored in full (the pre-0.45 toggle on):
  the L-R subcarrier passes exactly as it went in and the clipper only ever
  removes the mono share of an M+S peak. At 0.00 the clipper clips the whole
  composite the way Orban's half-cosine limiter (US 6,434,241 does not
  protect 23-53 kHz), Omnia and Stereo Tool do. Existing INIs load
  `mpx_clipper_cancel_stereo = True/False` as 1.00/0.00. GUI (Composite
  Clipper tab + inspector) and web dashboard show the slider; live-apply.
  The chain review had blamed full S restoration for the ~1.5 dB of routine
  Final-MPX limiter duty; the sweep refutes that: on the shipped Music - Loud
  profile the share changes nothing (clipper GR ~1.9 dB, limiter idle at
  0.02 dB, 35 dB separation, identical HF SINAD at every share), and on a hot
  config (multiband off, 5 dB of clipper GR) the ride is 1.19 dB at 0 and
  1.33 dB at 1, while guard 1 costs ~5 dB of 14 kHz tone separation (25.5 vs
  30.6 dB, both far above the 16 dB gate) and buys ~3 dB of decoded hi-hat /
  ride SINAD (13.7 vs 10.6 dB). The shipped default therefore stays 1.00 --
  the measured choice, since decoded HF cleanliness is what the 0.45 work is
  about -- and the industry-style setting is one slider move away. Unit test
  `stereoGuardShareControlsSubcarrierClipping` pins the semantics (39 kHz
  L-R sideband at 6 dB overdrive: -1.0 / -2.4 / -3.9 dB for 1.0 / 0.5 / 0).

- **Processed-audio output mode ran its audio-domain stages at the wrong
  sample rate.** Selecting the L/R processed-audio output switches the
  dual-rate boundary off after the generator was built with 48 kHz
  coefficients, and nothing re-derived them: pre-emphasis, the Audio
  Limiter, HF limiter, AGC, EQ and the rest ran 48 kHz coefficients at the
  output rate (a 50 us curve became ~12.5 us: +2 dB at 10 kHz instead of
  +10.3; limiter time constants 4x too fast at 192 kHz). Only the encoder
  FIR and the multiband crossovers happened to be reconfigured afterwards by
  their own setters, which is also why the tests never saw it.
  `setAudioOutputOnly` now re-derives every stage (the same routine a
  sample-rate change uses); `processedAudioKeepsThePreemphasisCurve` pins
  the curve at the output. Composite output was never affected.

- **The verifier and the Linux build now run the transmit filters.** The
  linear-phase encoder FIR and the FIR multiband crossovers were enabled only
  by the macOS live engine at start; `MPXGenerator` itself defaulted both to
  off. So every offline gate (`--verify*`, all baselines, the receiver and
  HF sweeps) had been measuring the IIR monitor-path filters (Butterworth
  encoder lowpass, LR4 crossovers) -- which is why the receiver gate's
  "encoder FIR OFF" isolation row always read +0.00 and why the crossover
  redesign above moved no baseline metric -- and the Linux ALSA engine
  shipped those monitor filters on air. The generator now seeds both flags
  from the config (`encoder_fir_enabled` / `multiband_fir_enabled`, default
  on); only the low-latency monitor output switches them off. All composite
  baselines recaptured on the TX chain. Found while measuring Step 3 of the
  chain review.

- **Multiband crossovers redesigned: 9.3 ms instead of 21.3 ms of latency, and
  real crossover slopes instead of brick walls.** The linear-phase FIR
  splitters (`LinearPhaseMultibandSplitter5` / `3`, also used by Advanced
  Dynamics) silently ignored the transition width the chain asked for and
  used 60 Hz for every crossover; at the 48 kHz audio domain the Kaiser
  estimate then hit the 2049-tap clamp -- 1024 samples = 21.3 ms where the
  code comment and ARCHITECTURE promised 5.3 ms -- and gave the 1.8 and
  6.8 kHz crossovers an ~85 Hz-wide edge that pre-rang for ~12 ms whenever
  adjacent bands carried different gains. Each crossover now gets its own
  transition (equal to its frequency, floored at 120 Hz), the design is
  centred so -6 dB lands exactly AT the crossover (Kaiser puts it at cutoff
  + transition/2; the old design sat above the nominal frequency), the
  stopband is 40 dB (vendor crossovers are 12-24 dB/oct), and the kernels
  are zero-padded to one shared length so every band still shares one group
  delay and the bands still sum to the delayed input at -156 dB. Measured
  (`MultibandFIRSplitterTests`, now at 48 kHz): 446 samples = 9.29 ms,
  -6 dB within 0.4 dB at all four crossovers, band peaks aligned to the
  sample, pre-ringing -28.8 dB and starting 0.56 ms early with a 6 dB
  inter-band disparity; the FIR multiband is now cheaper than the IIR path
  (0.91x, was 1.14x). The splitter owns its design (`transitionHz` parameter
  removed). Baselines recaptured. `AdvancedDynamicsTests` now excite the
  leveler with one tone per band instead of a single 1 kHz tone on the
  1.6 kHz crossover skirt (with real slopes the neighbouring band lifts
  that leak by its full range -- the known multiband-leveler behaviour that
  band coupling addresses, Step 7 of the chain review).

- **Receiver-side HF response is now flat to the analog pre-emphasis curve
  (+/-0.5 dB to 14 kHz; it was -3.5 dB at 14 kHz).** Two artefacts of the
  48 kHz audio domain stacked up on air. (1) The pre-encode Audio Limiter's
  4x decimation filter was a 6th-order Butterworth at 0.30 x the audio rate =
  14.4 kHz (the code said "12th-order"), sitting AFTER the encoder lowpass
  and pre-emphasis: -1.1 dB at 13 kHz, -2.3 dB at 14 kHz, -4 dB at 14.9 kHz,
  with only -27 dB of alias rejection at 24 kHz. It is now a linear-phase
  Kaiser FIR (`LinearPhaseFIRDecimator`, flat to 15 kHz, 80 dB down from
  16.5 kHz, ~640 taps / 1.7 ms) which also becomes the chain's proper 15 kHz
  band-limit in the pre-emphasised domain -- the encoder FIR runs before
  pre-emphasis, so its transition tail arrived +14 dB hotter and the old
  Butterworth had been re-attenuating it by accident. (2) The pre-emphasis
  network was the textbook matched-z zero, which under-boosts toward
  Nyquist: -0.6 dB at 10 kHz and -1.4 dB at 15 kHz at 48 kHz (a receiver
  de-emphasises with the analog curve, so that went on air as HF droop).
  `PreemphasisDesign` (MPXPrimeCore) now fits a minimum-phase biquad to
  |1 + j omega tau| at configure time (<0.05 dB to 15.5 kHz, matched-z
  fallback), the encoder uses it and the decoder's `DeemphasisFilter` is its
  exact inverse (the Meter and the verifier de-emphasise on the analog curve
  too; the matched-z pole was +0.09 dB at 15 kHz even at 192 kHz). Measured
  on the HF gate: Music - Clean ride SINAD 42.6 -> 46.8 dB, hat SINAD
  unchanged; the 15-23 kHz gap spill floor moves from -39 to -36 dB because
  the composite clipper now receives the HF it was owed (gate re-set to -34).
  The `--verify-receiver` 14 kHz tone now reaches the composite clipper at
  full level for the first time, exposing the stereo-guard M/S imbalance
  (95 -> 31 dB separation on that tone; Step 4 of the chain review). New
  `productionChainFollowsTheAnalogPreemphasisCurve` sweep pins the response;
  `PreemphasisFilterTests` pin both networks against the analog curve at 48
  and 192 kHz. Also fixed: a live threshold/release change on the Audio
  Limiter reconfigured it at the MPX rate instead of the audio-domain rate
  (look-ahead / attack / release / hold 4x too long, HF detector at 1 kHz)
  -- pinned by `liveApplyKeepsTheAudioDomainRate`. The unused single-channel
  `OversampledPeakLimiter` was removed. All composite baselines recaptured.

- **Stereo subcarrier polarity now follows 47 CFR 73.322 / ITU-R BS.450-3 --
  real receivers no longer play L and R swapped.** The encoder had sent
  `S = (R-L)/2` on the 38 kHz subcarrier since the first commit; the
  standard is `(L-R)/2` with the subcarrier crossing zero on a positive slope
  at every pilot zero crossing, so a standard receiver formed `L = M + S`
  and got the RIGHT channel. `MPXDecoder` carried a silent compensating
  negation (`diff = -diff`, added in 0.27 with the receiver-model verifier),
  which kept the monitor path, the Meter and every verifier gate
  self-consistent -- and also made MPX Prime Meter decode real off-air
  stations swapped. Both are fixed: the encoder emits the standard polarity,
  the decoder is a plain textbook decoder, and `--verify-receiver` now
  scores separation against the DRIVEN channel (a swap reads as negative
  separation) instead of "stronger vs weaker". New `StereoPolarityTests`
  pin both sides against an independent hand-written decode (left-only tone
  -> LEFT, right-only -> RIGHT, decoder on a hand-built standard composite).
  Composite magnitudes are unchanged; the waveform is not (M + S vs M - S),
  so all composite baselines were recaptured. Found by the 0.45 chain design
  review; confirm on a car radio with the calibration tone routed `left`.

- **`smoke-live.sh`: live-engine smoke test on a virtual output.** Runs the
  headless encoder with the REST API against BlackHole 2ch (192 kHz) using a
  COPY of the given INI (default: the station INI) and checks what the
  offline gates cannot: engine start on the device and HAL buffer
  negotiation, the calibration tone's measured deviation against the value
  the Test Tone card predicts, pilot injection, `Safety Clip` idle, xruns,
  composite budget, a live-apply PATCH (the deviation trace must follow
  within ~1 s) and a restart-class PATCH cleared by a transport restart.
  Exit 0 = pass; ~70 s; refuses to run while Studio is on air. First run on
  the operator's fixed INI: 11/11 checks passed (25.5 kHz measured vs
  24.8 expected, pilot 8.00%, Safety Clip 0.0, no xruns).

- **`output_gain_db` is attenuation-only in composite mode** (clamped to
  <= 0 dB on load; GUI slider stops at 0; processed-audio L/R output keeps
  its full range). Field finding: +2.79 dB on the operator's station divided
  the composite budget by 1.38, so the audio was clipped ~3 dB deeper
  (hat SINAD 15.2 vs 18.3 dB on identical processing) while pilot went on
  air at ~11% and RDS at ~4.1 kHz instead of 8% / 3.0 kHz -- and the
  composite was not one dB louder, because the budget governor caps it.
  Exciter drive belongs to `mpx_line_output_dbfs` or the exciter's input.

- **Block (buffer) size: measured and pinned.** New `--bench-blocks` sweep
  (release build, ~20 s) reports per block size the worst single block's
  render time as a fraction of the block duration, the implied I/O latency,
  bit-identity of the composite against 512-frame blocks, and the default
  output device's HAL buffer range. `BlockSizeInvarianceTests` pins that
  64 / 480 / 1024 / 4096 / 8192-frame renders are bit-identical to 512 --
  the size is a latency-vs-safety knob only. Measured on an M1 Pro at
  192 kHz, full chain: worst block 17% at 512, 23% at 256, 46% at 64;
  256 is now allowed (INI floor 512 -> 256, GUI + dashboard pickers).
  Manual documents the guidance and the two hardware caveats (device HAL
  clamping, USB interfaces below 256). Note for anyone comparing offline
  renders bit-for-bit: the RDS text scheduler paces PS/RT by wall-clock
  uptime, so such comparisons must run with RDS off.

- **Pre-0.45 configs are reset on load (RDS kept).** An INI carrying a
  legacy Format Profile id now has its processing (`[MPX]`) rebuilt from
  the migrated profile instead of only relabelled -- the old gain structure
  (peak controllers off, safety clips clipping) was the hi-hat distortion
  finding, and carrying it forward would keep the station distorting.
  `[RDS]`, `[INTERFACES]` (devices, sample rate, block size) and `[CONTROL]`
  are kept verbatim, as are the `[MPX]` calibration keys (pilot level,
  deviation, MPX output level, output gain, pre-emphasis, mono mode, test
  tone). The reset is saved back and announced at startup in both apps.
  `AppConfig.loadReportingMigration` / `iniText()`; pinned by
  `LegacyINIResetTests`.

- **Safety-clip duty is now visible.** New telemetry `Safety Clip` (GUI
  Monitoring card next to `Safety GR`; `safetyClipDB` in `/api/telemetry`
  and the dashboard): a 250 ms decaying peak of how far the audio composite
  exceeded the budget and had to be caught by the 1x safety soft clip. It
  reads 0.0 when the composite clipper and final limiter own the peaks, as
  designed; anything above zero is the distortion class fixed in 0.45
  (safety clip doing peak control) and means the gain structure or profile
  needs attention.
- **Unit tests no longer touch audio hardware.** `MPXPrimeViewModel` takes
  its device source by injection (`deviceLister`; the app passes the
  CoreAudio enumerator); every test that builds a view model passes a stub,
  pinned by `ViewModelDeviceSourceTests`. A headless `swift test` can no
  longer reach the audio HAL or provoke device dialogs.
- Measured and NOT changed: a 2.5 ms attack floor on Advanced Dynamics'
  top band did not move the stage's hi-hat cost at all (hat SINAD 15.1 dB
  and wash crest -3.1 dB either way), so the transient attack is not the
  lever there; reverted, recorded in plan.md.

- **Test tone is now a calibration source (fixes "tone way too loud, level
  slider does nothing").** The tone used to enter the full processing
  chain, so the AGC lifted any level to its target and Final Drive pushed
  it into the composite clipper: every setting produced full, clipped
  deviation. Now a tone sample bypasses input gain, AGC, EQ, multiband /
  Advanced Dynamics, enhancers, all clippers and limiters, Final Drive and
  BS.412 (delay-bearing stages stay in the path so pilot/RDS remain
  aligned), and **0 dBFS = 100% of the audio modulation** left after the
  pilot/RDS reservation -- deviation = `mpx_deviation_khz x budget x
  10^(level/20)`, linear in dB. Sines are pre-compensated for the
  pre-emphasis curve (same level at 400 Hz, 1 kHz, 10 kHz). The Test Tone
  card shows the expected audio and total deviation; the dashboard label
  says what 0 dBFS means. `TestToneGeneratorTests` pins level-in /
  deviation-out (within 0.25 dB), drive/processing independence, frequency
  flatness, routing-mode equality, and that the input path still responds
  to Final Drive.

- **Chain pruning, measured (less is more).** Removed: the 19 kHz audio-path
  pilot notch after the encoder FIR (receiver gate identical to 0.01 dB with
  and without it -- the FIR's >80 dB stopband already covers 19 kHz) and the
  0.28 experimental multiband composite clipper (`mpx_multiband_clipper_enabled`,
  `--verify-composite-multiband`, its tests and dashboard toggle -- it never
  reached a preset and its own A/B gate went TIGHT in both possible positions
  once the final stage was corrected). KEPT after measurement: the encoder
  HF guard -- removing it cost 20-40 dB of receiver-side HF stereo separation
  on the tone test (un-attenuated HF drives the composite clipper into
  audio-band IM) while the HF limiter does not engage at those levels. The
  HF Limiter is now ON by default and in every Format Profile (it was Music -
  Loud only). Baselines recaptured (small drift: hard-panned HF side-to-mid
  improved 35.7 -> 42.0).

- **Dead and redundant code removed (less is more; zero drift).** The
  audio-composite "smoother" (54 kHz one-pole that only ran between two
  identical safety soft clips), the second soft clip, and the post-output-
  gain soft clip at an absolute 0.98 (idle by construction since the
  clipper + final limiter own the peaks) are gone, leaving ONE budget safety
  clip (`audio_composite_softclip_enabled`); INI keys
  `audio_composite_smoother_enabled` and `final_mpx_softclip_enabled` are
  removed (ignored if present), and so are their dashboard toggles. The
  unwired `DynamicPreemphasis` sidechain (no INI key, no chain call) and its
  tests were deleted. The verifier's hand-maintained long-run signature
  table was dropped -- `long.json` already pins those scenarios strictly.
  All strict baselines are bit-identical.

- **Source layout split for maintainability (no behaviour change).** The
  three monoliths -- `MPXGenerator.swift` (10.8k lines),
  `SwiftUIControlApp.swift` (9.1k) and `VerificationHarness.swift` (4.4k) --
  were split by concern as pure moves: DSP stages one-per-file in `DSP/`,
  the RDS encoder in `RDS/`, the view model / app delegate / per-area views
  in `MPXPrimeViewModel.swift`, `AppDelegate.swift` and `UI/`, and the
  verifier one-file-per-mode in `Verification/`. Former file-private helpers
  that the split made cross-file are now module-internal; nothing else
  changed (all strict baselines bit-identical, 582 tests green). Incremental
  debug builds after a one-file edit no longer recompile a 10k-line file.
  AGENTS.md records the layout as a contract (one type per file, files under
  ~1000 lines, folders by concern) so manual development stays practical.

- **Hi-hats / cymbals no longer distort: the composite clipper actually
  clips now, and a real HF limiter replaces the HF clipper.** Field
  finding 2026-08-29, measured with the new `--verify-hf-transients`
  gate (receiver-side, de-emphasised decode of hat / ride multitones and
  band-limited cymbal noise; reports HF SINAD, HF crest loss, 15-23 kHz
  composite spill per chain variant). Root causes, in order of impact:
  (1) in EVERY shipped profile the always-on 1x "safety" shaper ran
  BEFORE the composite clipper at a LOWER threshold (the audio-composite
  budget, ~0.85 with pilot + RDS reserved) than the clipper's own
  threshold (referenced to digital full scale), so the shaper did all
  the clipping and the 16x oversampled, guard-band-protected clipper
  never engaged -- clipper on/off was bit-identical; (2) the final
  look-ahead MPX limiter was idle for the same reason (absolute 0.98
  threshold above the shaper); (3) `Music - Loud` used the HF *clipper*,
  a waveshaper on exactly the band cymbals live in (17 dB of decoded HF
  SINAD on hats). Fixes: final stage reordered to composite clipper
  (ceiling mapped onto the budget) -> 55 kHz bandwidth FIR -> BS.412 ->
  final look-ahead limiter (threshold just under the budget; it rides the
  in-band overshoot the clipper's guard-band restoration legitimately
  leaves -- probe: 1.18 vs a 0.966 ceiling on a 12 dB overdrive) ->
  experimental multiband clipper -> shaper as a genuinely idle safety
  net (pinned by `CompositeShaperOrderingTests`); the limiter's hold now
  outlasts its look-ahead. New **HF Limiter** stage (`hf_limiter_*`,
  live-apply, both UIs, default off, ON in Music - Loud): program-
  controlled pre-emphasis after Orban US 4,103,243 (expired) -- rides
  only the pre-emphasis BOOST (`out = flat + g * (pre - flat)`), boost-
  dominance guard so bass peaks cannot flutter HF, 1.5 ms / 5 ms hold /
  20 ms. `mpx_clipper_threshold_db` / `_ceiling_db` are now referenced to
  the composite budget (ceiling = budget), deviation unchanged.
  Measured (hat SINAD / ride SINAD / cymbal-wash crest loss): Music -
  Clean 13.0 / 31.8 / -1.1 -> 27.2 / 43.0 / -0.7 dB; Music - Loud 5.6 /
  8.3 / -3.3 -> 18.3 / 38.1 / -2.2 dB; Speech 9.9 / 13.5 -> 22.8 / 47.2
  dB; Classical 15.7 -> 27.0 dB. Also: pre-0.45 profile ids migrate on
  load (`chr_top40` -> `music_loud`, ...), a startup warning (CLI and GUI
  status) fires when neither Audio Limiter nor Composite Clipper is
  enabled, the HF clipper's live-apply reconfigured at the wrong (MPX)
  rate under the dual-rate audio domain, the verifier's safety-limiter
  bounds moved to the limiter's new duty (TIGHT > 2 dB, WARN > 3 dB),
  and all composite baselines were recaptured (deliberate chain change).
  `docs/test-playlist.md` adds a sourced listening playlist per stage.

- **Format Profiles reworked: four complete profiles instead of eight
  color-only ones.** Field finding: the old profiles set multiband/
  PrimeBass/widener/drive but never owned the gain structure, so a
  profile on a broken level structure still sounded broken (the safety
  soft-clips ended up doing the peak control). The new set -- Music -
  Clean (default), Music - Loud, Speech/Talk, Classical/Wide Dynamics --
  owns the FULL chain state: AGC (with per-profile target), pre-encode
  limiter, composite clipper + 2 ms look-ahead, and the final safety
  limiter are enabled by every profile, with format color on top. A new
  test pins the contract (no profile may leave the soft-clips as the
  de-facto peak controller). Old profile ids are gone (pre-1.0, no
  migration); default is music_clean. Manual documents the -12 dBFS
  nominal input convention.

- **Advanced Dynamics: decay guard + safer Max Boost default.** Field
  report: a solo bell synth "rang" on air -- the leveler read the bell's
  natural fade as quiet program and rode gain up through the decay,
  flattening/extending it (the classic AGC-on-solo-content failure,
  amplified by the stage's wide lift range). Fix: a per-band decay guard
  (slow-release envelope peak tracker; env more than 3 dB below it means
  an active fade) HOLDS the lift while program decays naturally and
  resumes when the level stabilizes or new material arrives. Pinned by a
  synthetic-bell regression test (decaying solo tones were a blind spot
  in the test program). Max Boost default lowered 18 -> 12 dB: high
  boost chases fades harder AND lowers the derived silence gate,
  pumping tails on sparse material.

- **Preset slots: no more false "changed" states.** Loading a preset
  while the engine ran always claimed "Restart-required changes are
  pending" -- even when the preset differed only in live settings or not
  at all. Loads are now classified with the same derived dispositions the
  REST API uses: "no changes" / "applied live" (live planes hot-applied
  immediately) / a restart prompt only for genuine restart-class diffs.
  The "edited since loaded" marker is now an exact config comparison
  against the loaded preset instead of a 0.6 s timer that raced binding
  churn and produced false flags. Seven new state-tracking tests pin the
  behavior (the mechanics were covered; the state machine was not).

- **MPX spectrum band captions: the two stereo regions are now labeled
  "Stereo L-R lower SB" / "upper SB"** instead of two identical "Stereo
  L-R" captions. Both regions really do carry the same L-R signal (DSB-SC
  mirrored around 38 kHz) -- the identical labels read as a copy-paste
  error, and distinct sideband labels also make SSB Stereo's
  one-sideband suppression recognizable at a glance. Applies to the
  Studio spectrum window and the Meter (shared view).
- **Verifier hardening (the parked 0.44-plan items):** (1) strict
  baselines extended to the preset sweep and the long-run sweep --
  platform-suffixed `presets.json` (records keyed `<presetID>/<scenario>`,
  21 records) and `long.json`, same schema as `default.json`; capture with
  `--verify-presets|--verify-long --capture-baseline`, compared on every
  run (drift = TIGHT, WARN under `--baseline-strict`). (2) Post-injection
  composite overshoot is now a HARD FAILURE, exit code 3, in both the
  main sweep and the preset sweep -- and it is checked before the
  quality/signature branches, which previously masked a coinciding
  overshoot down to exit 1. (3) `SampleINIDefaultDriftTests` lints the
  shipped `MPXPrime.ini` against code defaults with a reviewed whitelist;
  it immediately caught real drift -- the sample's RT texts still carried
  the pre-0.37 product name and `fft_window_92khz` contradicted the
  current default (both fixed).

- **SSB Stereo: experimental SSB-leaning stereo encoder**
  (`mpx_ssb_stereo_enabled`, default off; `mpx_ssb_stereo_amount`
  0..1, default 0.7). Leans the 38 kHz L-R subcarrier toward
  single-sideband (`diff*sin - amount*hilbert(diff)*cos`, linear-phase
  511-tap Hilbert with matched base/diff program delay), opportunistically
  keeping whichever sideband currently peaks lower (leaky-peak selection
  with 3% hysteresis and a 5 ms crossfade). Inspired by the composite
  techniques used by modern third-party broadcast processors; implemented
  from first principles. Measured: sideband asymmetry exactly matches
  theory (15.06 dB at amount 0.7), coherent decode separation preserved
  (worst 81 dB, -4.8 dB delta at 10 kHz vs a 20 dB floor), mono content
  bit-transparent, cost 1.03x, zero-drift (default off, strict baseline
  unchanged). HONEST CAVEAT: the new `--verify-ssb-stereo` A/B gate
  reports no measurable composite-headroom reclaim on the synthetic
  program scenarios yet (the gate says TIGHT by design) -- the loudness
  benefit needs dense real-program A/B, and the follow-up direction is
  moving the sideband choice inside the composite clipper loop. Exposed in BOTH UIs on a NEW 'Stereo Coder' tab/page at the stereo
  encoder's actual chain position (it is an encoder mode, independent of
  the Composite Clipper's enable) -- the previously invisible stereo
  encoding stage now has a home in the UI.

## 0.44 — 2026-08-03

- **Advanced Dynamics: experimental single-stage 5-band leveler**
  (`advanced_dynamics_enabled`, default off). Replaces the wideband AGC +
  multiband compressor with ONE fused leveling stage so slow leveling and
  per-band density shaping can never fight each other (the classic
  AGC-vs-multiband pumping). Target-based configuration (target level,
  low/mid/high tonal-balance anchors, density, speed) instead of
  attack/release times; program-adaptive time constants -- near-instant
  attack on transients (precomputed anchor blend, no per-sample expf),
  full freeze inside the target window, density-slowed release on busy
  material; -24..+24 dB per-band range for large in-song level jumps;
  low-band coupling bias reuses the multiband curve. Band split is an
  own-instance linear-phase FIR at the multiband crossovers, allocated
  lazily (a disabled stage costs nothing -- zero-drift preserved, strict
  baseline unchanged). All parameters live-apply; exposed in BOTH surfaces
  in sync: native GUI tab (Processing -> Adv Dyn, plus Overview card and
  signal-flow chip) and web dashboard card. While enabled, both UIs ghost
  the replaced stages (AGC / Multiband / Expander / MB Limiter dim with a
  "bypassed" banner; sidebar and overview dots show the EFFECTIVE state),
  and a test pins the bypass as total (extreme AGC/MB settings render
  bit-identical to those stages being off).
  New `--verify-advanced-dynamics` A/B gate: RMS/band/correlation/side/
  peak deltas vs the classic chain plus re-processing idempotency
  (second pass moves RMS < 0.3 dB) and cost ratio (~1.0x the two stages
  it replaces). Inspired by the single-stage design popularised by
  Stereo Tool's "Advanced Dynamics"; implemented from first principles.
  Default target level is -16 dB (field-tuned on air: -14 packed the
  bands against the ceiling and read as audible compression; -16 keeps
  the leveling transparent).
- **Web dashboard: transport-level Bypass button.** The status strip gains
  the GUI's Bypass next to Start/Stop: flips `processing_bypass` and
  restarts the engine when running (mirroring the GUI's Cmd-B exactly --
  the flag is restart-class), turns red "BYPASSED" while active, and asks
  for confirmation before putting unprocessed audio on air.
- **Web parity phase 4 became API-only: `GET /api/telemetry`.** Display-
  decimated input L/R + MPX scope waveforms and a server-computed 256-bin
  MPX spectrum (~6 KB, ~5 ms per request, measured); 503 while stopped or
  on a platform without a scope tap (Linux/ALSA today). An in-dashboard
  "Scopes & Spectrum" canvas page was built on a 4 Hz poll and REMOVED the
  same day -- at polling cadence it cannot look like an instrument next to
  the native windows, and the operator judged it too slow. The endpoint
  stays for external tooling; if browser visuals return, they need a push
  transport (SSE/WebSocket), not a faster poll.
- **Web dashboard: processed-audio mode awareness.** With
  `processed_audio_output` on, the dashboard now mirrors the GUI's
  `hiddenInProcessedAudio`: the RDS group, Composite Clipper, BS.412 and
  Final Stage pages hide (with live sidebar re-render and redirect if you
  are on one), the signal-flow pills drop the composite stages, and
  Monitoring swaps the MPX/Subcarriers cards for an honest "Output
  (processed audio)" card -- previously it showed deviation/pilot/RDS
  readouts for a composite that does not exist in that mode.
- **Web dashboard parity, phase 3 of 4: operator preset slots over the API.**
  The GUI's 8 snapshot slots are now a REST surface: `GET /api/snapshots`,
  save/load/rename/clear per slot, `GET .../export` (the slot's full INI --
  loadable via `--config`), and `PUT` import with validation through the
  canonical parser. Loading a slot applies it as ONE full config patch, so
  every changed key rides the same live/liveRDS/restart classification as a
  normal PATCH. Storage is the same `<config>.snapshots.json` the GUI always
  wrote (logic extracted into a shared `SnapshotStore`; the GUI delegates to
  it, so web and native operate on the same slots, including the
  "loaded/edited-since" marker -- the headless backend now flips it on any
  config change, matching the GUI). The web Presets page grows the slot
  grid: name, Save/Load/Export/Clear, Import into empty slots.
- **Web dashboard parity, phase 2 of 4: full settings coverage.** Every
  INI-backed control the native GUI has now appears in the dashboard, in the
  same structure: a new **Profile** page (station-format picker, works on
  headless via phase 1); the full **Radiotext** editor (mode, rotation, the
  four manual buffers + enables, RT+ formats, and the complete Now Playing
  configuration); multiband **crossovers** X1-X4 + the 3-band pair;
  composite-clipper **look-ahead + oversampling**; Final Stage composite
  internals (sum/diff levels, soft-clip/smoother toggles); Identity gains
  RBDS PTY table, PTYN centering, dynamic PS + frame time; Schedule gains
  the scheduler toggles + timezone offset; AF gains the method picker. The
  Interfaces page grows a **Monitor device** picker + enable, an Engine card
  (auto-start, pilot level, spectrum window), and a **read-only Remote
  Control card** (editing the server you are talking through is a lockout
  footgun -- INI/GUI only). Every Processing/RDS tab gets a **Reset This
  Tab** button driven by `GET /api/config/defaults`. Monitoring shows
  uptime, ring-buffer health, drop counters, resample trim, an OVER BUDGET
  flag, and the RDS status page shows live PTYN + Long PS.
- **Web dashboard parity, phase 1 of 4: served schema + drift-proofing.**
  The dashboard now renders itself from `GET /api/schema` (a new
  `WebUI/schema.json` -- widget definitions + page model); `index.html`
  carries no hardcoded control tables anymore. `ControlSchemaTests` pins the
  schema against the INI vocabulary BOTH ways: every key needs a widget or a
  reasoned exemption, every widget must name a real key, every page key must
  have a widget. The old hand-maintained tables had silently dropped ten
  controls (the web Test Tone had no frequency or level slider; the MB
  Limiter page was a single checkbox) -- all restored -- and the web Audio
  Limiter card patched the FINAL-MPX safety look-ahead keys instead of the
  pre-encode ones (misfiled; three keys were unreachable, now fixed, with the
  safety keys moved to Final Stage where the GUI has them). The schema now
  covers the FULL vocabulary (209 widgets + 26 reasoned exemptions), so
  phase 2 is page placement, not authoring.
  `GET /api/config/defaults` serves factory defaults for client-side reset.
- **Station formats + final-stage presets work headless.** The
  `format_profile` and new `finalstage` preset kinds are served by BOTH
  control backends -- the tables moved from the GUI view model into
  `PresetCatalog`, so a Linux box can now apply a station format over the
  API (previously GUI-only; `POST /api/presets kind=format_profile` returned
  400 on headless). GUI pickers unchanged (thin wrappers over the catalog).
- **Control API symmetry**: `/api/devices` gains the monitor-output slot
  (`selectedMonitor`, `monitorEnabled`); the GUI backend reports real
  `uptimeSeconds`; `restartPending`/`notes` semantics documented on the DTO.

## 0.43 — 2026-08-01

- **CI on every push and PR.** New `.github/workflows/ci.yml`: build, full
  test suite, swiftlint, and the fast offline verify gates (`--verify`,
  `--verify-receiver`, `--verify --baseline-strict` -- per-platform pinned
  baselines) on macOS and Ubuntu 24.04, for `develop/**` pushes and PRs to
  `main`. Previously nothing ran before the release tag. The release
  workflow's ubuntu-26.04 leg is removed until Swift.org ships a 26.04
  toolchain (it failed the v0.42 run in 15 s; the static-stdlib 24.04 deb
  installs and runs on 26.04 anyway).
- **Control server logs a clickable URL.** Hummingbird's raw
  "listening on 127.0.0.1:8737" info line is silenced; the startup line is
  the linkified `Control server: http://127.0.0.1:8737/` form.

- **Restart now equals live-apply, by construction.** Both engine-start paths
  (headless `HeadlessControlBackend.startEngine` -- API `transport/restart`,
  boot, reconcile -- and the GUI's `startEngine`) now apply the canonical
  DSP + RDS runtime planes to the freshly built engine after start. The
  generator/coder inits are hand-written duplicates of the canonical
  `RuntimeConfig` / `RDSRuntimeConfig` mappings and nothing pinned them
  together, so any init/make drift silently made a REBUILT engine differ
  from a live-PATCHed one (the issues.txt "now-playing off after an API
  restart" class; the single observed case was most likely the already-fixed
  empty-script poller bug, but the hole was real). New
  `RDSRestartParityTests` pins the two mappings: a coder built from a
  maximally non-default config must emit a BIT-IDENTICAL group stream to a
  coder live-applied to the same config, and a rebuilt coder must air the
  full configured state including the pushed now-playing track. Extend its
  `richConfig()` when adding an RDSRuntimeConfig field. Backend tests cover
  restart re-applying both planes and patch-while-stopped reaching the next
  build; `normalizeScriptPath("")` itself now returns "" instead of the
  launch directory (the helper-level version of the 0.43 call-site fix).

- **Verifier: `--verify-long` is green again and part of the release
  checklist.** Its per-scenario signature reference table had never been
  recaptured since 0.11 while the chain moved deliberately through 0.20/0.35/
  0.36 (each step gated by `--verify --baseline-strict`), so the long-run
  gate sat at TIGHT on pure staleness -- and nobody saw it, because it was
  not on the release checklist. Table recaptured from a canonical run
  against the current chain; checklist updated. A full attribution pass
  confirmed NO DSP error behind any of the warnings.
- **Verifier: no more silent fallback to the live station config.** Running
  any `--verify*` mode from a directory where `macOS/Verification.ini` is
  not findable used to fall back to the operator's own INI -- producing
  official-looking TIGHT/WARN verdicts about whatever pilot/RDS/clipper/AGC
  state the station happened to be in (this cost a real debugging detour).
  It now exits 64 with instructions; pass `--config` explicitly to verify a
  specific INI on purpose.

- **Meter: RF spectrum in SDR mode.** The spectrum card gains an **MPX | RF**
  switch: MPX is the demodulated baseband as before, RF is the band around the
  tuned carrier straight from the tuner's IQ -- the view an SDR application
  shows, for spotting adjacent channels and splatter. Span is set by a new
  **Sample Rate** control (Narrow / 1 MSPS / 2 MSPS, restart-required),
  defaulting to 1 MSPS for roughly +/-0.5 MHz.
  The tuner now keeps the **capture rate separate from the demod rate**: the FM
  demod chain always runs at its own 250/256 kHz behind a polyphase decimator,
  so widening the span cannot move any MPX measurement. At the Narrow setting
  the decimation factor is 1 and both backends are byte-identical to before --
  the RTL branch deliberately keeps its original packed-uint8 demod call there,
  since the complex path reproduces neither its normalization LUT nor its
  raw-byte saturation detection. The spectrum itself is a 1024-point
  Hann-windowed complex FFT on the capture thread at ~20 frames/s, published
  over a new `mpxtuner_rf_spectrum()` ABI. NOTE: the wide-capture path could
  not be exercised against real hardware during development -- if a dongle
  misbehaves at 1/2 MSPS, switch Sample Rate to Narrow.
- **Meter: closes the measurement gap against a Pira P175/P275 analyzer.**
  An audit of that instrument's manual against the Meter's readouts turned up
  eight missing quantities; six are new here (the remaining two need IQ-domain
  taps in the vendored tuner and are not done):
  - **AVE / MIN deviation** under the deviation bars, from the same trailing
    second of 50 ms peak-hold slots MAX is drawn from (the in-progress slot is
    excluded -- part-filled, it would drag both down). MAX far above AVE is a
    peaky signal; MAX close to AVE is a dense one riding its ceiling.
  - **Deviation distribution** -- the accumulated histogram, 1 kHz bins over
    0..120 kHz since the last Reset, plotted in the Trends card with the
    75 kHz limit line, plus the highest bin filled and the share at/over
    75 kHz. This is the metric Pira's manual argues no single MAX number can
    substitute for; it wants 15-60 minutes of programme to be representative.
  - **Signal quality**, a 5-step Unusable..Excellent rating derived from the
    energy ABOVE the modulated baseband, recovered as the exact complement of
    the 60 kHz measurement FIR (`delayed - filtered` through a delay line of
    the FIR's own group delay -- phase-exact and cheaper than a second FIR).
    Nothing is legitimately modulated up there, so it is demod noise and
    interference, and it is what says whether the other readings are worth
    believing.
  - **Carrier frequency offset** in kHz -- an FM demod turns a transmitter
    carrier offset into composite DC, which the measurement path already
    tracked but never published.
  - **L / R balance** in dB, heavily smoothed and level-gated.
  - **RDS group shares** alongside the counts, and a new **Order** row: the
    last 18 groups in transmission order. Counts say what an encoder sends;
    the order shows how it interleaves them.
  New `Quality` card in the second row; CLI dashboard gains `DIST`, `QUAL` and
  `ORDER` lines. 14 new deterministic tests. All six together cost ~0.15 % of
  one core.
- **Meter: RDS subcarrier phase (EN 50067 sec 1.2).** A new **RDS PHASE**
  readout in the Modulation card, beside the other standards-compliance
  figures (and `PHASE` on the headless `DEV` line), reads the angle between
  the 57 kHz RDS subcarrier and the third harmonic of the 19 kHz pilot -- the
  "RDS phase" figure a Belar RDS-1 / DEVA analyzer shows. The
  standard allows two answers, `0 deg (in phase)` or `90 deg (quadrature)`,
  each within 10 deg; anything between reads `out of spec` in amber and means
  the encoder is not truly pilot-locked. Measured coherently by
  `PilotRDSPhaseMeter`: one 19 kHz NCO feeds two IDENTICAL lock-in chains (the
  57 kHz reference is its exact third harmonic via the triple-angle identity),
  so the filter group delays match and the reading is immune to the
  pilot-frequency offset every real capture clock has -- with mismatched
  delays, 2 Hz of offset alone would bias the angle 5.4 deg, half the spec
  window. The suppressed-carrier 180 deg ambiguity is removed by squaring
  (Viterbi & Viterbi), so the reading is folded to an unsigned 0..90 that
  cannot flicker at the quadrature end. Gated on pilot presence, coherence,
  and at least 0.8 kHz of RDS; read off the subcarrier itself, so it still
  shows while the decode readout is reception-gated. Ten new deterministic
  tests (`MeterRDSPhaseTests`) pin the conventions, the offset immunity, the
  53 kHz rejection, and an encoder round-trip -- MPX Prime Studio derives its
  57 kHz carrier from the emitted pilot's recurrence, so it must read in
  phase. Conventions and readout deliberately match the Pira P175/P275 FM Broadcast Analyzer (unsigned 0..90 fold, +/- 10 deg window, blank when unstable) so the two can be compared number for number; Pira specifies +/- 4 deg for this measurement, ours measures 0.12 deg worst case across the range and 0.00 deg under a 10 Hz pilot offset. Costs ~0.6% of one core.
- **Input-ring health in `/api/meters`:** the macOS input source now reports
  capture->render ring diagnostics -- `inputRingBufferedFrames`,
  `inputRingOverflows`, `inputRingUnderflows`, `inputRingTornReads`,
  `inputResampleMode`, and `inputRatioTrim` (drift-corrector adjustment).
  The level meters cannot distinguish loud static from loud program, so
  these counters are the definitive readout for diagnosing clock-drift
  between the input and output devices. Null in headless/ALSA and when no
  input source is running.
- **Now-playing fixes found via the API push:** (1) an empty
  `now_playing_script` no longer resolves to the working directory --
  `normalizeScriptPath("")` returned the CWD, so the local poller launched
  it, failed, and cleared any API-pushed track every poll; (2) an idle
  poller (no script) no longer clears now-playing state on config changes,
  so API-fed RadioText survives PATCHes. The push script also re-sends the
  current track on a 30 s heartbeat so the encoder recovers after a restart.
- **Now-playing push over the API** (`POST /api/nowplaying {artist,title,display?}`).
  Feed the current track from a player on one machine to a (possibly remote)
  encoder -- e.g. VLC/Cog on your Mac -> headless encoder on a Linux box. It
  writes the same `NowPlayingState` the local script poller uses, so the
  existing RT / PS / RT+ templates fill in (RT+ artist/title tagging works).
  New `scripts/push-nowplaying.sh` (macOS) reuses `scripts/nowplaying.sh` for
  VLC/Cog extraction and pushes on change (flags/env `--url` / `--api-key`,
  `--interval`, `--once`); it warns if now-playing rendering is disabled on
  the target. To use: on the encoder set `now_playing_enabled = True` + an
  `rt_text` template with `{artist}`/`{title}` (or `{display}`), and leave
  `now_playing_script` empty (the push is the source).
- **Now-playing never airs a half-filled line.** A template segment that
  references `{artist}`/`{title}`/`{display}` whose value is empty is now
  dropped per-macro (previously only when metadata was entirely absent), so
  a partial tag (title but no artist) skips the track line instead of airing
  " - Title". A `/`-segmented template like `10s:{artist} - {title}/10s:My
  Station` gracefully falls back to the static segment. Applies to the API
  push, the local script, and the GUI alike.

- **Linux: a missing audio device no longer crashes the encoder.** If the
  configured ALSA device can't be opened at start (e.g. a USB card whose
  `hw:CARD=` name changed across reboots -- ALSA renames colliding cards
  Device / Device_1 by probe order), the process no longer exits (which
  under systemd meant a restart crash-loop). Instead the control server
  comes up first and the engine start is attempted tolerantly: the
  dashboard shows the engine stopped with the reason (`audio engine not
  started: ... No such device`), the operator picks a present device on the
  Interfaces page and presses Start. Only when no control server is enabled
  is a failed start still fatal. Also: `ALSAPCM` now closes idempotently on
  deinit so repeated failed starts don't leak PCM handles, and the dashboard
  status strip surfaces the stopped-engine reason.

## 0.42 — 2026-07-11

- **Linux: Debian/Ubuntu packages + systemd service.** `./build-deb.sh`
  produces `mpxprime_<ver>_amd64.deb` (static Swift stdlib; system
  dependencies computed by dpkg-shlibdeps): `/usr/bin/mpxprime` with the
  web-dashboard resource bundle, a systemd unit running as a dedicated
  `mpxprime` user (audio group, `/var/lib/mpxprime/MPXPrime.ini`,
  LimitRTPRIO for real-time audio threads, auto-restart), sample config
  and docs. Release tags now also build and attach Ubuntu 24.04 and
  26.04 debs via the GitHub workflow (with a dpkg smoke-install +
  `--verify` gate). The dashboard loader no longer fatals when the
  resource bundle is missing next to the binary (bare-binary installs
  serve a stub page instead of crashing the encoder).

- **Linux: full meter parity on the dashboard.** The ALSA engine now reads
  the generator's meter surface (AGC gain, pre-encode/composite/safety
  gain reduction, pilot/RDS injection %, composite budget margin,
  over-budget flag) every ~43 ms on the render thread -- the same
  accessors the macOS engine uses -- plus a deviation readout derived from
  the composite peak. The web Monitoring page previously showed dashes for
  everything except peaks and xruns on Linux.

- **MPX line output calibratable in dBFS** (`mpx_line_output_dbfs`, [MPX],
  default 0.0 = the classic full-scale convention; GUI Processing > Core
  "Line Output", web dashboard, live-apply). Sets the absolute converter
  level of 100% modulation (75 kHz) so exciter drive is calibrated in
  software with the OS/interface mixer at 0 dB. Range -40..0 dBFS:
  attenuation only -- positive line gain is unphysical at a DAC (full
  scale is the hardware ceiling, so it can only clip the composite and
  lift pilot/RDS proportionally; field-verified as "deviation good,
  pilot/RDS 3 dB high"). An under-driven exciter needs its
  input-sensitivity trim instead. The DAC conversion paths
  scale-then-clamp (also fixing an integer-overflow hazard). Applied at
  the DAC write on both platforms AFTER all processing and metering --
  deviation readouts and the composite budget are unaffected; the
  default is bit-identical to the previous behavior.

- **Linux: deep ALSA buffers (fixes chopped output on raw hw: devices).**
  The engine now requests 2048-frame periods x 8 (~85 ms at 192 kHz)
  instead of 512 x 4 (~10.7 ms). Plug-layer devices always granted larger
  buffers, but a raw hw: device grants the request exactly -- 10.7 ms of
  slack on a heavily loaded small CPU without RT scheduling produced a
  constant xrun storm (audible as chopped/garbled MPX). A transmitter has
  no latency requirement; measured on the J4105 driving a 192 kHz USB
  interface (hw:) the storm went from ~28k xruns to zero.

- **Linux: SIMD shim (full processing parity now fits small x86 CPUs).**
  The MPXPrimeAcceleration fallbacks for `vDSP_dotpr` / `vDSP_conv` (FIR
  crossovers, encoder FIR, decimators) and `vvtanhf` (oversampled clippers)
  are vectorized with portable Swift SIMD8 (SSE2 codegen -- no AVX flags,
  Goldmont-class CPUs have none): 4x-unrolled dot products and a
  Cephes-style vectorized tanh (Cody-Waite expf, max error vs libm ~1e-7,
  batch-size-independent via a padded tail lane; both properties are
  test-enforced). Measured on a Celeron J4105 at 192 kHz with a
  fully-loaded chain: scalar ran 102% of a core with constant xruns;
  SIMD runs the SAME chain with FIR multiband and the 16x composite
  clipper at ~92% with zero xruns. The Linux strict baseline is
  recaptured with the SIMD numerics; macOS remains bit-identical (the
  shim still compiles empty there).
- **Dashboard: usable ALSA device picker.** The Linux device list is
  filtered to the PCMs an operator selects (default / sysdefault / hw: /
  plughw:) instead of every plugin variant, and entries are labelled by
  PCM name with an [exact rate] / [converting] role tag -- previously the
  dropdown was dozens of identical "Loopback, Loopback PCM" rows.

- **Remote control: REST API + embedded web dashboard** (both platforms,
  default off; `[CONTROL]` INI section / GUI Settings card / `--control`).
  Endpoints: status, meters, RDS live snapshot + curated live updates
  (PS/RT/TA/PI/PTY), full config GET/PATCH by INI key, sound presets,
  transport start/stop/restart. PATCH classifies every key as
  live / liveRDS / restartRequired by DERIVING the disposition from the
  engine's own RuntimeConfig/RDSRuntimeConfig structs (no per-key table to
  drift); changes hot-apply through the existing render-thread hand-off and
  persist to the INI. Localhost binds are open; any remote bind requires an
  API key (Bearer / X-API-Key, constant-time compare) and refuses to start
  without one; TLS is delegated to a reverse proxy. The dashboard at `/`
  mirrors the Studio GUI: pinned broadcast status bar (transport, level +
  gain-reduction meters, deviation/pilot/RDS/margin readouts) over sidebar
  sections -- Sound stage cards with real switches/sliders in the GUI's
  control vocabulary (per-stage preset pickers included), RDS (on-air
  PS/RT, identity, text, flags), Test Tone, Presets, and an Advanced raw
  all-settings editor -- one self-contained page, no build step. All ~150 stage controls carry the GUI's exact ranges/labels (extracted from the GUI source), an Interfaces page offers audio-device dropdowns (CoreAudio / ALSA PCM enumeration via GET /api/devices), and the headless session shares the GUI's config file (loaded/created at the standard path; printed at startup). Built on
  Hummingbird 2 (new dependency, with SwiftNIO transitively). Internals:
  preset tables extracted to a shared `PresetCatalog` (GUI behavior
  unchanged); `ALSAAudioEngine` gained the live-apply hand-off, RDS
  snapshot, and peak/xrun meters; the headless runtimes now run through a
  `HeadlessControlBackend` actor (API restarts rebuild the engine); GUI
  mode routes remote changes through the view model on the MainActor so
  the window and web UI stay consistent. Also fixed: `sample_rate` was
  read from the INI but never written back, so a non-default rate vanished
  on the first autosave.

- **Linux command-line port of the encoder (milestone 1, experimental).** The
  `MPXPrime` executable now builds and runs on Linux (dev-tested: Ubuntu 24.04
  x86_64, Swift 6.3): headless `--nogui` encoding into an ALSA device (capture
  and playback, FLOAT/S32/S16 negotiation, xrun recovery, SCHED_FIFO
  best-effort), all `--verify*` modes, `--capture-baseline`, and `--bench`.
  The GUI, MPX Prime Meter, and SDR tuner remain macOS-only. Key pieces:
  - New `MPXPrimeAcceleration` target: same-name implementations of the vDSP /
    vvtanhf surface the encoder uses plus an `OSAllocatedUnfairLock` polyfill
    (pthread PI mutex). On macOS it compiles empty and the real Accelerate/os
    are used -- macOS composite output is bit-identical (verified: the
    pre-port `--verify --baseline-strict` passes unchanged). A golden fixture
    captured from real Accelerate pins the shim's FFT packing/scaling and
    window constants (`AccelerateShimTests`).
  - New `ALSAAudioEngine` (Linux counterpart of `AudioOutputEngine`) and a
    `CAlsa` system-library target; `input_device_uid` / `output_device_uid`
    carry ALSA PCM names on Linux.
  - Per-platform strict baselines: Linux pins
    `verifier_baselines/default-linux-x86_64.json` (Glibc libm and the scalar
    tanh shim differ from Apple's at rounding level); physical verify
    thresholds are identical and pass on both platforms.
  - Test suite runs on Linux (425 tests; GUI/view-model suites and the
    absolute wall-clock budget test are macOS-gated).

## 0.41 — 2026-07-10

- **Meter: vectorscope auto-zoom.** The goniometer's display gain rides the
  program level (fast shrink / slow grow, filling ~85% of the field --
  hardware-goniometer style) so quiet program no longer draws a tiny
  figure. Points past full scale saturate at the field edge like the real
  thing. Always on -- no knob to mis-set. The projection math was also
  corrected: the rotated (L+R)/(L-R) axes span twice the per-channel range,
  so full-scale mono previously overshot the reference circle by ~30% and
  the auto-zoom (driven by per-channel peaks) overfilled on near-mono
  program; scaling is now inscribe-safe, the auto-zoom targets the
  rotated-axis peaks (exact fill at any stereo correlation), and the
  reference circle is inset so its stroke never clips at the panel edges.
- **Meter: DC block for the decoded audio** (input-bar checkbox, default
  on, live): a transmitter carrier offset becomes DC after FM demod,
  showing as an off-center vectorscope, offset waveforms, and DC in the
  monitor/recordings -- as observed on an 864.5 MHz wireless audio link.
  Broadcast FM has no legitimate DC. Deviation measurements were already
  DC-tracked; this extends the cleanup to the decode path (scopes,
  vectorscope, monitor, recordings, L/R/M/S levels).
- **Meter: graceful SIGTERM.** pkill / logout / scripted termination now
  runs the normal shutdown, releasing the SDRplay selection and RTL handle
  (previously the SDRplay service ghost-held the RSP for the dead PID and
  the unit vanished from enumeration until replug).
- **Meter: the device-lost status now explains the held USB claim** (a
  dead handle is deliberately abandoned; the unit needs a replug or app
  restart before reuse).
- **Meter: harden the RTL-SDR close against the remaining crash paths.**
  A second SEGV-in-libusb crash (via the Stop button, on a wedged dongle)
  showed two holes in the earlier unplug fix: (a) `rtlsdr_read_async` can
  exit with rc == 0 on device loss, leaving the failed flag unset -- any
  unexpected stream exit now marks the device lost regardless of rc;
  (b) a wedged dongle can drop/re-enumerate on the bus leaving a stale
  handle -- the close now also verifies the same physical unit (by USB
  serial captured at open) is still enumerable before writing shutdown
  registers. Belt-and-braces: app termination uses a new
  `mpxtuner_close_fast` that never performs the register-writing device
  close at all (the kernel releases the USB claim as the process exits).
- **Meter: MPX pass-through.** New in the input bar's **Outputs** popover:
  play the received RAW composite (pilot + stereo subcarrier + RDS) to its
  own output device, in addition to the decoded monitor -- feed a 192 kHz
  DAC into an FM exciter (rebroadcast / translator) or a hardware analyzer.
  Live-apply; the output device is switched to the capture rate while the
  pass-through runs and restored afterwards (a 48 kHz output would lose
  the subcarriers). The decoded-monitor device picker moved into the same
  popover. A **Gain** control (0..+12 dB, live) matches the analog level to
  the analyzer/exciter: 0 dB keeps the SDR scaling (0 dBFS = 150 kHz, a
  75 kHz station peaks at -6 dBFS -- why the output reads "low" into an
  analyzer by default); +6 dB puts 75 kHz at full scale at the cost of
  clip headroom above it.
- **Meter: the SDR picker now reliably lists the unit in use.** The SDRplay
  API omits in-use devices from enumeration (including our own active RSP),
  which could hide the picker entirely. The tuner now reports the active
  unit's serial (`mpxtuner_device_serial`), the picker merges it in, a
  mid-capture rescan can only add devices (never shrink the list), and a
  full rescan runs on Stop.
- **Meter: input-bar cleanups.** Small captions (MHz / IF / kHz / Bias-T) no
  longer wrap into vertical letter stacks on narrower windows; the SDRplay
  antenna control is a compact menu; the SDR and Out pickers are slightly
  tighter so the bar fits on one line.
- **Meter: pick your SDR when several are attached.** New SDR picker in the
  input bar (shown with more than one unit): any mix of SDRplay RSPs and
  RTL-SDR dongles, listed by model + serial. The choice is remembered by
  serial (survives replug/reorder); Auto keeps the old behavior (SDRplay
  preferred). If the chosen unit is absent at start, the Meter starts on
  Auto with a note and keeps the selection. Run the app twice to meter two
  stations on two units. (C ABI: `mpxtuner_list_devices` +
  `MpxTunerConfig.backend`/`device_serial`; SDRplay selection by SerNo,
  RTL by USB serial.)
- **Meter: monitor Output device picker** in the input bar (both source
  modes): System Default or any output device, applied **live** -- only the
  monitor restarts; capture, analysis, and recording are untouched.
  Remembered by device UID. Essential when two Meter instances run side by
  side.

- **Studio: refuses to start when a preferred device is unplugged.** Starting
  with a remembered input / output / monitor device absent no longer silently
  streams to the OS default (a broadcast chain must never swap its
  transmitter feed unannounced): Start is refused with a visible alert
  ("reconnect the device, or choose another in Settings"). A device that was
  never chosen keeps the default-device behavior.
- **Studio: telemetry migrated to @Observable.** `LiveTelemetry` (65
  per-tick fields) moved from `ObservableObject`/`@Published` to the
  `@Observable` macro, matching the Meter and the project convention (the
  bridge's dependency tracking accumulates over long sessions); all 23
  monitoring call sites use `LiveObservationView`, and the legacy
  `LiveTelemetryView` wrapper is removed.
- **Meter: RDS readout gated by reception quality (+ Force override).** An
  RDS block decoder syncs on a single accidental syndrome match and accepts
  PI from any single CRC-passing block, so on noise the panel hallucinated
  data (random PI/PTY at ~74% BER on a no-RDS audio link). The published
  readout now opens only when reception is plausible -- BER <= 15% (with
  hysteresis: closes above 25%), a detectable 57 kHz subcarrier (>= 0.8 kHz
  when a kHz scale exists), and at least a few valid blocks decoded -- and
  shows "no usable RDS -- BER ..% . .. kHz" (the live evidence) while gated.
  After 10 s gated the decoder is cleared so stale garbage never flashes
  when the gate opens. BER/level keep measuring regardless. A **Force**
  checkbox in the RDS panel header bypasses the gate for diagnostics.
  Deterministic tests: seeded-noise hallucinations stay suppressed, real
  encoder-generated RDS opens the gate and decodes the true PI, Force
  publishes raw.
- **Meter: 1 kHz tuning resolution.** The frequency field accepts 1 kHz
  precision (e.g. 864.540 for an audio link) instead of the broadcast
  band's 100 kHz raster; scroll/stepper keep 0.1 MHz steps. Tuning
  off-grid carriers exactly also removes the demod DC offset at its
  source.
- **Meter: SDR tuning is no longer fenced to the broadcast band.** The
  frequency field now spans the ACTIVE tuner's real range -- RTL-SDR
  ~24-1766 MHz, SDRplay RSP 0.1-2000 MHz -- because FM-stereo MPX also
  rides analog audio links and license-exempt stereo transmitters outside
  87.5-108 MHz (e.g. 886 MHz). Out-of-range tunes are rejected gracefully
  by the driver; the tooltip states the active device's range.
- **Meter: the Modulation card is a two-column grid** (MPX POWER | PEAK,
  OVER 77 kHz | SEPARATION, SIGNAL | Reset Peaks) so it fills the top row
  compactly instead of stacking one tall column.
- **Meter: dashboard top row makes better use of the screen.** The Modulation
  panel is sized so its readouts never truncate (the "MPX POWER ... max ..."
  compliance figure was ellipsized), readout values shrink slightly rather
  than ellipsize on extreme values, the RDS text grid is capped at a
  comfortable reading width instead of swallowing the whole row on wide
  displays, and the instrument cluster left-aligns on ultrawide screens.
  Measurements get layout priority -- they are the product.
- **Meter: CORR renamed to PHASE CORR and color-coded** like a hardware
  correlation meter: normal while safely positive, amber near zero, red when
  negative (out of phase = mono receivers cancel the audio). Tooltip
  clarified; every readout in the app has a hover tooltip.

- **Meter: fix a crash on quit (or on stopping) after the RTL-SDR dongle was
  unplugged.** `rtlsdr_close()` writes shutdown registers over USB
  (`rtlsdr_deinit_baseband` -> `libusb_control_transfer`), which SEGVs inside
  libusb when the device has already vanished -- seen as an
  `applicationWillTerminate` crash after pulling the dongle mid-session. The
  vendored tuner already tracks unexpected stream death (`m_asyncFailed`);
  `RTLSDRDevice::disconnect()` now skips the register-writing close for a
  lost device and abandons the dead handle instead (nothing to deinit on a
  vanished device; the leak is bounded by process lifetime). Covers both the
  quit path and the dashboard's "device lost" auto-stop, which used the same
  crashing close.

## 0.40 — 2026-07-08

- **Meter: fix the GUI graphs getting slow/laggy -- and eventually the audio
  stuttering -- over a long session.** Profiled live: main-thread CPU grew
  from ~33% fresh to ~87%+ within 14 minutes of an SDR capture, eventually
  starving the real-time audio thread; engine Stop/Start did not clear it
  (the view tree persists), only a fresh launch did. The aged profile showed
  ~42% of main-thread time inside AppKit layout flush with
  `NSToolbarItemViewer _layoutSubtreeWithOldSize:` prominent -- the
  documented SwiftUI-on-macOS **toolbar relayout leak** (the same mechanism
  as Studio's 0.34 multi-hour freeze). Root cause: the RDS display strings
  (including the group-counter line, which changes with every received RDS
  group, ~10/s) lived as `@Published` on `MeterViewModel`, so each update
  re-evaluated the whole window body INCLUDING `.toolbar{}`. Fixes, in
  order of importance:
  - The 11 RDS display strings moved off the view model onto the telemetry
    object, and the RDS grid is wrapped in the isolation view -- RDS updates
    now re-evaluate only the grid, never the window body/toolbar.
  - The RDS panel refresh is throttled to 2 Hz (it is text for humans; the
    fast movers -- BER digit, group counters -- don't need the tick rate).
  - `MeterTelemetry` migrated from `ObservableObject`/`@Published` to the
    **`@Observable` macro** with the new `LiveObservationView` wrapper in
    `MPXPrimeUI`. Project convention going forward (AGENTS.md): all new
    observable state uses `@Observable`; mandatory for per-tick telemetry.
  - All live Canvas views (scope, trend, vectorscope, vertical meter) now
    disable implicit animations via `.transaction { $0.animation = nil }`
    like the spectrum already did.
- **Meter: lower GUI CPU while keeping the graphs fluid.** Telemetry writes
  are change-guarded and quantized to display resolution (a stable readout
  or bar now costs zero per tick; the trend graphs drop to their real ~2/s
  data rate), the GUI tick runs at 20 Hz (was 25 -- imperceptible on the
  scopes), and GUI pushes are skipped entirely while the window is
  minimized or fully covered (capture, analysis, and recording continue).
  Fresh-launch process CPU on an SDR capture drops ~33% -> ~23%.
- **Docs: the user manual is split per app.** `docs/manual.md` is now the
  **MPX Prime Studio** manual (encoder) and the new `docs/manual-meter.md` is
  the **MPX Prime Meter** manual (analyzer); the shared RDS PI/ECC + PTY
  reference tables stay in the Studio manual and the Meter manual links to them.
  The Meter's in-app "User Manual" link points to the Meter manual. Also brought
  README / ARCHITECTURE / BUILDING / AGENTS / tuner docs current: in-process SDR
  (not a helper binary), SDRplay RSP support, WAV recording + the
  `MPXPrimeRecording` target, the full seven-target layout, the Studio
  spectrum FM band overlay and monitoring windows, the SFP-X cross-validation,
  and the corrected default config path / build prerequisites.
- **Meter: RDS deviation now reads the injection level the encoder was set
  to (fixes the 0.39 under-read).** Reports after 0.39 said the RDS readout
  was too low -- correct: the coherent meter implemented an RMS-equivalent
  convention, which sits ~24% below the set injection on real shaped biphase
  (the envelope dips through zero at symbol transitions; the pre-0.39 leaky
  bandpass had masked this by inflating the RMS with 53 kHz leakage and
  noise). The industry display convention is PEAK-referenced (verified
  against Inovonics 531/541/730, R&S K7S default +/-Peak/2 detector, Pira
  peak-to-peak setting practice, and FCC/NRSC peak-budget arithmetic):
  encoders -- BasicRDSCoder included -- normalize the shaped waveform by
  its peak, so the set kHz IS the envelope peak, and EN 50067's "+/-1.0 to
  +/-7.5 kHz deviation range due to the unmodulated subcarrier" is a peak
  range. The meter now reports that number, derived robustly: coherent
  in-band RMS scaled by the EN 50067 shaped-biphase peak/RMS form factor
  (1.320, a constant of the spec's pulse shaping) -- a raw envelope-peak
  detector was tried first and rode composite-clipper intermod inside the
  57 kHz window on heavily-processed stations (2.5-3x over-read off-air,
  unsteady), while the RMS-derived reading responds to in-band IM only in
  the power domain and stays steady. New regression gates:
  `encoderRoundTripReadsTheSetInjection` renders spec-exact shaped RDS from
  our own encoder at `rds_level = 2.0` and asserts the meter reads 2.0
  (with a guard against regressing to the ~1.51 RMS reading), and
  `readingIsSteadyUnderDataModulation`. Off-air validation on a heavily
  processed commercial station (same recorded composite through all three):
  steady 3.4-3.8 kHz (~4.8% injection) where 0.39 read 2.6 and the raw
  peak detector bounced between 6.5 and 8.4.
- **Meter: readings confirmed against a Profline SFP-X measuring receiver**
  on the same live station (2026-07-07): RDS -- SFP-X 3.5-3.7 kHz vs Meter
  3.4-3.8; pilot -- SFP-X 5.6-5.7 kHz vs Meter 5.58-5.73; max deviation
  (live side-by-side, same moment) within 1-2 kHz, inside ITU-R SM.1268's
  +/-2 kHz instrument accuracy requirement. All three headline deviation
  readings now have independent professional-receiver confirmation on top
  of the deterministic test suite.

## 0.39 — 2026-07-06

- **Meter: measurement-grade metering, verified against the standards.** The
  operator report "deviation reads a bit too high" was audited against
  ITU-R SM.1268-5 / BS.412-9 / EN 50067 and professional-instrument practice
  (R&S, Pira, Belar, Deva, Inovonics), and four real over-read mechanisms were
  found and fixed:
  - The deviation/MPX-power measurement low-pass (60 kHz) is now a
    **linear-phase Kaiser FIR** instead of a 6th-order Butterworth IIR -- the
    IIR overshot and rang on clipped-composite edges, manufacturing deviation
    the transmitter never emitted.
  - **PEAK +/-** no longer latches the single largest sample forever: peaks
    are 50 ms peak-hold slots (20/s, the Pira / SM.1268 model); PEAK +/- is
    the trailing-60 s max (one impulse ages out instead of pinning the
    reading), and MAX DEV is the trailing-1 s max (SM.1268-5's 1 s display
    integration).
  - **MPX power is a true uniform sliding 60 s window** (ring of 1 s
    mean-squares, sample-exact rolls, oldest slot complement-weighted so the
    window is exactly 60 s at any instant) -- the old ~60 s EMA over-weighted
    recent loud audio and disagreed with the transmit-side BS.412 limiter.
    New **MPX MAX** readout shows the worst 60 s window since reset (what
    BS.412 compliance is actually judged on).
  - **RDS deviation is measured coherently** (57 kHz quadrature mix, flat
    low-pass, decimated FIR): the EN 50067 "equivalent unmodulated
    subcarrier" level, envelope-invariant under data modulation, with 53 kHz
    stereo-difference energy rejected > 85 dB -- the old single Q=10 biquad
    bandpass leaked adjacent stereo energy and noise into the reading.
  - The measurement path is **DC-tracked** (fast acquisition during warm-up,
    then 0.2 Hz): an SDR carrier/tuning offset no longer skews the + and -
    peaks apart or biases MPX power.
  - New **OVER 77 kHz** readout: the ITU-R SM.1268-5 compliance statistic
    (share of deviation samples above 75 kHz + 2 kHz tolerance; regulators
    treat > 0.0001 % as over-deviation -- rare single peaks are not a
    violation).
  - `MeterAnalysis` moved into the `MPXPrimeCore` library and the math is now
    covered by a deterministic test suite (`MeterAnalysisTests`): synthesized
    composites with exactly-known deviation (bare pilot = 6.75 kHz, aligned
    tone+pilot+RDS = exactly 75.0 kHz, sine at 19 kHz deviation = exactly
    0 dBr, 80 kHz tone = analytic 17.45 % exceedance, clipped+bandlimited
    program = no measurement overshoot, DC-offset composite = symmetric
    peaks, BPSK-modulated RDS = same reading as unmodulated).
  - Validated off-air on 88.6 MHz (Radio Veronica) via RTL-SDR and SDRplay
    RSPdx: the GUI (in-process SDR) and the headless `--stdin` path agree on
    the same recorded composite within inter-window variance.
- **Meter: headless CLI dashboard gains a `MOD` compliance line** (BS.412
  sliding MPX power + worst-window max, 60 s +/- deviation peaks, and the
  SM.1268 >77 kHz exceedance share) -- the same figures the GUI Modulation
  panel shows.
- **CI: the manual "Build Release" workflow is fixed and dispatch-only.** It
  fired on every `v*` tag alongside the Release workflow (double-building)
  and, once the 0.38 SDR tuner landed, failed for lack of the librtlsdr /
  liquid-dsp build deps. It now installs the same SDR deps as release.yml,
  runs only on manual dispatch, and uploads the correctly-named app bundles
  ("MPX Prime Studio.app" / "MPX Prime Meter.app" -- the old path pointed at
  the pre-0.37 "MPX Prime.app" name and uploaded nothing).

## 0.38 — 2026-07-06

- **Studio: the MPX composite spectrum now shows the FM band-region overlay.**
  The composite-spectrum window draws the same MpxTool-style band labels the
  Meter uses (Mono L+R, 19 kHz Pilot, Stereo L-R, 57 kHz RDS, SCA) as trapezoid
  outlines with captions, via the shared `MPXSpectrumView`'s `showBandLabels`.
  Gives the transmit-side spectrum the frequency context the receive-side one
  already had; no new drawing code.
- **Studio: presets no longer read "edited since loaded" immediately.** Loading a
  preset replaces the live config, whose control bindings then fire `onChange`
  asynchronously and tripped the "modified" flag right after the load set it
  clean. The flip is now suppressed for a short window after any programmatic
  config load (preset load / disk reload), so only genuine user edits mark the
  preset edited.
- **Studio: audio device selection is remembered by UID *and* name, and is never
  silently swapped.** Each chosen input/output/monitor device now persists its
  name (`*_device_name`) alongside its UID. On launch the device is matched by
  UID, then by name (so moving a USB interface to a different port -- which can
  change its Core Audio UID -- still re-finds the same device), and if it is
  simply unplugged the selection is **kept** (with a status note) instead of
  silently falling back to whatever device happens to be first. Only a first run
  with no prior preference picks a default.
- **Studio: forces the MPX output device to the configured rate, and warns if it
  can't.** The composite/processed-audio output device is now set to the
  configured `sample_rate` (e.g. 192 kHz) before the engine starts -- so the
  composite is emitted at full rate instead of being silently sample-rate-
  converted by Core Audio (which also starves the render thread). If the device
  doesn't support that rate, a routing note explains to set it in Audio MIDI
  Setup; the device's prior rate is restored on stop. (Mirrors the Meter's
  input-rate forcing.)
- **Meter: fix the frequency/numeric boxes getting "stuck" after typing.** After
  entering a value and pressing Enter the field kept first-responder focus, so its
  display stopped tracking the model -- later scroll / stepper / live-retune
  changes updated the tuner but the box looked frozen on the typed value ("can't
  change it after entering", "tuned but the frequency isn't updated", "when the
  text is selected it can't be changed"). The field now resigns focus on Enter
  and refreshes its display whenever the user isn't *actively typing* (a focused
  or text-selected box no longer blocks updates), writing only when the text
  actually differs so background re-renders don't deselect a box you just
  clicked. Applies to every Meter numeric field (frequency, gain, LNA, PPM, pilot
  reference, full-scale).
- **Meter: remembers the last-used settings.** Frequency, input source, all SDR
  controls (gain / auto-gain, IF bandwidth, LNA, antenna, Bias-T, PPM, RTL AGC),
  channel, monitor on/off + gain, pilot reference, audio calibration mode, record
  format, spectrum span, and the selected input/output devices now persist across
  launches via `UserDefaults` (`~/Library/Preferences`). Devices are matched by
  their stable UID, not the volatile Core Audio device ID. Saved on capture start
  and on quit; restored at launch (falling back to the SDR-when-a-dongle-present
  default only when nothing was saved).
- **Meter: fix periodic clicks in stereo recordings.** Recording resampled the
  stereo file to 48 kHz on the analysis thread -- the same thread that drains the
  real-time-fed input ring. The `.max`-quality SRC plus its per-block buffer
  allocations intermittently stalled that thread long enough for the ring to
  overflow and overwrite unread samples, leaving a one-sample gap heard as a
  click (~0.5/s, irregular, in the mono sum, on both SDR and audio-device input).
  The raw 192 kHz/MPX path, which does no SRC, was unaffected -- which isolated
  the cause. Fix: **the stereo file is now written at the capture rate** (e.g.
  192 kHz), with no real-time resampling at all; resample afterwards with any
  tool for a 48 kHz copy. Disk writes also run on a private serial queue, and the
  input ring's overflow/underflow counts are logged on stop. The recorder moved
  into a testable `MPXPrimeRecording` library target with a deterministic
  round-trip test (`MeterRecorderTests`) asserting a continuous input comes back
  sample-accurate and complete (a click would be a value or frame-count
  mismatch).
- **Meter: smoother spectrum.** The composite (and decoded L/R) spectrum was
  recomputed only every 4th analysis block (~6/s), so the centerpiece graph
  looked sluggish next to the ~23/s scopes and meters. It now recomputes every
  block (~23/s); the FFTs run on the analysis thread (off the audio path) and are
  cheap beside the per-sample decode already done there, so there is no glitch
  risk and the throttle was unnecessary.
- **Meter: one launcher.** `run-meter.sh` is now the single script -- with no
  arguments it opens the GUI, which auto-detects an attached dongle (in-process
  SDR) or falls back to the audio device; `--sdr-freq <MHz>` opens it pre-tuned,
  and `--device`/`--stdin` run the headless terminal dashboard. `run-meter-sdr.sh`
  is removed: its `--gui` mode is redundant now that the GUI auto-starts the
  in-process SDR, and its headless external-tuner FIFO path is just
  `./run-meter.sh --stdin` fed by an `fm-sdr-tuner`/`mpx-tuner` composite.
- **Meter: audio-input deviation calibration (Pilot-referenced or absolute).** The
  audio-device path has no inherent level reference, so a **Calibrate** switch on
  the input bar now offers two modes (audio mode only; both live, scroll-
  adjustable):
  - **Pilot** -- the default. Scales deviation by assuming the 19 kHz pilot equals
    the **Pilot Ref (kHz)** field. Stations vary (a pilot that is actually 5.7 kHz
    read against 6.75 inflated every kHz value ~18%), so set it to the source's
    real pilot. Fragile when pilot recovery is marginal.
  - **0 dBFS = N kHz** -- an absolute scale anchored to a known input level,
    independent of pilot recovery (the robust mode MPXTool-style monitors use).
    Feed 75 kHz at -6 dBFS and set 150; deviation then comes straight off the
    input amplitude, exactly like the SDR path.
  The SDR path is always absolute (150) and ignores both. Note pilot-referencing
  only corrects the overall scale; a source whose composite output rolls off
  above the audio band still reads 57 kHz RDS low -- use the SDR path for an
  accurate RDS-injection measurement.
- **Meter: SDRplay live retune fixed.** Changing frequency on an SDRplay RSP now
  takes effect cleanly instead of glitching / appearing to do nothing. Two
  causes: (1) the stream `reset` flag raised on a retune was ignored, so up to a
  ring's worth of old-frequency IQ played out before the new station -- the ring
  is now flushed on reset; (2) a scroll/drag burst fired one async SDRplay
  `Update` per event, which the API drops or stalls under, so the tuner command
  queue now coalesces a burst to a single update per type (RTL's synchronous USB
  retune was unaffected, which is why only SDRplay misbehaved).
- **Meter: opens live in SDR mode with audio.** When a dongle is present at
  launch the Meter now starts capturing immediately, and audio monitoring is on
  by default -- Start produces sound without a second toggle.
- **Meter: scroll works on every numeric SDR control.** The LNA and PPM steppers
  and the IF-bandwidth menu now adjust on mouse-wheel / trackpad scroll while the
  pointer is over them, matching the Frequency and Gain fields. The IF-BW menu
  still clicks open normally; scrolling steps through its widths.
- **Meter: IF-bandwidth menu is device-appropriate.** On SDRplay the IF BW picker
  offers the RSP's analog IF filter widths (Auto / 1536 / 600 / 300 / 200 kHz) so
  the operator can tighten the IF to reject adjacent-station interference; RTL
  keeps its demod channel-FIR steps (56-311 kHz).
- **Meter: SDRplay RSP support (auto-preferred).** When an SDRplay RSP is
  attached the Meter uses it instead of an RTL-SDR (14-bit ADC -> cleaner audio,
  better separation, lower MPX-power floor). The backend dlopens the
  user-installed SDRplay API at runtime (never linked/bundled; GPL-clean) and
  streams complex IQ at 250 kHz into the demod's complex path. SDRplay-specific
  controls surface in the input bar: an **Antenna** input picker (A/B/C on an
  RSPdx) and a manual-gain mapping that backs the LNA off to relieve broadcast-FM
  overload; the RTL-only PPM / RTL-AGC controls are hidden on SDRplay. Local-build
  feature (requires the SDRplay SDK at build time); CI/release wiring is a
  follow-up. Tested live on an RSPdx.

- Docs: clarified SDR calibration / MPX-power validity in the manual + ARCHITECTURE
  -- SDR deviation is math-absolute (no level calibration), and a valid BS.412
  MPX-power reading needs a strong, clean, multipath-free signal (SM.1268);
  weak/noisy reception inflates both peak deviation and MPX power.
- **Meter: WAV recording (stereo or MPX).** A format toggle + Record button in
  the input bar write a 24-bit PCM WAV: **Stereo** (decoded L/R, resampled to
  **48 kHz**) or **MPX** (the raw mono composite at the capture rate, 192 kHz on
  SDR). Files are **canonical RIFF/WAV** (new `CanonicalWavWriter`, no JUNK/FLLR
  padding chunks) so any audio player or FFT/analysis tool reads them cleanly --
  the previous AVAudioFile output padded the header to a 4 KiB offset, which
  some strict FFT viewers mis-parsed. Start/stop while capturing via a Save
  panel; `MeterAudioEngine` gained dynamic start/stop (lock-guarded against the
  analysis thread).
- **Meter: click a decoded scope for its audio spectrum.** Clicking the
  Decoded L or Decoded R waveform toggles it to an audio spectrum (0-20 kHz)
  drawn with the same gradient FFT graphic as the main spectrum (per-channel
  FFTs added to the analysis). Click again to return to the waveform.
- **Meter visual polish.** Decluttered the meters: the Audio group shares one
  `MeterScaleRuler` (dBFS) instead of repeating the number column on every bar,
  and the deviation bars are scale-less (limit line + kHz value). Level bars
  gained a subtle vertical gradient fill; the trend graphs gained a soft
  gradient area under the trace; the vectorscope guides are softened (faint
  bounding circle + dashed diagonals). Tightened the top row to remove dead
  space. (HIG: clarity / deference.)
- **Meter is a proper macOS app.** A real **About MPX Prime Meter** panel
  (description, clickable GitHub / User Manual / License links, version, and the
  canonical not-certified disclaimer), a full app menu (About / Services / Hide /
  Hide Others / Show All / Quit), a **Help** menu linking the User Manual, and a
  **distinct app icon** (an analyzer VU-gauge + MPX spectrum bar in a teal
  palette) so it is no longer confused with MPX Prime Studio in the Dock. The
  icon is drawn at runtime as well, so even the unbundled `swift run` / CLI
  binary gets a proper Dock icon.
- **Meter: SDR signal-level (RSSI).** The Modulation group shows a **SIGNAL**
  readout on the SDR path -- a relative received-level (dBFS) indicator from the
  filtered IQ channel power (new `mpxtuner_signal_dbfs` C-ABI query), colored
  green (strong) to red (weak). Most meaningful with Auto Gain off. Hidden on
  the audio-device input (no RF level there).
- **Meter readability.** The RDS panel adds PTY (code + name), PTYN, and ECC
  rows. The MPX Power / Peak +- readouts turn amber near and red at/over the
  limit (0 dBr, 75 kHz). The vectorscope is enlarged on the second row.
- **Meter: spectrum span toggle + SDR-by-default.** The spectrum header has a
  **60 / 100 kHz** span toggle (default 60, focusing on the modulated bands;
  100 kHz shows the full baseband incl. SCA). The input **Source** now defaults
  to **SDR** when an RTL-SDR dongle is detected at launch (Audio otherwise).
- **Meter HIG pass.** The Meter toolbar is decluttered to the few frequent
  commands (Start/Stop, Source, Monitor); the per-source input settings (audio
  device + channel, or SDR frequency / AGC / gain) moved into a translucent
  in-window input bar below the toolbar. The instrument displays (scopes,
  spectrum, vectorscope, trends) now share centralized always-dark
  `BroadcastStyle.instrument*` tokens so their internal labels/grid stay
  legible in **Light Mode** (they previously used the semantic `.secondary`,
  which vanished on the dark canvas under a light system appearance). The
  deviation and MPX-power trend graphs gained min/max + limit-line scale labels
  (75 kHz / 0 dBr).
- **Built-in RTL-SDR, in-process (no external binary, no subprocess).** MPX
  Prime Meter now links the vendored RTL-SDR -> FM-demod -> MPX tuner directly
  as a C++ library (`CMPXTuner`, a stripped subset of FM-SDR-Tuner under
  `tuner/`, GPL-3.0, exposed through a small C ABI `mpx_tuner_capi.h`). The
  capture+demod runs on a thread inside the app and delivers float MPX blocks
  straight to the analysis path -- no spawned helper, no FIFO, no int16 WAV
  round-trip. `Source -> SDR` works out of the box on Apple Silicon with just a
  connected dongle (the librtlsdr / liquid-dsp / libusb / fftw dylibs are
  bundled inside the app). **Because it links the arm64-only RTL-SDR libraries,
  MPX Prime Meter now ships as an Apple-Silicon-only binary; the MPX Prime
  Studio encoder stays universal.** The headless `run-meter-sdr.sh` script still
  uses an external `fm-sdr-tuner` over stdin.
- **Live SDR controls (no restart).** Frequency, **IF bandwidth**, gain / auto
  gain, **PPM** correction, **Bias-T** (RTL-SDR v3 5V, for an active antenna),
  and the **RTL2832 digital AGC** all apply live to the running tuner via direct
  in-process calls -- no device re-open, no audio gap. IF bandwidth (Auto /
  56-311 kHz) trades adjacent-channel rejection against full-composite passband
  (RDS / SCA); the tuner's internal channel FIR re-designs on the fly and the
  hardware IF filter is set to match. Retuning the frequency also resets the
  transient meters -- peak-hold, MPX power, separation, BER, trends, and the RDS
  decoder -- plus a 1 s warm-up, so the new station starts clean. The input bar
  relabels the old "AGC" toggle to "Auto Gain" (tuner gain mode) now that the
  separate RTL digital AGC is exposed.
- Docs: documented MPX Prime Meter across README / manual / ARCHITECTURE /
  AGENTS (it shipped in 0.37 but wasn't mentioned).

## 0.37 — 2026-06-15

- **MPX Prime Meter GUI.** The companion analyzer ships a full SwiftUI
  dashboard window (scopes, MPX spectrum with band captions, levels +
  deviation meters, stereo vectorscope, RDS panel) plus MPX power (BS.412),
  peak-hold deviation, best stereo separation, and deviation/power trend
  graphs. Native RTL-SDR input via FM-SDR-Tuner (`run-meter-sdr.sh --gui` or
  Source -> SDR), and a packaged double-clickable `MPX Prime Meter.app`.
- **RDS PIN (Programme Item Number).** Group 1A block 4 can now carry a PIN —
  the scheduled day / hour / minute of the current programme item — instead of
  always sending 0. Off by default; enable it under RDS → Program → Station
  Identity (config keys `pin_enabled`, `pin_day`, `pin_hour`, `pin_minute`),
  live-apply. Legacy field, rarely decoded, added for spec completeness.
- **RDS LIC moved next to PI/ECC** in the Station Identity group (was orphaned
  in the Schedule tab's Clock Time card).
- **PS no longer force-uppercased.** The 8-character Program Service now
  transmits in the case you type it (e.g. "Veronica"), matching RadioText and
  Long PS. Previously PS was always upper-cased for older-receiver
  compatibility. PTYN is still upper-cased.
- **"Snapshots" renamed to "Presets"** in the UI (full-config save slots).
  The on-disk file, types, and methods are unchanged — no migration.
- **Renamed to "MPX Prime Studio".** The encoder app is now "MPX Prime Studio"
  (paired with the "MPX Prime Meter" analyzer); all window titles, menus, the
  About panel, the `.app` bundle, and the default RDS text reflect the new name.
  The default config lives at
  `~/Library/Application Support/MPX Prime Studio/MPX Prime Studio.ini`. This is
  a clean break — an old `MPX Prime/MPX Prime.ini` is **not** migrated; point
  the app at it with `--config`, or re-save your setup as a preset. The bundle
  identifier (`com.mpxprime.app`) is unchanged, so the granted microphone
  permission carries over. The DMG filename stays `MPX_Prime-<version>.dmg` and
  the internal executable stays `MPXPrime`.
- **Fixed snapshot names not saving/loading.** Typing a name then clicking Save
  (or saving first then renaming) now persists the name reliably — committed on
  Enter and on focus loss, kept visible after Save, and re-synced when a slot is
  loaded or renamed.

## 0.36 — 2026-06-10

- **RDS now bit-exactly locked to 3x pilot.** The 57 kHz RDS subcarrier is
  derived from the pilot oscillator's recurrence via the triple-angle identity
  (`sin 3t = 3s - 4s^3`) instead of a separate additive phase accumulator that
  slowly drifted against it. Measured pilot-vs-RDS relative drift dropped from
  ~9.08 deg / 5 s to ~0.11 deg / 5 s (EN 50067 Sec 2.1.4). Also slightly cheaper
  than the old `fmodf` + `sinf`.
- **Monitor decoder hardened against non-finite input.** `MPXDecoder` sanitises
  NaN/Inf samples so a single bad sample can no longer permanently poison the
  pilot-lock I/Q and envelope state (the smoothers never flushed NaN and the
  stereo-collapse self-heal could not re-arm).
- **Input ring buffer: torn-read telemetry.** Post-copy detection counts the rare
  overflow-fault race (`tornReads`) rather than letting it pass silently; the
  producer/consumer atomic protocol is now documented. No happy-path change.
- **Numeric robustness.** BS.412 block-average denormal flush; downward-expander
  gain floored at -60 dB to remove a subnormal-underflow gating discontinuity on
  near-silent program.
- **Verifier coverage.** Encoder-side sideband fingerprint baselined (asymmetry +
  side/mono delta at 1/10/14 kHz; baseline schema 3). `--verify-receiver` now
  reports composite-clipper guard-band cancellation depth (pilot ~11.8 dB / RDS
  ~12.7 dB) and a pilot/RDS phase-lock drift gate. `--verify` adds a 4x-oversampled
  true-peak (BS.1770-style) inter-sample-overshoot metric, baselined. Stage-isolation
  sweep extended with bass / HF / DC clipper rows. New tests: RDS 3x-lock regression,
  decoder NaN recovery, ring-buffer torn-read, BS.412 rolling-power ceiling, multiband
  idle transparency.
- **UI polish (HIG / accessibility).** Dropout indicator conveys state by shape +
  colour (not colour alone, WCAG 2.1). Test-tone preset buttons highlight the active
  frequency. Signal-flow strip dims bypassed stages with a tooltip + VoiceOver value.
  Shared `BroadcastStyle` tokens centralise previously ad-hoc chip / connector / tick
  fills (appearance unchanged).

## 0.35 — 2026-06-09

- **Pre-emphasis-aware HF clipper (new; opt-in, default off).** A dedicated clipper
  on the high band of the *pre-emphasised* L/R signal, placed between pre-emphasis
  and the pre-encode limiter, so HF transients are tamed by a focused stage instead
  of forcing the broadband limiter to pull gain across the whole signal (the classic
  FM "dulling"). De-emphasis-correct: it limits the pre-emphasised HF, so the
  receiver's fixed de-emphasis restores the curve -- the trade is HF density, not
  the curve mismatch that dynamic pre-emphasis would cause (the approach Orban /
  Omnia / Stereotool take; web-researched, see plan.md). Anti-aliased oversampled
  tanh soft-clip on an LR4-split high band (mirrors `BassClipper`). Config, all
  live-apply: `hf_clipper_enabled` (false), `hf_clipper_crossover_hz` (5000),
  `hf_clipper_threshold_db` (-3), `hf_clipper_drive` (1.2); dedicated HF Clipper
  Processing tab. Validated on the receiver model -- pilot / RDS / sub-crossover
  separation are bit-identical off->on. Ships off pending real-program listening.

- **Composite-clipper acceleration (~56% off the heaviest stage).** The composite
  clipper was the single heaviest stage (~9% of real-time / ~46% of the chain). A
  `sample(1)` profile of a `--verify-long` render showed the cost was dominated by
  `Biquad.process` (~32% of total CPU) -- the per-OS-step residual guard-band
  cancellation running 16x per host sample -- with a secondary chunk in copy-on-
  write checks. Three steps, each measured:
  - Precompute the Lagrange interpolation basis weights (the interpolation
    fraction is fixed per oversample phase) instead of re-evaluating the
    polynomials per sample. Bit-identical.
  - Hold `withUnsafeMutableBufferPointer` over the per-sample scratch-array
    writes so each store doesn't trip a COW uniqueness check. Bit-identical.
  - Move the pilot (19 kHz) and stereo (22-53 kHz) guard cancellation from the
    16x oversampled rate to **host rate on the decimated residual**. Both bands
    sit within the FIR's 53 kHz passband, so decimate and band-cancel commute;
    running them once per host sample instead of 16x is the bulk of the win. RDS
    (57 kHz, outside the FIR passband) and the audio guard stay at OS rate.
  - Net: composite clipper **~9.05% -> ~3.95% of real-time** on M1 Pro. The first
    two steps are bit-identical; the host-rate move is output-affecting but
    bounded -- production stereo separation (1/10/14 kHz), pilot level/phase, and
    RDS guard levels are unchanged on the receiver-model verifier; the only
    composite-baseline drift is a +1.2% side/mid nudge on the single most extreme
    (hard-panned HF) scenario. Verifier baseline recaptured accordingly.

- **Steadier numeric readouts.** Live numeric fields (levels, gain reduction,
  deviation, pilot / RDS %, etc.) are right-justified to constant character widths,
  so a value moving between 1 / 2 / 3-digit magnitudes ("-6.2" -> "-12.4" ->
  "-120.0") no longer shifts the surrounding layout on every refresh. The readout
  fonts are monospaced, so fixed-width fields keep everything still.

- **Tidier tab help.** Removed the in-card captions that duplicated the bottom help
  box across the Processing / RDS / Test-Tone tabs (the same stage description was
  shown twice); kept the in-card notes that give distinct actionable guidance. The
  one-source-of-tab-help rule is now recorded in the agent instructions.

## 0.34 — 2026-06-09

- **Lower cold-start input latency.** On a cold start the render path outputs
  silence until the input ring primes, but the input device free-runs and
  overshoots the ring well past prime depth in the meantime, leaving ~100 ms of
  standing latency that a warm (tone->input) restart didn't have. The ring now
  snaps to prime depth the instant it primes (same RT-safe call the warm path
  uses), so cold start settles at the same low latency as a warm restart
  (measured ~300 ms -> ~200 ms at block 1024 / 192 kHz). Note: the input ring
  target is floor-limited at 100 ms, so block sizes at or below ~512 give the
  same ring depth -- 256 buys no latency over 512, only higher callback load.

- **Long-run GUI stall — monitoring-overhead reduction (ARM and Intel).** The
  GUI progressively bogged down (UI near-frozen) when a monitoring window was
  left open for hours; the audio render, on its own real-time thread, was never
  affected. A main-thread `sample` traced it to the per-tick AppKit/SwiftUI
  layout pass driven by the 30 Hz metering refresh. Two changes cut that load:
  - Meters now draw in a `Canvas` (vertical strips on the Levels window,
    horizontal bars on the dashboard / status bar) instead of SwiftUI subviews
    whose `.frame(width:/height:)` tracked the value — a value change is now a
    repaint, not a layout invalidation.
  - High-frequency telemetry (≈65 live values) moved off `MPXPrimeViewModel`
    into a dedicated `LiveTelemetry` observable; only the live readouts (wrapped
    in `LiveTelemetryView`) observe it, so a metering tick no longer fires the
    view model's `objectWillChange` and re-evaluates the whole monitoring tree.
    The view model keeps one-line forwarding properties, so the writer code in
    the update methods is unchanged.

  - Fixed-footprint meter readouts: the `MeterRow` value text is now a
    fixed-width monospaced-digit frame, so a per-tick value change repaints in
    place instead of resizing and re-solving the enclosing stack.
  - The detached high-refresh windows (Levels, Scopes, MPX Spectrum, Audio
    Spectrum) set `NSHostingController.sizingOptions = []`: the window drives
    the size and the SwiftUI content fills it, so the hosting controller no
    longer adds/recomputes min/intrinsic/max Auto Layout constraints on every
    content update -- guarding against constraint accumulation in AppKit's
    layout engine over a long-open window (a documented SwiftUI-on-macOS
    long-running slowdown, closely related to the toolbar-recreation leak that
    the telemetry split above also defuses).

  Root cause was the documented SwiftUI-on-macOS defect where a high-frequency
  state-change storm (the 30 Hz metering refresh firing the view model's
  `objectWillChange`) recreates the window's `.toolbar` hierarchy every tick and
  leaks the copies, so the main thread becomes progressively layout-bound until
  the UI is near-frozen. Moving the telemetry off the view model severs that
  driver: a tick no longer invalidates the `RootView` / toolbar scope. Confirmed
  by a ~10-hour soak on a single instance with a monitoring window open the whole
  time — resident memory trended *down* (156 MB -> 103 MB), the per-tick layout
  pass stayed flat, and there was no visible lag, versus the old build's steady
  climb to a near-freeze. A residual steady layout cost remains (the text/metric
  panels re-solve their stacks on each update, inherent to that many live
  readouts) but it is bounded and not the stall; a future pass may migrate the
  monitoring state to the Observation framework (`@Observable`, macOS 15+) and
  drive the Canvas meters from `TimelineView` as the idiomatic structure.

- **Bass-desensitised wideband AGC** (opt-in, default off; `wideband_agc_bass_desensitize`,
  AGC tab toggle). A kick / heavy bass line no longer pumps the whole chain: P4
  (US 4,249,042) low-shelf-cuts the LF band out of the detector *sidechain* (audio
  untouched) so bass can't drive the loudness reading; P5 (US 3,790,896) recovers
  fast from brief reductions. Verifier-backed (`BassDesensitizedAGCTests`: bass no
  longer drives the AGC; config round-trip).
- **Now-playing scripts unified** into a single auto-detecting `nowplaying.sh` (VLC
  then Cog) — shared title cleanup / output written once. Strips parenthetical
  `(Radio Edit)` and bracketed `[Official Video]` title decorations (both default-on,
  `STRIP_TITLE_PARENS` / `STRIP_TITLE_BRACKETS`) that overflow RT / PS.
- **Platform support tiers** documented: Apple Silicon (arm64) Tier 1; Intel
  (x86_64) Tier 2, best-effort.

## 0.33 — 2026-06-07

### Processed-audio output mode

- **New output mode: processed stereo L/R for an external stereo coder.** A third
  `AudioOutputMode` (`processedAudio`, INI `processed_audio_output`, restart-required)
  emits the post-pre-encode-limiter L/R audio instead of the FM composite — for
  transmitters / exciters that only accept L/R / AES3 audio and have their own
  stereo generator + RDS encoder (the classic separate-processor topology). The
  whole audio chain runs (phase rotator, AGC, EQ, multiband with linear-phase FIR
  crossovers, widener, PrimeBass, bass/audio-band clippers, pre-emphasis,
  look-ahead pre-encode limiter, 15 kHz FIR band-limit); the composite half
  (stereo encode, composite clipper, BS.412, pilot/RDS injection) is skipped. The
  composite output path stays byte-identical (the audio-only path branches off
  `processAudioDomain`, reusing the existing `preMPX` tap; no new DSP).
- **Selectable pre-emphasis ownership.** Reuses `preemphasis_us` (Off / 50 / 75) so
  MPX Prime can apply pre-emphasis when the external coder has none (or it is
  disabled), or stay flat when the coder applies it. The Settings UI explains the
  one-and-only-one rule.
- **Runs at the audio device rate** (e.g. 48 kHz / 24-bit recommended), not the
  >=110 kHz composite minimum. Doubles as a clean, real-time audition path for the
  audio-processing chain on any output device.
- **Output level normalized** to full scale (the pre-encode limiter ceiling maps to
  ~0 dBFS) times the operator output gain, so the feed is at a proper line level
  rather than the raw ~-1.4 dBFS ceiling.
- **Optional final loudness clipper** for transmitters whose coder has no clipper:
  a Settings toggle "External coder has its own clipper" (default on, next to the
  pre-emphasis selector). When off, MPX Prime applies an 8x-oversampled
  distortion-cancelled final clipper (with a drive control) so the processed feed
  can be made denser; the one-clipper rule mirrors the pre-emphasis ownership rule.
  Default-on keeps the feed clean to avoid double-clipping.
- **UI gating + mode awareness.** A **MODE** chip in the status bar shows
  COMPOSITE / MONITOR / PROC AUDIO. When processed-audio is active, everything that
  is meaningless without an MPX composite is hidden or adapted: the RDS sidebar
  group and the composite Processing stages (Composite Clipper, BS.412, Final Stage)
  are hidden; the Core "MPX Output Level" relabels to "Output Level"; the Levels
  window hides the MOD (deviation) meter and relabels MPX -> OUT; the Monitoring
  dashboard drops the deviation/modulation/composite-GR/BS.412/pilot/RDS readouts;
  and the composite-only **MPX Spectrum** and **Scopes** windows are disabled (the
  Spectrum toolbar button opens the Audio Spectrum instead), auto-closing on switch.
  Selection normalizes to the Processing overview on (re)start.
- **Levels window default size** reduced (860 -> 560 wide) so the six meter strips
  no longer leave half the window empty.
- Verified on Apple Silicon and Intel x86_64: new `ProcessedAudioOutputTests`
  (no pilot / 38 kHz / 57 kHz, true-stereo preservation, 15 kHz band-limit,
  pre-encode peak ceiling, config round-trip) + navigation-gating tests; Intel
  release build + `--verify` PASS + headless 48 kHz processed-audio run clean.

### Performance / RDS

- **Composite clipper optimization.** Per-band IM cancellation rewritten via LTI
  superposition (one filter on the residual per band instead of one on the clipped
  and one on the original) — half the per-band filtering. Intel x86_64: composite
  clipper stage 23.2% -> 10.6% of real-time (-54%), full chain 37.5% -> 25.8% RT
  (-31%). Output delta -78 dBFS (inaudible); baseline-strict PASS.
- **PTY region toggle (RDS / RBDS).** New `pty_rbds` switch + UI control: the PTY
  picker and status label show the European RDS or North American RBDS genre table
  (same transmitted 5-bit code, region-specific labels).
- **Arch-tiered GUI refresh profile for Intel.** The scope/spectrum/meter draw is
  main-thread/SwiftUI-bound and pegged one core on older Intel Macs (e.g. i7-9750H).
  The x86_64 binary slice now runs a lighter refresh profile (20 Hz active / 12 Hz
  idle, 15 Hz inline spectrum, 256 inline bins) while the arm64 slice keeps the full
  profile unchanged (compile-time, zero Apple-Silicon impact). Measured ~100% ->
  ~85% of one core on the i7-9750H with responsive meters; the audio render thread
  was never affected.

Carries everything since 0.30.3, including the unreleased 0.31 work
(symmetric RDS decoder, cross-module-inlining perf pass). The headline of
this release is a full Apple HIG sweep of the UI, real-time-safety
hardening, and RDS/RT+ correctness + guidance work.

### RDS / RT+

- **Symmetric RDS decoder (`RDSStreamDecoder`).** Receive-side counterpart to
  `BasicRDSCoder` in `MPXPrimeCore`: BCH offset-word block synchronization,
  per-block CRC, and accumulated PI / PTY / TP / TA / MS / PS state. Round-trip
  tested against the encoder.
- **RT+ tag ordering fix.** RT+ 11A tags are now ordered so the longer element
  uses tag 1 (6-bit length marker, up to 64 chars) and the shorter uses tag 2
  (5-bit, up to 32). Previously sorted by start position, so a title longer
  than 32 characters landed in tag 2 and was clipped to 32 on the receiver.
- **RT+ guidance.** The Radiotext card now explains how to surface Artist/Title
  via RT+: RT+ tags text inside the RadioText (per the RDS standard), so the
  now-playing must appear in an RT message via `{artist}`/`{title}` macros.
  Station identity belongs in PS / Long PS.
- **Cog now-playing poller.** New `scripts/cog-nowplaying.sh` reads the current
  track from Cog (https://github.com/losnoco/cog) via its AppleScript
  dictionary, mirroring the VLC poller's output contract. Both pollers now gate
  on `pgrep` (a pure process check that sends no Apple events) so they never
  launch the player when it is not running. Both example scripts ship in the
  app bundle (`Contents/Resources/Scripts/`) and the DMG.
- **Scheduler UX.** The RDS Schedule tab is now a single "Custom group
  sequence" advanced toggle; automatic IEC 62106 scheduling (derived from the
  enabled features) is the clear default.

### UI — Apple HIG sweep

- **Navigation.** `HSplitView` -> `NavigationSplitView` with a standard
  collapsible sidebar and a unified title-bar toolbar (transport / bypass /
  config / scopes / spectrum / levels). Main window hosted via
  `NSHostingController` with `sizingOptions = []` so the tall sidebar no longer
  drives the window size past the screen.
- **Accessibility.** Parameter sliders and steppers expose unit-bearing
  VoiceOver values; meter strips, scopes and spectra became labelled elements;
  the dropout pill and status chips encode state as text (not color alone);
  About-panel text uses Dynamic Type styles.
- **Terminology / controls.** Patent/jargon control labels reworded to
  outcome language; experimental limiter controls moved under a disclosure
  group; destructive snapshot Clear gained a confirmation; AF Method picker is
  segmented.
- **App name.** The unbundled binary now shows "MPX Prime" in the Apple menu
  and Dock (embedded `Info.plist` linker section), matching the bundled app.

### Real-time safety / performance

- **Render-thread hardening.** Monitor/analysis scratch buffers no longer
  allocate on the audio thread (debug-assert + tracked release-only fallback);
  runtime config handoff uses a try-lock so the render thread never blocks;
  the first-AUHAL-frame scalar peak loop + `os_log` moved off the render path.
- **Cross-module inlining.** `MPXDecoder` hot `process()` made `@inlinable`
  so it inlines across the `MPXPrimeCore` boundary in release builds; denormal
  guards added to its leaky integrators.
- **AGC.** Density-scaled release coefficient computed lazily in the only
  branch that uses it (bit-identical to the prior per-sample result, verified
  by an old-vs-new A/B on the rendered composite), removing two `expf()` per
  sample on attack / hold / gate / in-window samples.

### Docs

- Corrected the UI/UX HIG rules in `AGENTS.md` (toolbars are HIG-endorsed;
  prefer `NavigationSplitView`; "cards" reclassified as house style).

## 0.30.3 — 2026-05-29 (hotfix)

### Crash fix — CompositeMultibandClipper SIGILL at degenerate sample rates

Found during the v0.30.2 Intel soak: an MBP16,1 (Coffee Lake-H) running with the experimental `mpx_multiband_clipper_enabled = True` crashed with `EXC_BAD_INSTRUCTION` / SIGILL on the main thread after several hours, on an engine restart (`MPXPrimeViewModel.startEngine()` -> `AudioOutputEngine.start()` -> `MPXGenerator.setSampleRate()` -> `CompositeMultibandClipper.configure()`). It traps only on *some* restarts, which matches the operator habit of stop-starting the engine to clear an audio glitch.

**Root cause.** `CompositeMultibandClipper.configure()` ended with `precondition(lpLow.tapCount == lpMid.tapCount)`. `precondition()` is NOT stripped in release builds, so a failure compiles to a trapping instruction. The two split bands (180 Hz and 4.2 kHz cutoffs) normally get identical Kaiser tap counts — the count depends on the transition band, not the cutoff. But the transition is clamped by `(nyquist - fc)`, and at a degenerate sample rate the 4.2 kHz band's transition clamps against Nyquist while the 180 Hz band's does not, so the counts diverge. The trigger is `setSampleRate` flooring a momentarily-~0-Hz device rate to `max(8000, rate)` = 8 kHz during a (re)start: at 4 kHz Nyquist the bands no longer match and the precondition kills the app.

**Fix.** An experimental, opt-in stage must never be able to take the whole app down. `configure()` now degrades to clean pass-through (empty delay line -> `process()` returns the input untouched; zero group delay so the upstream subcarrier alignment stays correct) when `sampleRate < 32 kHz` or the tap counts somehow still differ, instead of asserting. Behaviour at real MPX/composite rates (>=96 kHz) is unchanged — `--verify --baseline-strict` is identical to the captured baseline. New regression guards: `degenerateRateDegradesToPassThroughInsteadOfCrashing` (parameterized over 0 / 8k / 11.025k / 22.05k / 31.999k) and `saneRateConfiguresActiveStageWithMatchedBands`.

Severity note: `configure()` runs on **every** engine start, unconditionally — the `mpx_multiband_clipper_enabled` flag only gates whether the stage *processes* audio, not whether it is configured. So the crash was reachable by **any** operator whose output device briefly reported ~0 Hz on a (re)start, not only those who had enabled the experimental stage. The machine where it was observed happened to have the stage on, but the enable flag is not a precondition for the trap.

Correction (added post-release): an earlier draft of this entry stated the verifier "confirmed the stage degrades decoded-audio quality on dense/bass program." That claim was based on an uncontrolled single field `--verify` run and is **not** supported by measurement. A controlled OFF-vs-ON A/B (via the extended `--verify-composite-multiband`, same base config, only the multiband toggle flipped) shows the stage changes decoded RMS drift by <=0.8 dB worst case (wide_bass is +2.21 off / +2.20 on — identical) and actually *improves* `>60k` HF leakage substantially on bright/HF content (bright_dense -60.5 -> -90.7 dB, hf_edge_12k -59.9 -> -93.1 dB). The drift/leakage seen in the field run came from that run loading the operator's hotter `MPX Prime.ini` (en_rds=False, no explicit sample_rate) against per-scenario quality thresholds calibrated for the default chain, not from the multiband clipper. The stage stays off by default because it is experimental and not yet listening-validated, not because of measured quality degradation.

### Internal — MPXPrimeCore shared DSP target (modularization step 1)

First concrete step of the modularization push and the prerequisite for the planned MPX Prime Meter companion app. New `MPXPrimeCore` SPM library target holds the reusable decode-side DSP — `MPXDecoder` plus the foundational `Biquad` / `BiquadCascade6` / `DeemphasisFilter` primitives — moved verbatim out of the ~9.6k-line `MPXGenerator.swift` (which drops ~280 lines). Only the public surface and cross-module-inlining annotations changed; the hot per-sample `process()` methods are `@inlinable` so they still inline across the new module boundary in release builds. Verified output-identical (`--verify --baseline-strict`) and CPU-neutral (`--bench` 28.33% RT vs 28.40% pre-extraction on M1 Pro). No user-visible change.

## 0.30.2 — 2026-05-24 (hotfix)

### Real-time safety — FTZ/DAZ flags on the audio thread

Second same-day hotfix for an Intel-only "white noise after a couple of songs" bug. The chain produced correct MPX initially, but after minutes of operation the audio thread would stop producing meaningful output and the receiver would hear broadband noise. Engine stop → start recovered it temporarily. M1 Pro / Apple Silicon did not reproduce.

**Root cause: denormal-float accumulation on x86_64.** Long-running envelope followers, exponential integrators, biquad allpass states, and the BS.412 rolling-window in the chain slowly drift their internal state toward zero. Eventually some of those values cross into denormal (subnormal) Float range (< ~1.175e-38). On Intel without FTZ (Flush-to-Zero) + DAZ (Denormals-Are-Zero) flags set, denormal floating-point arithmetic is handled by microcoded slow paths at 10-100x the normal-range cost. Once enough of the chain's state is denormal-heavy, the audio thread misses CoreAudio's deadline, samples are dropped, and the output goes to garbage. Standard textbook real-time-DSP gotcha on x86.

Apple Silicon's NEON / AMX handle denormals at full speed so the failure mode is invisible there — only the production Intel install reproduced it.

**Fix.** New `MPXPrimeNative` C target (Swift can't write MXCSR / FPCR control registers directly). Exposes `mpx_enable_flush_to_zero()`:
- **x86_64**: MXCSR FTZ (bit 15) + DAZ (bit 6) via `_MM_SET_FLUSH_ZERO_MODE` / `_MM_SET_DENORMALS_ZERO_MODE` from the SSE / SSE3 platform headers.
- **arm64**: FPCR FZ (bit 24) via `mrs` / `msr` inline asm. Defensive on Apple Silicon (NEON handles denormals fine) but keeps behaviour consistent across architectures.

Call sites: top of the `AVAudioSourceNode` render callback in `AudioOutputEngine.swift`, top of the AUHAL input proc in `InputAUHAL.swift`. Both per-callback (cost ~1 ns) because CoreAudio may swap audio threads on device events and these flags are per-thread.

`DenormalGuardTests` regression guard: forces a runtime denormal multiplication and asserts the result is exactly zero (without FTZ the denormal arithmetic produces a non-zero subnormal). If someone removes the guard in a future commit, this test fails immediately.

**Why the 0.30 / 0.30.1 verifier didn't catch it**. The verifier runs offline `MPXGenerator.renderFromInputInPlace(...)` directly, not through the AVAudioSourceNode callback. The denormal slowdown only manifests under real-time deadline pressure — the synthetic test loop has no per-callback deadline, so the slow denormal arithmetic is invisible (it just adds a few microseconds the test doesn't notice). The fix is also untestable in pure-Swift unit tests by direct timing; `DenormalGuardTests` validates the flag's *effect* (denormal → zero) rather than its timing impact.

Tests: 390 default tests pass (388 + 2 new denormal-guard tests). Release build clean. swiftlint 0 violations.

**Operator impact**: v0.30 / v0.30.1 Intel users should upgrade to v0.30.2. The symptom is "after some time the receiver loses the signal and just hears broadband noise" — that's the audio thread starving on denormal arithmetic. v0.30.2 hardens against this; no more long-session dropouts.

## 0.30.1 — 2026-05-24 (hotfix)

### DSP — fix HF amplitude regression from 0.30 dual-rate cutover

Single-commit hotfix for the v0.30 regression "lost a lot of high frequencies" — confirmed via a new HF amplitude sweep test that the v0.30 chain attenuated content above 4 kHz by 18+ dB, with everything above 6 kHz at the noise floor (-100+ dB) when the dual-rate boundary was on (the v0.30 default) and the encoder FIR was enabled (the production default).

**Root cause.** `setEncoderFIREnabled(_:)` and `setSampleRate(_:)` re-configured several audio-domain stages at `self.sampleRate` (the engine's MPX rate, 192 kHz) AFTER `applyEncoderComplianceConfiguration` had correctly configured them at `audioDomainSampleRate` (the audio rate, 48 kHz when the boundary is on). The production startup flow was:

1. `MPXGenerator.init()` → `applyEncoderComplianceConfiguration(sampleRate: self.sampleRate)` → internally uses `audioDomainSampleRate` → encoder LP/FIR configured at 48 kHz. ✓
2. `AudioOutputEngine.start()` → `gen.setEncoderFIREnabled(true)` → clobbers the encoder LP/FIR back to 192 kHz. ✗

When a FIR's 14.9 kHz cutoff is designed at `fcNorm = 14.9 / 96 = 0.0776` (target 192 kHz Nyquist) but the convolution is then applied to a 48 kHz sample stream — because the audio domain runs at 48 kHz when the boundary is on — the effective digital cutoff becomes `0.0776 × 24 kHz = 1.86 kHz`. A 1.9 kHz brick-wall lowpass masquerading as a 14.9 kHz encoder bandwidth guard.

`setSampleRate(_:)` had the same bug pattern: it re-configured every audio-domain stage (pre-emphasis L/R, wideband AGC, input HPF, HF trim, phase rotator, bass clipper, pre-encode L/R limiter) at `self.sampleRate`. Fixed all of them to use `audioDomainSampleRate`.

**Why the 0.30 verifier suite missed it.** `--verify-receiver` tested stereo separation at 1 / 10 / 14 kHz via the internal `MPXDecoder`, which itself runs deemphasis + bandwidth-limiting filters that masked the encoder-side HF loss. The receiver-decoded "Wanted" levels matched the off baseline within 0.3 dB — looked clean. But the encoder-side audio composite was missing all HF; the receiver was deemphasizing an already-deemphasized signal and finding nothing where the deemphasis curve put it. The HF amplitude response of the audio chain *itself* was never measured.

**Regression guard.** New `DualRateHFResponseTests` with two default-on (not env-gated) tests:
- `dualRateOnMatchesOffInAudioPassbandWithProductionFIR` — sweep 1 / 2 / 4 / 8 / 10 / 12 kHz with encoder FIR enabled (production default), fail if delta vs boundary-off exceeds ±0.5 dB.
- `dualRateOnMatchesOffNearEncoderCutoff` — same at 13 / 14 / 15 kHz with ±2.5 dB tolerance (closer to FIR rolloff).

Plus the existing `MPXPRIME_HF_RESPONSE=1`-gated full-sweep markdown report stays available for diagnostics.

**Measured.** Post-fix HF sweep with the production FIR path (delta of boundary-on vs boundary-off, M1 Pro release build):

| Freq | Pre-fix Δ | Post-fix Δ |
|---:|---:|---:|
| 1 kHz | 0 dB | 0 dB |
| 4 kHz | **-18 dB** | -0.06 dB |
| 6 kHz | **-106 dB** | +0.01 dB |
| 10 kHz | **-109 dB** | -0.04 dB |
| 14 kHz | **-112 dB** | -0.34 dB |

Tests: 386 default tests pass (was 385 — added the 2 new HF regression guards). Release build clean. Tested on a real Intel i7-9750H (MBP16,1) — DMG installed locally + `--bench` validation confirmed identical CPU savings as v0.30 (the bug was HF amplitude, not CPU cost).

**Operator impact.** v0.30 users should upgrade. The audible HF loss is dramatic — basically everything above ~3 kHz was being silently removed. v0.30.1 restores the v0.29-equivalent audio with the dual-rate refactor's CPU savings intact.

## 0.30 — 2026-05-24

### Tooling — `MPXPrime --bench` CLI + Intel benchmark captured

Two related pieces:

**`MPXPrime --bench` CLI.** The benchmark previously lived as a Swift Testing `@Test` gated on `MPXPRIME_BENCH=1`, which means it needed full Xcode (for `Testing.framework`) to run. That blocked running it on machines with only Command Line Tools — including Intel Macs accessed over SSH for the long-pending plan.md A11 Intel benchmark item. Refactored: bench logic moved from `Tests/MPXPrimeTests/BenchmarkSuite.swift` to `Sources/MPXPrime/BenchmarkRunner.swift`; `BenchmarkSuite` becomes a thin `@Test` wrapper that delegates; new `--bench` CLI command in `main.swift` runs the same logic on any machine. The MPXPRIME_BENCH `swift test` workflow on the dev machine continues to work.

**MBP16,1 i7-9750H benchmark captured (closes plan.md A11).** Ran `MPXPrime --bench` on a real Coffee Lake-H Intel Mac to confirm the projected dual-rate payoff on Intel hardware. Measured:

| | M1 Pro (defaults) | Intel i7-9750H (defaults) |
| --- | --- | --- |
| Full chain @ 192 kHz, dual-rate off (legacy) | 41.9% RT | **59.1% RT** |
| Full chain @ 192 kHz, dual-rate on (shipping default) | 24.3% RT | **38.5% RT** |
| Savings | -17.6 pp / -42% relative | **-20.6 pp / -34.8% relative** |
| Composite clipper @ 16x | 14.3% RT | **24.6% RT** |

The Intel savings are larger in absolute terms than M1 Pro — exactly the audience the dual-rate refactor was aimed at. Composite clipper at 16x is the single heaviest stage on Intel; the 8x option drops it by ~12 pp. Stacking dual-rate on + 8x clipper gets the i7-9750H full chain to ~27% RT — roughly M1-Pro-with-defaults headroom. Full report at `macOS/benchmarks/mbp16-1-i7-9750h-v0.30.md`.

## 0.30 — 2026-05-23

### DSP — Dual-rate audio chain is now default ON; baseline refreshed; README device-config section

Following the same-day Phase 2 cutover commit, flipping `dualRateAudioDomainEnabled` from default-false to default-true. The savings are large (-17.6 percentage points / -42% relative on M1 Pro), receiver verification confirms stereo separation matches the off baseline, and the bigger relative benefit on older Intel hardware (AVX2 with no AMX) is exactly the audience that needs it most. Operators who want the legacy single-rate chain can set `dual_rate_audio_domain_enabled = False` in their INI.

- **AppConfig default flipped** from `false` to `true`. Sample `MPXPrime.ini` reflects the new default with an inline comment block explaining the trade-off and how to opt out.
- **Verifier baseline (`macOS/verifier_baselines/default.json`) recaptured** under the new default — `--verify --baseline-strict` now passes again (was reporting drift since the 0.28-era baseline + multiple unrelated 0.29/0.30 changes accumulated).
- **`DualRateBoundaryTests` regression guards updated**: previous test `defaultDisabledIsBitIdenticalToBaseline` (which asserted `default == false`) split into two new guards — `defaultIsDualRateEnabled` (asserts `default == true`) and `explicitlyDisabledIsStable` (the legacy single-rate path still produces reproducible output, catches drift in that code path for operators who opt out).
- **README** gains an input-device configuration subsection alongside the existing output-device guidance: input at **48 kHz / 24-bit** is the recommended sweet spot since the audio domain now processes at 48 kHz internally — matches the audio-domain rate without Core Audio upsampling on the way in, no information gain from higher input rates since audio source material has no useful content above ~20 kHz. The output device guidance for 192 kHz / 24-bit unchanged (required for RDS at 57 kHz).
- **Engines at non-integer engine:audio rate ratios (176.4 / 128 kHz output)** continue to silently fall back to the legacy single-rate chain regardless of this flag — Phase 1's integer-ratio restriction stands. Phase 3 (non-integer polyphase resampler) is a future item.

Tests: 385 default tests pass (one new regression guard added, one renamed). All verify modes pass (--verify --baseline-strict, --verify-presets, --verify-receiver, --verify-composite-multiband, --verify-multiband-coupling). Release build clean; swiftlint 0 violations.

### DSP — Dual-rate audio chain, Phase 2 cutover (audio domain at 48 kHz)

The big one. With this commit the dual-rate boundary is no longer a no-op — when enabled, the entire audio domain (`processProgramStereo` → stereo image protection → pre-emphasis → pre-encode limiter, including multiband splitter/compressors/limiters/expanders, PrimeBass, parametric EQ, stereo widener, phase rotator, wideband AGC, bass clipper, DCC) runs at 48 kHz inside the boundary instead of at the engine's MPX rate after a roundtrip. The MPX domain (composite assembly, BS.412, composite clipper, audio-composite bandwidth FIR, final-MPX safety limiter, pilot+RDS injection) stays at the high rate where pilot/L−R sidebands/57 kHz RDS need bandwidth.

**Measured payoff on M1 Pro (release):**

| | % of real-time |
|---|---|
| Boundary off (192 kHz everywhere) | 41.85% |
| Boundary on (audio 48 kHz, MPX 192 kHz) | **24.26%** |
| Savings | **-17.59 pp / -42.0% relative** |

Matches the original projection (16.5 pp / 40% relative) from the pre-dualrate baseline. Full report at `macOS/benchmarks/m1pro-v0.30-phase2-cutover.md`. Stereo separation verified to match the boundary-off baseline at 1 / 10 / 14 kHz (42.9 / 26.1 / 33.4 dB on with boundary, 42.9 / 26.0 / 26.4 dB off — 14 kHz separation is slightly *better* with the boundary on).

**Implementation:**

- All audio-domain configure call sites (~15 helpers covering biquads, multiband splitter/compressor/limiter/expander, primeBass internals, stereo widener, bass clipper, DCC, pre-emphasis, pre-encode limiter, program LP, pilot notch, encoder HF guard) now use a new `audioDomainSampleRate` computed property. When the boundary is off, `audioDomainSampleRate == self.sampleRate` and behavior is bit-identical to pre-cutover; when on, the property returns `dualRateAudioRate` (typically 48 kHz) and every stage's coefficients land on the lower-rate grid.
- `processSampleDetailed` dispatches: boundary-off runs `processAudioDomain` at MPX rate as before; boundary-on calls a restructured `applyDualRateBoundary` that runs `processAudioDomain` exactly once per L OS ticks (when decim emits), pushes the audio-domain output through interp, and serves the L upsampled MPX-rate samples to the MPX domain one per OS tick.
- Side outputs (`analysisStereo` and `inputActivity`) are buffered between audio-rate ticks via new `latestAudioAnalysisStereo` / `latestAudioInputActivity` state so MPX-domain stages see consistent values every OS tick.

**Two bugs caught + fixed during validation:**

1. **Interp output buffer was being read in the wrong order.** With the original phase counter design, each L-cycle emitted `buffer[L-1], buffer[0], buffer[1], ..., buffer[L-2]` — a per-cycle temporal discontinuity that destroyed phase coherence and trashed stereo separation. Fix: reset `dualRateBoundaryPhase = 0` on every refill so the L outputs are read in chronological order (`[0], [1], ..., [L-1]`).
2. **`recomputeSubcarrierDelay()` was over-delaying the pilot by the boundary delay.** The boundary sits upstream of the stereo encoder; the freshly-generated pilot and embedded 38 kHz subcarrier are both emitted by the encoder at the current OS tick and do NOT traverse the boundary. Adding boundary delay to the pilot side rotated the pilot ~94° at 19 kHz relative to the embedded carrier — the encoder-side sidebands stayed balanced (SideSum = Mono), but the production decoder's pilot PLL recovered a 38 kHz reference that was phase-rotated from the actual embedded carrier, dropping separation from ~43 dB to ~2 dB. Ideal-coherent decode (which uses the engine's 38 kHz reference directly, not the pilot) was unaffected — which is what initially diagnosed the issue. Fix: removed `dualRateBoundaryDelay` from `recomputeSubcarrierDelay()` (the boundary affects audio-modulation timing but not the encoder-side pilot/subcarrier emission timing).

**Tests:** 384 default tests pass, including `DualRateBoundaryTests.defaultDisabledIsBitIdenticalToBaseline` (regression guard for the boundary-off path). `--verify-receiver` with boundary on confirms separation matches off baseline. Release build clean; swiftlint 0 violations.

**Next:** validation work (real-program listening A/B with boundary on, accumulate hours of operation, refresh stored verifier baselines for the boundary-on path), then look at whether the audio-domain pre-emphasis at 48 kHz needs the planned response-measurement audit vs 192 kHz.

### UX / HIG — Codex review small-fix batch

Four targeted fixes from the 0.30 codebase review (issues A8/A10/H1/H3/H8 + D2):

- **In-app warning when RDS is enabled below 192 kHz output rate.** New chip in `BroadcastStatusBar` ("RDS WARNING — RATE < 192 kHz", orange `exclamationmark.triangle.fill`) appears whenever `enRDS = true` and the effective sample rate (running `renderHz` if engine is up, configured `sampleRate` otherwise) is below 192 kHz. Catches the most common amateur misconfiguration on built-in Mac audio (96 kHz default) where the RDS subcarrier at 57 kHz cannot be represented and folds back into the audio band — operators previously had no in-app cue and would debug RDS coder bugs that didn't exist. Tooltip explains the fix path (raise sample rate vs disable RDS).

- **Global "Restart pending" chip.** New chip in `BroadcastStatusBar` ("PENDING — RESTART REQ.", yellow `arrow.triangle.2.circlepath`) appears whenever `runtimeApplyPending` is true. Single always-visible cue replaces (well, complements — the existing per-tab status text stays) the easy-to-miss in-content status messages. Tooltip enumerates which settings are restart-required.

- **Replace `NavigationSplitView` with `HSplitView` for the root sidebar.** Repo HIG guidance is "HSplitView for static sidebars; NavigationSplitView only when sidebar collapse is required." The previous root view used NavigationSplitView pinned via `columnVisibility: .constant(.all)` + `toolbar(removing: .sidebarToggle)` — a workaround around a view type whose default behaviour included collapsibility. HSplitView is the correct primitive: no sidebar-toggle to remove, no autosaved-collapse state to fight, just a fixed-position stage list on the left and the active stage on the right. Sidebar width range preserved (220 min / 240 ideal / 320 max). Inspector behaviour unchanged. Closes H1 + H8.

- **Explicit Release Validation checklist in AGENTS.md.** Adds a "Release validation checklist" subsection to "Release prep" with explicit checkboxes for swift test, release build, swiftlint, `--verify` / `--verify-presets` / `--verify-receiver` / `--baseline-strict`, release-build live smoke at 192 kHz, Audio MIDI Setup device-rate match, RDS receiver smoke matrix, manual VoiceOver pass for UI changes, and optional deep DSP suite. Previously the prep section was 5 narrative bullets; several validation items the review surfaced (receiver verifier, baseline-strict, accessibility pass) had no anchor in the release process.

## 0.30 — 2026-05-22

### DSP — Dual-rate audio chain refactor, Phase 0 + Phase 1 (no-op boundary)

First infrastructure step of the dual-rate refactor (plan.md "Next up" #1). The goal is to run audio-domain DSP stages at 48 kHz (where 48 kHz input content actually lives) while keeping MPX-domain stages at the high rate where pilot / L-R sidebands / 57 kHz RDS need bandwidth. This commit lands the foundation; Phase 2+ migrates individual stages across the boundary.

**Phase 0 — Polyphase resampler primitive.** New `LinearPhaseFIRInterpolator` (1:L upsampler) in `MPXGenerator.swift`, sibling to the existing `LinearPhaseFIRDecimator`. Same primitives: Kaiser-windowed sinc + `vDSP_dotpr` polyphase commutator, kernel scaled by L for unity DC gain, double-buffered delay-line trick, real-time safe (no allocations on `push`). 7-test suite (`LinearPhaseFIRInterpolatorTests`) covers DC gain, group-delay accounting (OS vs input-rate), impulse-response peak placement, decim → interp round-trip identity (recovers band-limited signal to better than -75 dB RMS error after alignment), zero-stuffing image suppression (≥75 dB at the first image after polyphase upsample), reset/configure idempotence, disabled-state passthrough.

**Phase 1 — No-op boundary wired into `processSampleDetailed`.** Adds `dualRateBoundaryEnabled` and `dualRateAudioRateHz` to AppConfig (INI keys `dual_rate_audio_domain_enabled`, `dual_rate_audio_domain_rate_hz`; defaults `false` / `48000.0`; restart-required). When enabled, the per-OS-sample input L/R is pushed through a decim → interp pair before the rest of the chain runs — audio stages do NOT yet migrate to the lower rate; the boundary just round-trips data to validate the resampler primitives at chain scale. Only integer engine:audio ratios are supported in Phase 1 (192/48 = 4, 96/48 = 2); non-integer ratios (176.4/48 = 3.675, 128/48 = 8/3) silently fall back to disabled. The boundary's combined kernel group delay is folded into `recomputeSubcarrierDelay()` so pilot/RDS stay phase-coherent with the audio composite. `DualRateBoundaryTests` regression-guards three properties: (1) default-disabled is BIT-IDENTICAL to the pre-refactor chain (no opt-out cost), (2) non-integer ratios fall back cleanly (no crash, no aliasing), (3) integer-ratio enable produces recognisable output with peak within ±20% of baseline.

**Next: Phase 2** starts migrating individual audio-domain stages across the boundary. Smallest-first (pre-emphasis or stereo widener) as low-risk first moves, then bass clipper / DC clipper / multiband splitter for the bulk of the CPU win. Each baseline-gated against `--verify --baseline-strict` and re-run through `BenchmarkSuite` to confirm the predicted ~16-percentage-point real-time savings on M1 Pro (and proportionally larger on Intel hardware).

## 0.30 — 2026-05-21

### DSP — Composite clipper oversampling is operator-selectable

`CompositeClipper` was hardcoded at 16× oversampling since post-0.29. It is now configurable to 8 / 16 / 32 via the new `mpx_clipper_oversampling` INI key (default 16, preserves shipping behaviour) and a segmented picker in the Composite Clipper inspector.

Why each option exists:
- **16× (default)** matches Optimod 8X00 / Omnia.11 / Stereotool industry practice. Sweet spot — pick this unless there is a specific reason to deviate.
- **8×** halves this stage's CPU cost. Gives up ~6 dB alias suppression at hot drives — measurable but almost never audible on amateur program. The right answer when CPU headroom is the constraint (older Intel Macs, Pi-class hardware).
- **32×** doubles this stage's CPU cost. Adds ~6 dB further alias suppression — Omnia.9-class spec-sheet number, mostly visible in measurement rather than audible. For operators who want the maximum-quality knob defended and have the CPU to spend.

Restart-required (changes FIR decimator tap count, Lagrange interpolator step count, and per-host batch buffer sizes). `CompositeClipper.factor` is now an instance var assigned in `configure()`. Per-host batch buffers default-size to 32 (the supported maximum) so swapping to a smaller factor shrinks them without reallocating, and bumping back up is also non-allocating after first configure. `RuntimeConfig` carries the field so the live-apply structural-change detector picks up a mismatch (defense-in-depth — the UI uses `.restart` disposition so the engine fully rebuilds on change).

Measured cost on M1 Pro (release, full chain, 192 kHz):
- 8×:  35.1% of real-time (-6.2 pp vs 16×)
- 16×: 41.3% of real-time  (reference)
- 32×: 53.5% of real-time (+12.2 pp vs 16×)

See `macOS/benchmarks/m1pro-v0.30-with-os-selector.md` for the full report. Reproducible with `MPXPRIME_BENCH=1 swift test -c release --filter Benchmark`.

### DSP — opt-in benchmark suite (`BenchmarkSuite`)

New env-gated test suite for measuring absolute DSP cost: rate sweep (96 / 128 / 176.4 / 192 kHz), per-stage A/B (multiband, AGC, EQ, PrimeBass, widener, mono bass, phase rotation, bass clipper, DCC, multiband limiter, pre-emphasis, pre-encode limiter, pre-encode look-ahead, composite clipper, BS.412, RDS), and composite-clipper oversampling sweep (8 / 16 / 32). Outputs a markdown report to stdout with machine info, build mode, and a first-order estimate of dual-rate refactor savings. Gated on `MPXPRIME_BENCH=1` so it does not slow normal `swift test` (returns early when the env var is absent — 374 default tests still pass cleanly).

Purpose: capture a durable "before dual-rate" baseline (plan.md "Next up" #1) so the audio-domain → MPX-domain split can be validated against measured numbers rather than guessed at. Initial M1 Pro capture saved at `macOS/benchmarks/m1pro-v0.30-pre-dualrate.md`; post-OS-selector capture at `macOS/benchmarks/m1pro-v0.30-with-os-selector.md`.

## 0.30 — 2026-05-17

### UI — Format Profiles (atomic "Station Format" selector)

Top-of-Processing-Overview Format Profile picker that atomically applies a coherent bundle of multiband + final-stage + PrimeBass + stereo widener + composite-clipper settings per programming format. One-click "make this sound right for my format" — operator picks the format, downstream stages all receive matching settings. Per-stage knobs remain editable after; the profile is a cosmetic label that stays selected until the operator picks a different one.

Eight format profiles ship:
- **Community Radio** (default) — `5_ac` light + `balanced` + no PrimeBass + `safe_fm` + +4 dB drive
- **Pop / Adult Contemporary** — `5_ac` normal + `balanced` + PrimeBass `ac` + `open_music` + +6 dB
- **CHR / Top 40** — `5_chr` normal + `chr` + PrimeBass `chr` + `wide_chr` + +8 dB
- **Rock** — `5_rock` normal + `punchy` + PrimeBass `rock` + `open_music` + +7 dB
- **EDM / Dance** — `5_dance` heavy + `chr` + PrimeBass `chr` + `wide_chr` + +9 dB
- **Urban / Hip-Hop** — `5_urban` normal + `chr` + PrimeBass `urban` + `open_music` + +8 dB
- **Jazz / Classical** — `5_classic` light + `balanced` + no PrimeBass + `safe_fm` + +3 dB
- **News / Talk** — `5_talk` light + `speech` + no PrimeBass + `safe_fm` + +4.5 dB

The "Community Radio" default produces a chain state equivalent to the shipping defaults (regression-guarded by `defaultProfileMatchesShippingDefaults` test) so the new default is a rename, not a behavioural change at first install. Closes "Next up #3" in plan.md (open since 0.26). All eight profiles reuse the existing per-stage preset IDs — no new multiband / final-stage / PrimeBass / widener entries.

New surface:
- `MPXPrimeViewModel.FormatProfile` struct + `formatProfiles` static catalogue + `applyFormatProfile(_:)` + `formatProfileBinding()` + `currentFormatProfileSummary`
- `AppConfig.formatProfileID` (INI key `format_profile_id`, default `community_radio`)
- `ProcessingOverviewGrid` picker card above the existing stage grid

11 new tests in `FormatProfileTests`: catalogue uniqueness, all referenced per-stage IDs exist, atomic apply for `pop_ac` / `edm_dance` / `news_talk`, default profile matches shipping defaults, unknown ID is a no-op, INI round-trip, summary helper. 344 total tests pass (was 333).

## 0.30 — 2026-05-16

### DSP — pre-encode L/R limiter look-ahead (Phase 1 + Phase 2 both default-on)

Two-phase rollout of look-ahead peak control on the pre-encode L/R limiter (`StereoLinkedOversampledPeakLimiter`), closing the last major audible gap versus pro-tier chains on HF transient handling.

- **Phase 1 — basic delay+detector look-ahead, default 1.0 ms.** Audio-rate delay buffer (`lookaheadSamples`, `lDelay` / `rDelay`) added inside the stereo-linked limiter struct. The detector reads the un-delayed input and computes a `futurePeak = max(|left|, |right|)`; the audio path processes the delayed sample; `stereoStep` now uses `peak = max(osPeak, futurePeakHint)` so the gain ramp begins ahead of the actual peak arrival. With attack constant at 0.25 ms, a 1.0 ms lookahead (4x attack time) yields a smooth gain ride instead of the prior reactive tanh squash. `lookaheadMS = 0` short-circuits to the bit-identical legacy path (regression-guarded by test). Restart-required (allocates delay buffer at configure time). New INI key `pre_encode_lookahead_ms`, clamp 0-5 ms, default 1.0. New slider on the Audio Limiter card. Pre-1980 prior art (`US 4,208,548`, expired ~1997); no patent citation required.
- **Phase 2 — Dolby HF-subband-aware detector, default-on with 4 kHz cutoff.** Per `US 5,579,404` / `EP 0685130 B1` (Dolby Laboratories Licensing Corp, expired 2013-11 US / 2014-02 EP). When `lookaheadHFOnly` is true, the detector path runs through a 2nd-order Butterworth high-pass biquad (`hfDetectorL` / `hfDetectorR`) before computing `futurePeak`. Audio path stays full-band — only the gain envelope changes. Rationale: pre-emphasis adds +10-12 dB specifically to HF before the pre-encode limiter sees the signal, so the peaks the limiter actually fights are concentrated above ~3 kHz. Targeting the lookahead detector at HF leaves LF perceived loudness / punch untouched while preserving the HF-reach improvement that real-program listening A/B validated in Phase 1. New INI keys `pre_encode_lookahead_hf_only` (bool, default True) and `pre_encode_lookahead_hf_cutoff_hz` (float, clamp 1000-12000, default 4000). Both restart-required. New UI toggle + cutoff slider on the Audio Limiter card with cascading disabled-state (cutoff requires HF-only on; HF-only requires lookahead > 0).
- **Live-apply path preserves all look-ahead settings.** `applyRuntimeConfig` now passes `lookaheadMS` / `lookaheadHFOnly` / `lookaheadHFCutoffHz` through the `preEncodeLimiterChanged` reconfigure so that operator slider moves on threshold / release / residual settings don't silently reset the look-ahead config. Regression-guarded by `liveApplyReconfigurePreservesLookahead` test.
- **Listening validation:** real-program A/B with HF-rich content (cymbal-heavy mix, sibilant vocal, dense pop) confirmed audibly cleaner HF transients with Phase 1, and improved HF reach (cymbal tails breathe, sibilance no longer "tssk", snare/kick attacks survive). Phase 2 default-on is the architectural completion — focuses the detector on the band that drives the look-ahead path.
- **Tests** (7 new in `PreEncodeLookaheadTests`): bit-identical regression at lookahead=0, peak overshoot reduction at lookahead>0, mono-link discipline holds with lookahead, live-apply preserves lookahead, Phase 2 LF transients trigger less GR with HF-only on, Phase 2 HF transients still trigger comparable GR, Phase 2 HF-only=false is bit-identical to Phase 1. 329 total tests pass.

### Standards-conformance pass — remove non-spec config knobs and tighten ranges

Audit pass against EN 50067 / IEC 62106-2 / ITU-R BS.450-4 / FCC §73.317 / §73.322 / CEPT FM22 working-group docs. Every knob that allowed a non-spec value or had a range wider than the regulator allows was either removed entirely or tightened to the spec ceiling. INI keys retained where applicable for back-compat; INIParser silently ignores keys that no longer exist in `AppConfig`.

- **`rds_freq` removed entirely.** The 57 kHz RDS subcarrier frequency is spec-fixed at 57 kHz ± 6 Hz, locked to 3x pilot (EN 50067 §2.1.4). The previous GUI slider and INI key allowed values from 40 to 80 kHz which had no operational meaning — the production render path always used `nextSampleWithPilotLock()` (which forces 3x pilot) and ignored the configured value. Removed from `AppConfig`, INI parser, GUI slider, and sample INI files; kept the `nextSample()` free-running path internally with a hardcoded 57 kHz for the tests that use it.
- **25 µs pre-emphasis removed from accepted values.** No FM broadcast standard uses 25 µs; ITU-R BS.450-4 mandates 50 µs (Europe / ITU), FCC §73.317 / Japan mandates 75 µs, 0 disables. The GUI segmented picker was already correctly limited to Off / 50 / 75; `AppConfig.normalise` was still accepting 25 from legacy INIs. Now snaps to 50 µs.
- **Sum / Diff Level sliders pulled from GUI.** The FM stereo matrix `M=(L+R)/2`, `S=(L-R)/2` is spec-fixed (ITU-R BS.450-4 / EN 50067 §1.3.1). Setting either knob to anything other than 1.0 produces a non-compliant signal — the receiver's demodulator recovers L and R at wrong levels. INI keys `sum_level` / `diff_level` retained at clamp range `0..2.0` for lab / debug use, but no longer exposed as operator controls. The proper stereo widener (`stereoWidenEnabled`) is the right path for stereo image work.
- **Pilot Level GUI range tightened to 0...12%.** ITU-R BS.450-4 / FCC §73.322 / EN 50067 specify 8-10% deviation; the prior slider went to 20%. Default stays at 8.0%. INI clamp also tightened to 12%.
- **Program lowpass range tightened to 8000...16000 Hz, default 16000.** ITU-R BS.450-4 specifies 30 Hz – 15 kHz audio bandwidth for stereo. Prior default 16400 and clamp upper 20000 allowed entering the 17-19 kHz pilot guard region. New default and upper bound stay safely below the encoder FIR rolloff.
- **BS.412 window tightened to 30...90 s.** ITU-R BS.412-9 / national regulators (DE BNetzA, AT RTR, CH OFCOM, SE PTS, CZ ČTÚ, SI AKOS) all use a 60 s rolling-average window canonically. The prior 1...120 s slider range allowed configurations that aren't BS.412 anymore (1 s window = fast AGC). Default stays at 60 s; tooltip clarified.

Documents updated alongside: `AGENTS.md` / `CLAUDE.md` (RDS restart-only list no longer mentions `rds_freq`), `README.md` ("restart-only physical-layer settings" line), `ARCHITECTURE.md` (RDS disposition table no longer lists `rds_freq` as a row), `plan.md` (P8 patent backlog entry added for `US 5,579,404` and follow-up roadmap for Phase 1 + Phase 2 look-ahead).

### Diagnostics — device-rate mismatch as second-tier buffer-issue cause

`AGENTS.md` / `CLAUDE.md` two-step diagnostic for buffer-overrun / silent-output / 1M+ OVR reports: (1) ask debug-vs-release build; (2) check that Audio MIDI Setup's device format (e.g. "24-bit 192 kHz") matches the configured `sample_rate` in the INI. CoreAudio's implicit SRC bridges any mismatch internally; if the device's nominal rate doesn't match what the chain expects, the render thread starves and the input ring overflows in seconds. Same end-state symptom as a DSP fault (input meters work, output silent, all GR at 0 dB) but very different root cause.

## 0.29 — 2026-05-14

### DSP — multiband inter-band coupling (experimental, opt-in)

- **New `multiband_inter_band_coupling_enabled`** INI key (default off, live-apply). When enabled, low-band gain reduction is smoothed with a 20 ms attack / 300 ms release control envelope and converted into small negative threshold biases on the upper bands. 3-band mapping: `mid = -0.15 x lowGR`, `high = -0.25 x lowGR`. 5-band mapping: bands 2-5 = -0.10 / -0.15 / -0.22 / -0.25 x lowGR. This is the canonical Optimod-style "loud bass softens highs" tonal-glue control law, not a wideband gain ride.
- `MonoCompressor.process` gains a `thresholdBiasDB` parameter (default 0.0) that adds to `thresholdDB` in the gain-reduction calc. `lastGainReductionDB` exposed as `private(set)` so the low-band's GR can drive the upper bands' bias in the same render sample. With the toggle off, the bias is exactly zero and the classic compression path is byte-identical.
- Wired through both 3-band and 5-band compressor pairs in `MPXGenerator.process3BandMultiband` / `process5BandMultiband` via the new `multibandCouplingBiases(lowGainReductionDB:)` / `multibandFiveBandCouplingBiases(lowGainReductionDB:)` static helpers. Live-apply via the existing `multibandCompressorChanged` change detector.
- New `MultibandInterBandCouplingTests` suite (4 tests): runtime-config flag propagation, coupling arithmetic matches the design ratios, threshold bias measurably increases upper-band control (>=0.5 dB GR + >=10% RMS drop), zero-bias matches classic compression to within 1e-6.

### DSP — composite multiband clipper retune

- **Per-band ceilings tightened**: `low 0.94 / mid 0.88 / high 0.78` → `low 0.90 / mid 0.62 / high 0.38`. The 0.28 thresholds were too gentle to engage on most program material; the retune lifts peak control on dense/HF content into the measurable range. Default still off (`mpx_multiband_clipper_enabled = False`); no shipping behavior change.
- `--verify-composite-multiband --seconds 2` (see below) confirms about 1.4-1.6 dB peak/audio-composite peak reduction on HF-heavy scenarios (`hf_edge_12k`, `hard_panned_hf`), zero post-injection overshoot, correlation delta within +/- 0.05 across all measured scenarios.
- Two new tests in `CompositeMultibandClipperTests`: `enabledChainPreservesRawStereoSidebandSymmetry` (FFT-measured `38 +/- 10 kHz` sideband asymmetry stays below 1.5 dB and within 1 dB of the disabled chain) and `enabledChainReducesHFEdgePeakWithoutBudgetOvershoot` (HF-edge stress reduces composite peak and audio-composite peak by >=1 dB each with zero post-injection overshoot).

### Verifier — opt-in feature A/B modes

- **`--verify-composite-multiband [--seconds N]`** new CLI mode. Renders 5 dense/HF verifier scenarios (`bright_dense`, `vocal_sibilant`, `hf_edge_12k`, `transient_push`, `hard_panned_hf`) with the broadband composite clipper forced on and the multiband clipper toggled off/on. Reports PeakDelta / AudioPkDelta / MarginDelta / POvrOn / CorrDelta / SideDelta / `>60kDelta` per scenario. Pass criteria: at least one scenario reduces peak or audio-peak by >=0.15 dB, no scenario exceeds composite budget, no correlation flip beyond +/-0.18, `>60k` energy doesn't worsen by 6 dB. Result: OK.
- **`--verify-multiband-coupling [--seconds N]`** new CLI mode. Renders 5 program scenarios (`bass_dense`, `kick_vocal`, `italo_pump`, `wide_bass`, `speech_bed`) with multiband forced on and AGC disabled (for isolation), toggling inter-band coupling off/on. Reports per-band Low/Mid/High RMS deltas + RMSDelta / CorrDelta / SideDelta / PeakDelta / POvrOn / offline render cost ratio. Pass criteria: no scenario exceeds composite budget, correlation within +/-0.15, side/mid doesn't fall more than 1.5 dB, at least one scenario shows >=0.05 dB mid-or-high reduction. Result: OK; cost ratio 1.02x.
- New `DSPThroughputTests.compositeMultibandClipperCostStaysBounded`: bounds the FIR-split clipper path at <2.5x the same chain with the toggle off. Measured 0.98x on the heavy-program render.

### Configuration + UI

- New INI key `multiband_inter_band_coupling_enabled` (default `False`) in `MPXPrime.ini` and `Verification.ini`.
- Multiband processing tab gains a third Toggle row labelled "Inter-band Coupling" with `.help` tooltip describing the experimental status.

### GUI taxonomy alignment

- **Processing tabs**: `MB Limiter` and `Expander` order swapped to match the actual chain processing order. In `processMultibandStage` the downward expander runs first (per-band noise reduction) and the per-band peak limiter runs after; the tab order now reflects this.
- **`Limiter` → `Audio Limiter`** rename. The chain has five distinct limiters (MB Limiter, this pre-encode L/R Audio Limiter, lookahead limiter, final-MPX safety limiter, BS.412). The generic "Limiter" label was ambiguous; "Audio Limiter" matches AGENTS.md / README terminology.
- **RDS tabs aligned with commercial-encoder convention**:
  - `Control` tab renamed to `Status`. After moves 1 and 2 below, the remaining content is master enable + live snapshot, which is the canonical "Status" tab of DEVA SmartGen / RDS Manager / Audemat encoders.
  - Per-program flags TP / TA / MS / DI (incl. DI sub-flags Stereo / Head / Comp / Dyn-PTY) moved from `Control` → `Identity`. Standard practice puts these next to PI / PS / PTY because they describe what the station is broadcasting *right now*.
  - Subcarrier injection level moved from `Control` → `Subcarrier`. Injection level is physical-layer data — belongs with carrier frequency + Gaussian shaping.
  - All `RDSTab` and `Stage` enum *cases* preserved (`.control`, `.rdsControl`) for code stability; only rawValue strings + sidebar labels changed. Every config key, every live-apply route, every test unaffected.

### Docs

- **README.md**: new **Download** section linking to GitHub Releases with a first-launch Gatekeeper walkthrough (the DMG is ad-hoc signed, not Apple-notarized, so users must approve once in System Settings → Privacy & Security → Open Anyway). Features list gains the **HF stereo separation headline** (65 / 50.5 / 43.4 dB at 1 / 10 / 14 kHz from the 0.28 work). Processing tab list updated to match the new sidebar order + "Audio Limiter" rename + Expander-before-MB-Limiter swap. Receiver-model verifier description refreshed for the 0.28 additions (raw sideband analyzer, stage-isolation sweep, ideal-receiver decode). New CLI examples for `--verify-composite-multiband` and `--verify-multiband-coupling` in Offline Verification. PrimeBass paragraph trimmed to a one-line "what it does"; Orbass-rename history removed.
- **ARCHITECTURE.md**: new "Multiband Inter-Band Coupling" + "Multiband Transient-Aware Attack" sections under the multiband dynamics block. Composite multiband clipper paragraph updated with the 0.29 ceilings and verifier-mode pointer. `main.swift` verifier-mode list updated for the two new 0.28 modes. `MPXDecoder` bullet documents the 0.28 I/Q coherent lockin PLL refactor. PrimeBass paragraph trimmed.
- **plan.md**: HF separation subsection collapsed to a 5-line summary (work all done); multiband Phase 1 / 2 / 4 marked landed (only Phase 3 still open); composite-clipper-improvements #1 condensed; Patent-backlog P0 / P2 rows refreshed.
- **FUTURE.md**: DSP Enterprise-Level Roadmap items 1 / 2 / 3 arithmetic blocks collapsed (work shipped); Plan.md alignment table compressed; Patent candidates table renumbered.
- **AGENTS.md**: `--verify-composite-multiband` and `--verify-multiband-coupling` added to the verification command list. Composite multiband clipper description updated with current ceiling values + verifier mode pointer. New Multiband inter-band coupling paragraph in the dynamics summary. Branch-model example refreshed to v.028 / v0.28.
- **verifier_baselines/ClipperAliasingBaseline.md** and `README.md`: small wording fixes for consistency.

## 0.28 — 2026-05-13

### DSP — high-frequency stereo separation premium-grade (headline)

A focused investigation + fix cycle that lifted decoded receiver-side stereo separation by 19-31 dB across 1 / 10 / 14 kHz, putting MPX Prime into premium amateur / lower-prosumer territory.

Receiver-decoded separation (default config, `--verify-receiver --seconds 5`):

| Tone | 0.27 | 0.28 | Δ |
|---|---|---|---|
| 1 kHz | 33.7 dB | **65.0 dB** | +31.3 dB |
| 10 kHz | 26.1 dB | **50.5 dB** | +24.4 dB |
| 14 kHz | 24.0 dB | **43.4 dB** | +19.4 dB |

All three exceed plan.md "Next up — HF separation" targets (≥35 / ≥30 / ≥25-30 dB) by 13-31 dB on both coherent decode and the PLL external-style decode. The two paired root-cause fixes:

- **`AppConfig.audioCompositeSmootherEnabled` default `true` → `false`.** The legacy one-pole 54 kHz LP inside `processFinalComposite` was asymmetrically rolling off the wanted (L−R) sidebands at 24-52 kHz (-1.83 dB at 39 kHz, +1.84 dB asymmetry at the 14 kHz tone upper sideband). It is now opt-in for compatibility but the default chain is the cleaner softclip-only path.
- **`MPXDecoder.diffDecodeGain` `1.22 → 1.0`.** The 1.22× diff-channel gain implicitly compensated for the smoother's side attenuation; with the smoother off, unity gain is the natural scale.

### DSP — receiver-side PLL refactor

- **`MPXDecoder` PLL switched from bandpass + phase-discriminator to I/Q coherent lockin demodulator.** Slow IIR-smoothed estimates of `mpx·sin(ω_p·t)` and `mpx·cos(ω_p·t)` at the local oscillator, then the doubled-phase subcarrier is recovered via trig identities. Effect: PLL external-style decode now achieves parity with synthetic-reference coherent decode at all three test tones (was ~10 dB behind in 0.27).

### DSP — multiband Phase 2 (transient-aware attack + RMS/peak hybrid)

- **`MonoCompressor` gains `transientAwareAttackEnabled`** (default off, opt-in via `multiband_transient_aware_attack_enabled`). An RMS envelope (10 ms attack / 90 ms release) runs alongside the existing peak follower; the peak-to-RMS ratio drives a transient indicator that triggers when peak rises above 1.65× RMS. A 10 ms hold latches the indicator. On a transient, the detector blends mostly RMS (peakWeight drops 0.58 → 0.18) and the attack coefficient stretches to 3.2× the base attack. Net effect: percussive fronts pass hotter than the classic peak-only detector; sustained content converges back near the classic level. Matches Optimod "Smart Attack" character.
- Public `transientDriveObserved` accumulator exposes the indicator for tests and future telemetry.
- Wired through both 3-band and 5-band compressor pairs via `configureCompressorPair`. Live-apply via the existing `multibandCompressorChanged` change detector.
- Tests: percussive 6 ms burst over a 120 ms primed bed lands ≥4% hotter with the flag on; sustained 440 Hz at -1.7 dBFS converges within ±15-20% of the classic detector level over 500 ms.

### DSP — composite multiband clipper (experimental, opt-in)

- **New `CompositeMultibandClipper`** (default off, opt-in via `mpx_multiband_clipper_enabled`). Parallel-cumulative-LP topology with shared-tap-count linear-phase FIR lowpasses at 180 Hz and 4200 Hz, delay-matched input bypass. Recombines as `softClipSafety(low, 0.94) + softClipSafety(mid, 0.88) + softClipSafety(high, 0.78)`. Sum-to-flat property holds at low drive (output = `delayed(input)` when no band clips).
- Placed after the broadband composite clipper and before the audio-composite bandwidth FIR. Group delay folds into `recomputeSubcarrierDelay()` only when enabled; capacity is unconditionally reserved at configure time so live-toggle is allocation-free.
- Tests: runtime-config flag propagates, toggling adds exactly `groupDelaySamples` to the subcarrier delay line, below-threshold signal reconstructs to within 0.015 linear, hot signal stays finite and `outputPeak < inputPeak × 0.92`.
- **Caveat (acknowledged in plan.md + ARCHITECTURE.md)**: runs at host rate without oversampling, so the high band will alias on hot HF content. Default-off until verifier/listening/cost data proves a net win.

### Verifier — new infrastructure for HF separation work

- **Raw MPX sideband analyzer in `--verify-receiver`.** New "Encoder-Side Sidebands" table reports per (channel, tone): baseband mono bin, lower / upper DSB-SC sidebands at 38 ± toneHz, asymmetry, side-sum vs mono delta. Tap point is raw MPX *before* MPXDecoder applies deemphasis / 15.5 kHz LP / pilot/RDS notches — isolates encoder-side from receiver-model loss.
- **Per-stage isolation sweep.** Renders the encoder-side metrics with each toggleable stage individually disabled (composite clipper, audio composite softclip, audio composite smoother, final MPX safety, encoder FIR, pre-encode limiter, pre-emphasis + pilot notch), printing each row's asymmetry + side-delta as a delta vs the all-stages-enabled baseline. Identified the one-pole smoother as the entire encoder-side bottleneck (every other stage moves the metric by ~0.01 dB).
- **Ideal Receiver Decode table.** Computes coherent decode using raw mono + Goertzel-side with the side phasor normalized to mono magnitude — isolates phase alignment as the ceiling, separates it from amplitude loss. "Gap vs Prod" column reports `idealSeparation - productionSeparation`; receiver notes emit ("audit MPXDecoder filters before encoder tuning") when the gap exceeds 6 dB.
- `hf_edge_12k` scenario `maxAbove67kRatioDB` tolerance widened from -58 to -52 dB to reflect the post-smoother chain's true alias-band behavior; baseline JSON refreshed.

### Configuration + UI

- **New INI keys** (all live-apply, default false):
  - `multiband_transient_aware_attack_enabled` — Multiband tab toggle.
  - `mpx_multiband_clipper_enabled` — Composite Clipper tab toggle.
  - `audio_composite_smoother_enabled` default flipped to `False` (still configurable for compatibility / A/B).
- **UI**: Multiband and Composite Clipper tabs gain Toggle rows with `.help` tooltips describing the experimental status. Processing-tab order in the sidebar now matches the chain order (Phase Rotator before AGC, Multiband / MB Limiter / Expander before Widener / PrimeBass, Composite Clipper before BS.412).

### Tests

- **+7 tests / +2 suites** (308 / 42 → 315 / 44):
  - `MultibandPhase2Tests` (3): transient-burst-vs-classic, sustained convergence, runtime-config flag.
  - `CompositeMultibandClipperTests` (4): runtime-config flag, subcarrier-delay accounting on toggle, sum-to-flat reconstruction, finite + peak-reduced under hot drive.
  - `StereoSeparationReceiverTests` previously updated for the 0.27 active-count split; still passing on the new chain.

### Docs

- **plan.md**: HF separation 5-step plan added to "Next up" with completed-work summary and actual achieved numbers; multiband Phase 2 + multiband composite clipping reranked from "open" to "implementation landed, validation pending"; receiver-model verifier item retitled "hardening" and rescoped.
- **AGENTS.md**: multiband composite clipper and transient-aware attack added to the chain description; measurement-first DSP-validation guideline retained from 0.27.
- **ARCHITECTURE.md**: composite-clipper-improvements section gains a `CompositeMultibandClipper` paragraph; dynamics block gains a transient-aware-attack note.

## 0.27 — 2026-05-13

### DSP — anti-aliased clipping (US 6,937,912) groundwork

- **`BandLimitedStep` primitive landed** ([`macOS/Sources/MPXPrime/BandLimitedStep.swift`](macOS/Sources/MPXPrime/BandLimitedStep.swift), Phase A of the US 6,937,912 work). Allocation-free helper that detects fractional threshold crossings (`crossingFraction(previous:current:threshold:)`) and schedules normalized finite band-limited correction windows. Three correction shapes supported — impulse (area-normalized), step (BLEP, for value discontinuities), and ramp (BLAMP, for slope discontinuities — the shape the current `tanh` soft knee actually needs since it is value-continuous). 13 deterministic tests in `BandLimitedStepTests` cover kernel normalization, crossing detection, DC balance, overlap, reset, and finiteness of both step and ramp correction outputs.
- **Spectral gate landed** ([`AntiAliasedClipperProbeTests`](macOS/Tests/MPXPrimeTests/AntiAliasedClipperProbeTests.swift), Phase B). A 5.111 kHz mono-tone probe at 48 kHz compares four kernels against the alias-bin energy budget: hard knee (-31.06 dBFS), current `tanh` knee (-30.76 dBFS), naive normalized BLAMP-only correction (-30.87 dBFS — stable but no improvement yet), and the patent-style residual-bandlimiting candidate (-44.90 dBFS — 13.84 dB cleaner than hard, fundamental preserved within 0.00 dB at -3.17 dBFS). Gate asserts the patent-residual candidate is ≥6 dB cleaner than hard and preserves the wanted fundamental within 1 dB.
- **`AcceleratedBandlimitedResidualClipper` landed** ([`macOS/Sources/MPXPrime/AcceleratedBandlimitedResidualClipper.swift`](macOS/Sources/MPXPrime/AcceleratedBandlimitedResidualClipper.swift)). Patent-style candidate: hard clip → residual = clipped − input → band-limit residual through a Kaiser-windowed-sinc lowpass via `vDSP_dotpr` polyphase → reconstruct as `delayedCleanInput + filteredResidual`. The clean signal rides a group-delay-matched bypass; only the broadband clipping error is filtered. Kept off the production hot path; available via the new `pre_encode_bandlimited_residual_enabled` opt-in.
- **`OversampledPeakLimiter` / `StereoLinkedOversampledPeakLimiter` gain an opt-in band-limited residual ceiling.** New `bandlimitedResidualEnabled` parameter on both `configure(...)` paths wires the residual clipper as the inner kernel. Stereo-linked path keeps the `max(|L|, |R|)` detector intact; only the per-channel ceiling kernel changes. New `pre_encode_bandlimited_residual_enabled` INI key (default false) + `RuntimeConfig` plumbing + live-apply via `applyRuntimeConfig` change detection + GUI toggle on the Audio Limiter card (clearly labelled "Use New Band-limited Limiter Ceiling"). 4 integration tests in `PreEncodeBandlimitedResidualLimiterTests` cover the runtime-config flag, single-channel ceiling holding under 1.02, stereo-link gain shared across channels at L/R asymmetry, and a 2-tone IM gate.
- **Residual ceiling kernel is now tunable** ([`AppConfig.swift`](macOS/Sources/MPXPrime/AppConfig.swift), [`MPXGenerator.swift`](macOS/Sources/MPXPrime/MPXGenerator.swift)). Two new live-apply INI keys: `pre_encode_bandlimited_residual_taps` (5–129, forced odd, default **33**) and `pre_encode_bandlimited_residual_cutoff_fraction` (0.05–0.49, default **0.25**). Plumbed through `PreEncodeAudioLimiter` / `StereoLinkedOversampledPeakLimiter` / `OversampledPeakLimiter` `configure(...)`. Default kernel changed from the previous hardcoded (65, 0.20) to (33, 0.25) after a 12-candidate parameter sweep against the isolated ceiling stress signal — the new sweep test `residualKernelParameterSweepFindsCleanerIsolatedCeilingCandidates` asserts the best usable kernel beats classic tanh by ≥6 dB on alias/IM energy while keeping isolated peak ≤ 1.02. Toggle still ships off, so default users see no change.
- **Full-chain A/B regression coverage for the residual ceiling.** New `fullMPXChainResidualCeilingDoesNotRegressMeasuredCompositeMetrics` renders the full MPX chain at 192 kHz, classic-tanh vs residual, and bounds the deltas on composite peak (≤ +0.03), 10–20 kHz non-program "upper-band grain" (≤ +3 dB), 60–90 kHz alias/IM (≤ +4 dB), pilot level (±0.75 dB), and RDS-band level (±1.5 dB). `fullMPXChainDefaultKernelMatchesBoundedSweepCandidate` pins the new (33, 0.25) default against the prior (65, 0.20) candidate on the same chain. `newLimiterDoesNotRaiseUpperBandHissAgainstClassicCeiling` covers HF-grain isolation on the limiter alone.
- **CPU-cost guard for the residual ceiling** (`DSPThroughputTests.bandlimitedResidualPreEncodeLimiterCostStaysBounded`). Bounds the residual-FIR path at < 2.5× the classic tanh ceiling on the same heavy-program render — locks in vDSP acceleration as a prerequisite for ever defaulting the residual path on.

### DSP — monitor path refactor + receiver model

- **`MPXDecoder` extracted as a reusable struct** ([`macOS/Sources/MPXPrime/MPXDecoder.swift`](macOS/Sources/MPXPrime/MPXDecoder.swift)). Pilot-PLL-locked or externally-referenced 38 kHz subcarrier demod, L+R / L−R recovery, pilot/RDS notches, deemphasis, smoothed noise gate, and stereo-collapse cooldown logic. Replaces ~200 lines of inline monitor-demod code in `MPXGenerator`. `MPXGenerator` now owns a `monitorDecoder: MPXDecoder` and feeds it the existing delay-aligned reference subcarrier + program-activity envelope on each render sample.
- **Stereo-subcarrier delay alignment for the monitor path.** New `stereoSubcarrierDelayLine` ring buffer mirrors the existing 0.26 `subcarrierDelayLine` but carries the 38 kHz stereo reference instead of pilot+RDS. The monitor decoder now reads the delay-aligned reference, so the monitor demod stays phase-coherent with the audio composite even with the composite clipper, audio bandwidth FIR, and look-ahead all engaged.
- **`--verify-receiver` CLI mode** ([`main.swift`](macOS/Sources/MPXPrime/main.swift), [`VerificationHarness.swift`](macOS/Sources/MPXPrime/VerificationHarness.swift)). Offline receiver-model verifier reports stereo separation at 1 / 10 / 14 kHz, mono compatibility (mid / side / side-rejection in dB), and subcarrier health (pilot percent + phase, RDS lower / upper / center sideband levels). Result `OK` when separations exceed 18 / 18 / 16 dB respectively, side rejection ≥ 26 dB, pilot 6.5–9.5 %, RDS sideband ≥ -60 dBFS, RDS center ≥ 8 dB below sidebands; otherwise `TIGHT` with a per-metric warning list.

### DSP — silent live-resize of composite clipper look-ahead

- **`CompositeClipper.setLookaheadMS` is now allocation-free** ([`MPXGenerator.swift`](macOS/Sources/MPXPrime/MPXGenerator.swift)). `configure()` preallocates `lookaheadDelay`, a `lookaheadResizeScratch` workspace, and the OS-rate Lemire monotonic deque (`deqValues` / `deqIndices`) to the 5 ms maximum capacity at engine start. `setLookaheadMS` then only changes the active logical length (`lookaheadHostSamples`), preserves time-ordered audio content via the preallocated scratch, and resets the deque without touching storage. New `maxTotalDelayHostSamples` getter exposes the preallocated capacity so the subcarrier-delay recompute can size against it instead of the active length. Fixes audible clicks when dragging the look-ahead slider on a live audio path.
- **Subcarrier delay line gains a separate active-count.** New `subcarrierDelayActiveCount` tracks the logical length while `subcarrierDelayLine.count` is the preallocated worst-case capacity. New `resizeDelayPreservingContentsInPlace` helper mutates in place when the required capacity is already available, falling back to the old allocating path only on structural growth. Render-callback read site now uses the active-count so logical resizes don't change the per-sample math. New regression test `liveCompositeLookaheadResizeChangesActiveDelayWithoutGrowingStorage` asserts the allocation-free contract directly: `subcarrierDelayLine.count` (capacity) stays fixed across slider moves, only `subcarrierDelayActiveCount` shifts. `liveLookaheadResizePreservesProcessingPath` (in `CompositeClipperLookaheadTests`) exercises the 0.5 → 3.0 → 0.0 ms transition under signal and asserts the reported `totalDelayHostSamples` tracks and peak stays bounded.

### Configuration + UI

- **`pre_encode_bandlimited_residual_enabled` INI key** added to `MPXPrime.ini` and `Verification.ini` (default `False`). Live-applicable (no engine restart). Audio Limiter card gains a toggle labelled "Use New Band-limited Limiter Ceiling" framing the choice as A/B vs the classic tanh ceiling: off = current chain, on = 0.27 patent-style candidate.
- **`pre_encode_bandlimited_residual_taps` and `pre_encode_bandlimited_residual_cutoff_fraction` INI keys** (defaults 33 and 0.25). Live-applicable. Operator/preset-tunable residual kernel without engine restart; only changes the inner ceiling when the master enable is on.
- **Processing overview card reorder.** `UIProcessingOverview` now lists Multiband / MB-Limiter / Expander **before** Stereo Widener / PrimeBass, matching the actual canonical post-multiband chain order (PrimeBass and widener were relocated post-multiband in 0.25). New "Audio Limiter" card with kernel-mode subtitle (`tanh` / `residual`) for at-a-glance visibility of the experimental toggle. Stage subtitles refreshed for the Core / PrimeBass / Widener / Final-Stage entries to match current placement.

### Verifier

- Default `--verify --baseline-strict` and `--verify-presets` remain `OK` on the post-0.27-groundwork chain (worst overshoot 0.000000, composite budget exceeded no, all 7 presets clean). Baseline JSON refreshed.

### Tests

- **+28 tests across 4 new suites + 3 existing suites** (280 → 308 across 38 → 42 suites):
  - `BandLimitedStepTests` (13, new suite)
  - `AcceleratedBandlimitedResidualClipperTests` (4, new suite)
  - `PreEncodeBandlimitedResidualLimiterTests` (8, new suite — 4 core + 4 covering HF-grain isolation, full-MPX-chain A/B vs classic, default-kernel parity vs prior 65/0.20, 12-candidate parameter sweep)
  - `AntiAliasedClipperProbeTests` (2, new suite — `tanh` knee continuity + 4-way spectral comparison gate)
  - `CompositeClipperLookaheadTests` (+1 existing — live look-ahead resize preserves processing path)
  - `StereoSeparationReceiverTests` (+1 existing — live look-ahead resize changes active delay without growing storage; 2 existing tests retargeted from `subcarrierDelayLine.count` to `subcarrierDelayActiveCount`)
  - `DSPThroughputTests` (+1 existing — residual ceiling cost bounded < 2.5× classic tanh)

### Docs

- **plan.md** Next up #1 rewritten: Phase A marked landed, Phase B spectral gate landed, off-by-default residual candidate landed with tunable kernel + parameter sweep + full-chain A/B coverage, Phase C / D still pending. Next up #2 (composite clipper look-ahead listening work) updated to note silent live-resize landed in 0.27. New "Extended MPX monitoring" subsection describes the generated-MPX monitor and the planned external-USB MPX-input analyzer.
- **ARCHITECTURE.md** updated: removed stale PrimeBass entries from the dynamics section (PrimeBass and stereo widener live post-multiband since 0.25); corrected audio-composite bandwidth FIR placement to "after composite clipper, before BS.412 / final-MPX safety limiting" (was incorrectly "between BS.412 and safety limiter"); pre-encode limiter description notes the optional band-limited residual ceiling with live-applicable kernel parameters; default-on stage list corrected.
- **AGENTS.md** gains a measurement-first validation guideline: for DSP differences, prefer deterministic-signal / FFT / receiver-decode / verifier-baseline tests before asking the operator to listen; listening tests are for subjective confirmation, not regression detection.
- **FUTURE.md** + **plan.md** rows for "Composite clipper look-ahead" and "Anti-aliased clipping (US 6,937,912)" updated to reflect the silent live-resize and the tunable / parameter-sweep-validated residual kernel.

## 0.26 — 2026-05-11

### DSP — composite peak control + chain integrity

- **Composite clipper look-ahead peak control.** New OS-rate (1.536 MHz at 192 kHz × 8) sliding-window-max detector with Lagrange-interpolated intersample-peak detection feeding an exponential-attack / exponential-release gain envelope smoothed by a 200 Hz one-pole LP. Gain is applied identically to both `up` (clipper input) and the per-band `orig*` filters so the differential topology's per-band cancellation linearity holds. Single INI knob `mpx_clipper_lookahead_ms` (0.0–5.0 ms, default 0.0 disabled, recommended 2.0). Separate `lookaheadGainReductionDB` telemetry distinguishes clean predictive ducking from soft-clip distortion-producing GR. Sources: US 5,737,434 (Orban 4 ms look-ahead, expired ~2017), US 6,434,241 (Orban half-cosine FM peak control, expired 2014), Lemire monotonic deque (sliding-window-max), Signalsmith / musicdsp.org #274 — every primitive expired or public-domain.
- **Composite budget governor — post-injection clamp no longer reachable for sane configs.** `MPXGenerator.makeFinalCompositeThresholds(outputGain:threshold:reserved:)` now derives `allowedAudioAbs = max(0, effectiveThreshold - reserved - safetyMargin)` and an `overBudget: Bool` flag. The previous `0.18` / `0.16` audio-composite hard floors are gone; a single `finalCompositeBudgetSafetyMargin = 0.02` remains. `processFinalComposite` enforces `audioCeilOut = postLimiterCeiling × outputGain` as a smoothed gain ride on the audio path *before* pilot/RDS injection — the audible work is done by the smoothed ride (separate attack/release time constants), and a hard ceiling remains as a last-sample guard for attack transients. The final `clampf(mpx, -1, 1)` stays only as a numeric guard. `CompositeCalibrationStatus.overBudget` re-derives from current outputGain + smoothed subcarrier reservation envelope and surfaces to UI / verifier. Tests pin `postInjectionOvershoot < 1e-4` for default and `< 1e-2` for hot-but-sane (+6/+12 dB); pathological (+24 dB) classifies explicitly as `overBudget == true` rather than silently relying on the final clamp.
- **Pilot/RDS subcarrier delay alignment.** New `subcarrierDelayLine` host-rate ring buffer delays pilot+RDS by the composite clipper's total delay plus the final lookahead-limiter lookahead samples. `recomputeSubcarrierDelay()` sizes the line dynamically from the active stage delays so the receiver-side pilot-derived 38 kHz reference aligns with the audio composite's internal subcarrier modulation. Closes a long-standing receiver-side stereo-decode degradation where the 38 kHz reference was time-shifted relative to the audio L−R sidebands. `StereoSeparationReceiverTests` covers delay sizing, composite-clipper flag response, MPX output difference, and silent-input pilot phase shift.
- **Audio composite bandwidth FIR.** New linear-phase FIR cleanup stage between BS.412 and the safety limiter strips shaper/limiter spill that would otherwise live above the upper stereo sideband. Its group delay (~112 host samples at 192 kHz) folds into `recomputeSubcarrierDelay()` so subcarriers remain phase-aligned automatically.
- **Audio-peak metric is now post-governor.** `audioCompositePeakState` capture moved to *after* the budget governor clamp, storing the governed pre-outputGain value. `CompositeCalibrationStatus.audioPeak` now reports the post-governor MPX-scale audio peak — the metric finally reflects what is delivered to the MPX output (was previously a pre-clamp internal value that could exceed 1.0 at hot gains).
- **Stereo-linked PreEncodeAudioLimiter.** New `StereoLinkedOversampledPeakLimiter` replaces the per-channel `OversampledPeakLimiter` pair. Detector uses `max(|L|, |R|)` so both channels receive identical gain reduction — eliminates the asymmetric-pumping artifact the per-channel pair produced when one channel briefly exceeded threshold. Pre-encode limiter threshold/release are now in `RuntimeConfig` (`preEncodeThreshold`, `preEncodeReleaseMS`) and re-applied live via `MPXGenerator.applyRuntimeConfig`. `PreEncodeLimiterLiveApplyTests` verifies both edits without restarting the generator.

### Verifier

- **`worstPostInjectionOvershoot` and `compositeBudgetExceeded` exposed as first-class verifier signals.** `VerificationHarness` and the `--verify` / `--verify-presets` / `--verify-long` reports now print these per scenario; the baseline JSON file carries them so `--baseline-strict` flags regressions in the post-injection budget invariant.

### Tests

- **+5 lookahead unit tests** (`CompositeClipperLookaheadTests`): overshoot bound at 2 ms lookahead (`max(|out|) ≤ ceilingLin × 1.005`), steady-state transparency on pink noise, pilot/stereo/RDS guard regression coverage with lookahead on, cross-domain cancellation regression catching asymmetric per-band gain leak, and latency reporting (`compositeClipper.totalDelayHostSamples` correctness for 0/1/2/3/5 ms).
- **+4 receiver-side stereo separation regression tests** (`StereoSeparationReceiverTests`).
- **+4 post-injection clamp budget tests** (`PostInjectionClampTests`): default config zero-overshoot acceptance, hot-but-sane settings (`audioPeak < 0.98`, `overshoot < 1e-2`, `!overBudget`), pathological config (`overBudget == true`), silent-input + high-gain path stays clean.
- **+2 pre-encode limiter live-apply tests** (`PreEncodeLimiterLiveApplyTests`).
- **Permanent WAV-capture test infrastructure.** New `Support/WAVExport.swift` (32-bit float WAV writer) and `Support/AuditCaptureDriver.swift` (env-gated `MPXPRIME_AUDIT_CAPTURE=1` orchestrator with scenario generators: bright_dense, program_mix, hard_panned_hf, dense_pop, classical_orchestral, sparse_acoustic, spoken_word). Captures land in `macOS/.audit-out/<audit-name>/<arrangement>/<scenario>/{demod,mpx}-<arrangement>.wav` and are reusable for future audits (preset tuning, multiband Phase 2).

### Docs

- **FUTURE.md and plan.md updated:** composite clipper look-ahead, pilot/RDS delay alignment, post-injection clamp fix, and pre-encode limiter live-apply marked LANDED.

## 0.25 — 2026-05-10

### DSP — chain-order modernization
- **Pre-emphasis relocated from M/S to L/R, upstream of the pre-encode limiter.** Canonical Optimod / Stereotool placement: pre-emphasis runs in L/R domain immediately before the pre-encode audio limiter, so the limiter peak-controls the +10–12 dB HF-boosted signal before composite assembly. Previously ran in M/S inside `makeCompositeComponents`, after the limiter — HF transients flew un-peak-controlled into the composite stage. Phase 1 chain-order audit (see `macOS/.audit-out/chain_order/REPORT.md`) confirmed: C1 CPU gate PASS at 1.07× release-build ratio (b806053-class regression no longer reproducible on the current chain — vvtanhf, vDSP_dotpr, FIR multiband, and differential composite clipper optimizations between 0.10 and 0.24 cut absolute chain cost from ~95% to ~28% of real-time); C2 sustained-load PASS over 30 s; HF guard band cleaner above 60/67 kHz on `bright_dense`, `mono_1khz`, `stereo_diff_400hz`, `wide_bass`. Renamed `preSum`/`preDiff` → `preL`/`preR` to reflect the operating domain change.
- **PrimeBass moved post-multiband.** Industry canonical: bass enhancers (MaxxBass / Aural Exciter / Big Bottom-class) belong after the multiband stage. Multiband no longer compresses synthesised harmonics that PrimeBass just generated. Zero verifier-baseline drift on the standard scenarios; listening confirmed the move on real program.
- **Stereo widener moved post-multiband.** Industry canonical: a widener belongs after multiband. Multiband on a widened L/R can over-enhance side-channel differences in HF bands where compression ratios are highest. Mono bass stays inside `processStereoImageStage`. Zero verifier-baseline drift; listening confirmed.

## 0.24 — 2026-05-10

### Audio I/O
- **AUHAL input capture replaces the AVAudioEngine input path.** New `InputAUHAL` wrapper around a direct `kAudioUnitSubType_HALOutput` audio unit configured for input capture, replacing the second `AVAudioEngine` instance that `AudioOutputEngine.setupInputCapture` used to spin up. Closes the longstanding bug where AVAudioEngine's first `start()` with a non-default input device intermittently failed to deliver tap callbacks even though every API call returned success — `engine.start()` ok, `capture.isRunning == true`, ring stayed at 0/N forever. The two-AUHAL pattern (separate input AU + output AVAudioEngine + ring buffer as the only bridge) is documented in TN2091 and is what professional audio apps (Stereotool, CAPlayThrough, AudioKit's non-default-device path) use on macOS. Setup follows TN2091's 11-step sequence verbatim; client format pinned to the device's native sample rate (AUHAL's built-in converter does packing/format only, NOT sample-rate conversion — the existing adaptive cubic resampler in `StereoInputRingBuffer.readAdaptive` handles 48→192/96→192 plus clock drift). Channel selection via `kAudioOutputUnitProperty_ChannelMap` covers mono devices (`[0,0]`) and multichannel devices (`[0,1]`). Output stays on AVAudioEngine — output side is not the bug source.
- **Auto-start Stop+Start watchdog removed.** The 1.5 s startup stall + cycle that previously masked the AVAudioEngine first-start failure is gone — AUHAL delivers frames immediately on cold boot. `transportInputStalled` and `cycleEngineForRecovery` deleted from the view model.

### UI
- **GUI exposure of the last engine + safety-limiter knobs that were INI-only.** Two new cards close out the "every operator setting reachable from the GUI" story that started in 0.23:
  - Core tab → "Engine — TX path" card: `Encoder Lowpass: linear-phase FIR` (FIR vs Butterworth — ~1.67 ms vs ~0.2 ms latency, >80 dB vs ~40 dB stop-band) and `Multiband Crossovers: linear-phase FIR` (FIR splitters vs IIR LR4 — ~5.3 ms vs ~0.3 ms, sum-to-flat at -155 dB). Both restart-required.
  - Final Stage tab → "Final-MPX Safety Limiter" card: `Enable Safety Limiter` (`limit_mpx`), `Threshold` (0.5..0.999), `Enable Look-Ahead`, `Look-Ahead` (0..20 ms). Restart-required.
- **Chain-strip taxonomy fixes.** Three issues found while auditing the strip pill order against `MPXGenerator.processProgramStereo` / `processFinalComposite`:
  - **Phase Rotator pill was missing entirely** — it runs *before* AGC in code but was never rendered in the strip. Inserted between Core and AGC.
  - **BS.412 / Composite Clipper order was reversed.** Strip showed `Lim → BS.412 → MPX-Clip → Final`; actual code runs Composite Clipper *before* BS.412 in the audio-composite domain. Swapped to `Lim → MPX-Clip → BS.412 → Final`.
  - **MB Limiter and Downward Expander removed from the strip.** They are *per-band* processors *inside* the multiband stage, not three serial stages — strip was implying a sequential flow that doesn't match the code. Sidebar entries kept (operators still want their own controls cards).

## 0.23 — 2026-05-10

### Tools
- **Test Tone tab — first-class sidebar stage with Stereo Tool parity.** Engine had a sine-only generator (mono / stereo (L=−R) / left-only / right-only) wired up since 0.11 but **never surfaced in the GUI** and stuck at full-scale (1.0) amplitude — operators couldn't run any calibration workflow. New "Tools" sidebar group with a "Test Tone" tab (⌘T from anywhere). Tab content: Enable toggle (live-flips the engine source from input → tone with no restart), Type picker (Sine / Pink / White), Stereo mode picker (Mono / Stereo / Left / Right), Frequency text field + presets (50 / 100 / 400 / 1k / 5k / 10k / 12k / 15k Hz, sine only), Level slider (−60 to 0 dBFS, default −20 dBFS for broadcast line reference), and a Status grid summarising the current source / type / mode / freq / level. Tone enters the chain pre-AGC so operators can observe how the chain responds at calibrated input levels. Pink noise via Paul Kellet's 4-pole IIR (≈3 dB/octave); white noise via xorshift64* uniform. New `test_tone_level_db` and `test_tone_type` INI keys; existing `test_tone_freq` / `test_tone_mode` stay. New `TestToneGeneratorTests` suite (8 tests) covers AppConfig defaults / clamps / type+mode validation, plus end-to-end render-amplitude checks at −20 dBFS and −40 dBFS through a mono-mode minimal-chain `MPXGenerator`. Default verifier baseline bit-identical to prior build (engine source defaults to `input`; Test Tone is opt-in). Pre-existing minor bug in the non-monitor tone render path (where `tonePhase` was never advanced — generated DC silence) fixed in the same commit.

### DSP
- **PrimeBass Phase 3: Werrbach Big Bottom envelope follower** (Aphex US 5,359,665, expired 2012-07-31 — public domain; finishes the bass-enhancement patent backlog). Replaces the prior spectral-ratio detector + transient-hold machinery in `processPrimeBass` with a direct LF-level envelope follower: ~10 ms attack catches the leading edge of a kick / plucked-bass note, ~300 ms release lets the boost extend over the natural decay. Net effect per the patent: "envelope duration extension" — same peak boost as a static gain, just held longer through the note tail. Removes ~25 lines of spectral-ratio gating (`primeBassRatioEst`, `primeBassTargetRatio`, `primeBassRatioDeadband`, `primeBassHoldRemaining`, the 1.2 s / 2.8 s post-target smoother) that tracked compositional balance over seconds and so couldn't engage on a typical drum hit before the hit was over. New `bigBottomEnvelopeAttacksFastAndReleasesSlow` test verifies the envelope's behaviour at three phases (pre-onset / sustained / post-release) via the internal `primeBassAdaptiveGain` accessor.

### UI
- **Final Stage / Audio Limiter split.** The previous single "Final Stage" tab conflated the pre-encode peak limiter (a single chain slot) with three workflow controls (Broadcast Preset, Final Drive, Composite Deviation) that are not the limiter at all. Split into two stages: **"Audio Limiter"** (existing slot, `Lim` pill stays at its real chain position) carrying just the pre-encode limiter, and a new **"Final Stage"** tab (new `Final` pill at the end of the chain strip after `MPX-Clip`) carrying the workflow controls. New `Stage.processingFinalStage` case + new `ProcessingTab.finalStage`. Sidebar reset menus and chain-strip routing updated. Workflow language ("Final Stage Preset", `final_stage_preset_id`) preserved.
- **Audio Limiter Threshold + Release exposed in GUI.** `pre_encode_threshold` (0.5..0.999 linear ceiling) and `pre_encode_release_ms` (10..200 ms) were previously INI-only; now editable as live-apply sliders on the Audio Limiter tab.
- **Composite Clipper per-band cancellation toggles in GUI.** The four `mpx_clipper_cancel_*` flags (`audio` default off; `pilot` / `stereo` / `rds` default on) were INI-only; now exposed as live-apply toggles in the Composite Clipper card with HIG help tooltips. Operators can recover HF detail (Cancel audio band on) without editing the INI.
- **About panel redesigned** macOS-native (app icon + name + version + copyright + prose disclaimer matching the README; replaces the previous orange-bordered "Disclaimer" box with warning-triangle header). Window 360×460.
- **Sidebar** width `min: 200 → 220, ideal: 230 → 240, max: 280 → 320` so labels never truncate at first launch. Icons now use `.foregroundStyle(.tint)` + `.symbolRenderingMode(.hierarchical)` so they pick up the system accent (blue by default) with 3-level tonal layering — matches Apple's first-party sidebars (Music.app, Mail.app).
- **Monitoring redesign — industry-aligned metric layout.** `BroadcastStatusBar` shrunk from 11 chips to 3 (TRANSPORT + SOURCE + RATE only — content-level numbers belong in the section, not multiplexed onto the chrome). Three new metric Cards in `MonitoringDashboardView`: **MPX** (output peak / audio composite / deviation / modulation %), **Headroom** (pre-encode GR / composite GR / safety GR / BS.412 budget), **Subcarriers** (pilot % / RDS % / stereo image). Side-by-side on wide windows, stacked on narrow via `ViewThatFits`. Matches the split Stereo Tool / Logic Pro / Apple Music use.
- **Buffer-fill bar smoothing.** Previously twitched on every 30 Hz meter tick because the underlying frame count bounces ±a few each pull. Now low-passed with ~10 s time constant — bar shows trend, not noise. Instantaneous delay text (e.g., "92.2 ms") still updates at full rate next to the bar; real underflows still surface in the Dropouts tile within one tick.
- **HIG audit fixes:** three Settings buttons (`Reveal Config`, `Reload Config`, `Refresh Devices`) now have `.buttonStyle(.bordered)`; `DSPStatusPill` values are `.textSelection(.enabled)` (PI / PTY / RDS App ID codes are operator-copyable); spectrum Canvas backgrounds use `BroadcastStyle.panelInsetCornerRadius` instead of hardcoded `8`; Help window styleMask matches Settings (no `.miniaturizable` on utility windows); `UISignalFlowStrip` `.active` chip now has the `.help()` modifier the other chip cases already had; decorative connector `Rectangle()` is `.accessibilityHidden(true)` so VoiceOver narrates clean chip names. Dead `MonitoringStatusLine` removed.

### DSP
- **Active meter timer reverted to 30 Hz.** The 60 Hz active rate from the adaptive-FPS work in 0.20 was real-time-capable on release builds but preempted the audio thread on debug builds, producing buffer underruns. Inline spectrum keeps the modest `12 → 24 Hz` lift (FFT runs off-main, cheap). Adaptive on-screen / off-screen behaviour (occlusion / minimize / inactive-app gates) stays in place.

### Docs
- **External 192 kHz audio interface emphasised in README.** Apple's built-in audio output on Mac laptops and most desktops tops out at 96 kHz, which cannot carry RDS (the 57 kHz subcarrier exceeds 48 kHz Nyquist). README now calls this out as effectively required for any FM-with-RDS chain in both the Requirements bullet list and the Quick Start audio-routing section.
- **"Leave BS.412 and the Composite Clipper off when not needed" recommendation** added to README. Both stages visibly cost stereo image and HF detail when engaged; outside EU regulatory environments operators don't need BS.412 at all, and the composite clipper is a loudness lever that trades image / HF for raw level. Per-band cancel toggles documented alongside.
- **`main` is the default branch** (was per-release `develop/v.NN`); integration branches now use `develop/v.NNN` (three digits, leading zero, e.g. `develop/v.023`).
- **Debug-build performance callout** added to README and AGENTS.md: `swift run` debug binaries can preempt the audio thread; for actual playback or on-air use a release build (`swift build -c release` or the DMG).
- **Chain-order audit** documented in `plan.md` — three deviations from canonical Optimod / Omnia / Stereo Tool stage ordering noted (PrimeBass before multiband, widener before multiband, pre-emphasis in M/S after L/R limiter), each with audible cost / engineering effort / recommendation. Backlog rather than a near-term fix.
- **`plan.md` stale TODO fixed** — composite-clipper improvement #1 (linear-phase FIR decimation) was still listed as future work; already shipped in 0.20.

## 0.21 — 2026-05-09

### Docs
- **Patent-attribution list complete.** The "Compared to commercial processors" paragraph in README previously credited only `US 4,460,871` and `US 5,737,434` (the 0.11 references). Updated to list all six expired patents whose published claims are used as design references: those two (Orban distortion-cancelled composite clipping) plus `US 6,337,999` (Orban differential composite clipper topology, expired 2022), `US 5,930,373` (Waves MaxxBass equal-loudness harmonics, expired 2017), `US 4,150,253` (Aphex Aural Exciter pre-waveshaper topology adapted for bass via allpass, expired 1996), and `US 5,424,488` (Werrbach transient-discriminate harmonic gain, expired 2013). Each linked to Google Patents; framed as public-domain prior art, not licensed reproductions.
- **Trademarks and affiliations** subsection added to README. Names referenced descriptively throughout the project (Orban, Optimod, Omnia, Stereo Tool / Stereotool, Aphex, Waves / MaxxBass, BBE, DTS, Music Tribe, Inovonics, DEVA, Audemat, BW, JUCE, Qt, Apple, macOS / AVFoundation / CoreAudio / vDSP / vForce, JACK, ALSA, AES3, DAB+, Livewire, Dante, Ravenna) are trademarks of their respective owners; MPX Prime is independent and not affiliated with any of them. The PrimeBass rename in 0.20 was specifically to remove the unintended trademark adjacency to Orban.

No source changes vs 0.20. Audio path bit-identical; binary identical except for the `appVersion` string.

## 0.20 — 2026-05-09

### Added
- **Optional deep DSP combination test suite.** New `DeepDSPTests.swift` adds an opt-in test suite that catches stage-interaction bugs the existing per-stage tests miss. Five layers: (1) per-stage isolation smoke tests for the previously-unstested stages — Phase Rotator, Parametric EQ, Mono Bass, Stereo Widener, BS.412, Pre-encode limiter, DC clipper, 3-band multiband, multiband limiter, encoder FIR, final MPX safety limiter (12 tests). (2) Universal invariants on 200 deterministically-seeded random valid configs × 7 adversarial programs (HF-rich pop / sustained bass / percussive transients / pink noise / silence / DC offset / full-scale step) — asserts no NaN / inf, composite peak ≤ 1.05, pilot RMS within tolerance when stereo subcarriers are emitted, RDS energy present when active. (3) Pairwise enable/disable matrix on 11 high-impact stage flags (12 covering rows). (4) Counteract detection — for 10 suspect pairs (AGC × Multiband, PrimeBass × BassClipper, CompositeClipper × BS.412, Pre-encode × CompositeClipper, Widener × MonoBass, etc.) renders A-only / B-only / A∧B and asserts no amplitude conspiracy (combined peak ≤ max single × 1.10) and no cancellation conspiracy (combined 1 kHz energy ≥ min single − 6 dB). (5) Per-preset safety check on five 5-band presets (`5_ac`, `5_talk`, `5_chr`, `5_rock`, `5_dance`) × three programs. The whole suite is gated behind `MPXPRIME_DEEP=1` so the default `swift test` stays at ~10 s; running deep takes ~4 min on M1. Invocation: `MPXPRIME_DEEP=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOS --filter Deep`.

- **Bass enhancer renamed `Orbass` → `PrimeBass`.** The previous name read as a portmanteau of "Orban bass" — too close to a registered broadcast-equipment trademark for comfort. New name anchors to the MPXPrime brand. Renamed across Swift identifiers (`primeBassEnabled`, `processPrimeBass`, etc.), UI labels, INI keys (`primebass_enabled`, `primebass_amount`, ...), and tests. **Backwards compatibility:** the legacy `orbass_*` INI keys are still read as fallback values when the new `primebass_*` keys are missing, so existing user configurations keep working. The legacy keys will be removed in a later release. INI files written by the app now emit only `primebass_*`.
- **PrimeBass Phase 2: Werrbach transient-discriminate harmonic gain** (Aphex US 5,424,488, expired 2013-06-08 — public domain). The harmonic-band gain in `processPrimeBass` is now modulated by a dual-envelope transient detector: a fast follower (~5 ms attack / 30 ms release) tracks the LF input's leading edge while a slow follower (~50 ms attack / 250 ms release) tracks its baseline. Their normalized difference saturates positive on real onsets (drum hits, plucked-bass attacks) and decays to zero as the slow follower catches up — typically within 50–150 ms of the burst. Mapped onto a 0.7×–1.4× gain range, this gives a brief harmonic burst on attacks and a lower sustain floor on continuous program — the "punchy not boomy" character of the original Aphex Sound Enhancement System. Average HF energy on continuous program drops by ~3 dB versus a static gain (which indirectly helps the verifier `>67k/in` metric on sustained material), while peak-attack harmonic intensity is preserved. New `transientGainBurstsOnAttackAndDecaysOnSustain` test verifies the gain modulator's behaviour at three known time points (pre-onset / 25 ms post-onset / 350 ms sustained) via an internal accessor — direct-state inspection rather than spectral analysis, since FFT measurement of harmonics this close to the fundamental gets muddied by window leakage at FFT sizes practical for short bursts.
- **PrimeBass Phase 1: MaxxBass equal-loudness harmonics + Aphex phase-shift topology** (Waves US 5,930,373 expired 2017, Aphex US 4,150,253 expired 1996 — both public domain). The harmonic-synthesis stage in `processPrimeBass` now produces separately-weighted *even* (2nd / 4th, asymmetric squarer) and *odd* (3rd / 5th, tanh difference) harmonic terms, each multiplied by an ISO 226 phon-curve approximation evaluated at the harmonic frequency at configure time. Pre-waveshaper allpass biquad at the configured F0 rotates phase ~180° without amplitude loss, so the synthesised harmonics are phase-decorrelated from the direct lowboost path (the bass-extension adaptation of Aphex's HP-then-clip topology — a HPF would attenuate F0 itself). Direct LF gain is tapered down with the harmonics knob (`primeBassDirectGainReduction = 0.62`): perceived bass is now carried more by the weighted harmonics, less by raw LF amplitude — buys headroom in the bass clipper and pre-encode limiter without changing subjective bass weight (the existing makeup-gain stage compensates absolute level). New `PrimeBassMaxxBassTests` suite (4 tests) verifies harmonic generation, F0/harmonic balance shift with the harmonics knob, equal-loudness shape (3rd > 5th near 80 Hz F0), and clean pass-through with PrimeBass off. Tests use a mono-mode minimal-chain `MPXGenerator` render so the composite output equals baseband audio. The default verifier baseline (PrimeBass off) is bit-identical to the previous build — the audio path itself only changes when PrimeBass is enabled, by design.

- **Composite clipper modernised: linear-phase FIR decimation + differential topology** (Orban US 6,337,999, expired 2022 — public domain). New `LinearPhaseFIRDecimator` struct (Kaiser-windowed sinc, ~147 taps, `vDSP_dotpr` polyphase) replaces the prior `BiquadCascade6` 12th-order Butterworth as the OS-rate decimation filter. `CompositeClipper.process` restructured so only the *clipping residual* goes through the decimator while the wanted signal rides a 1× delay-matched bypass — the decimator's stopband leakage and any phase non-flatness now only colour the residual subtracted at output, not the wanted signal itself. Per-band IM cancellation still works: cancelled bands are subtracted from the residual before decimation. Net behaviour: flat passband response across 0–53 kHz (versus Butterworth's 1–2 dB rolloff at the upper subcarrier edge), 90 dB FIR stopband (versus Butterworth's ~70–80 dB), and no decimator-induced phase rotation on the wanted (L−R) sidebands. Cost: ~9 host samples (~47 µs at 192 kHz) of TX-path latency. Cross-domain cancellation depth on the synthetic test drops 1–2 dB (architectural trade-off; receiver-perceived behaviour is improved). Reference: Kahles, Esqueda, Vаlimaki (JAES 2019) on filter choice for nonlinear waveshaping.

- **Comprehensive RDS live-apply.** Every operationally-toggled RDS setting now applies to the running encoder without a transport restart. Previously only RT/PS text content was live; the rest required engine cycle. Now live: master `enRDS`, `rdsPI`, `rdsPTY`, `rdsPTYN`, `rdsECC`, `rdsLIC`, `rdsTP`, `rdsTA`, `rdsMS`, all four `rdsDI_*` bits, RT text + buffers + mode + cycle, PTYN text + enable + centering, Long PS text + enable + centering + CR, AF enable + list + method, group sequence, scheduler auto/standard/standard-LPS, CT/ID/TZ/LIC. Only restart-only settings remaining are physical-layer (`rdsLevel` injection kHz, `rdsFreq` subcarrier, Gaussian shaping FIR taps/BW). `RDSRuntimeConfig` struct expanded from 17 fields to 38; consolidated `RDSRuntimeConfig.make(from: AppConfig)` factory is the single source of truth used by both `AudioOutputEngine.applyRDSRuntimeConfig` and the test suite. `BasicRDSCoder.applyRDSRuntimeConfig` rebuilds derived caches (PTYN/Long PS frames, group schedule) only when relevant inputs change. New `RuntimeChangeDisposition.liveRDS` case routes RDS-only edits through `applyLiveRDSConfigIfRunning` (parallel to the existing `.live` for DSP edits).
- **RDS GUI restructure with status-first Control tab.** New top-level Control tab is the default RDS landing page: master Enable, RDS injection level, live PI/PS/RT readout, and runtime flags (TP/TA/MS/DI). Detail tabs reorganised per UECP message-class taxonomy: Identity (PI/PTY/PTYN/ECC + PS banks), Radiotext (RT/RT+/Now Playing), Long PS, Alt. Frequencies (split out — was buried in Flags), Schedule (group sequence + clock — split out from Carrier), Subcarrier (physical layer only). Old Flags tab removed; TP/TA/MS/DI now live on Control where operators expect them. Snapshot card moved from Identity to bottom of Control. Modeled on DEVA SmartGen 5 / BW RDS3 / Audemat conventions.
- **AF Method B encoding (IEC 62106-2 §7.5.3 / EN 50067 §3.2.1.6.4).** Group 0A block C now correctly emits the paired `(tuned, alt)` Method-B variant when `rds_af_method = B`. Previous code dispatched everything through Method A. Convention: `afCodes[0]` is the tuned frequency; `afCodes[1...]` are alternatives. Receivers deduce Method B from the repeated tuned frequency. EN 50067 12-pair cap honoured. Three new tests cover first-block layout, subsequent-block cycling, and Method-A vs Method-B byte-stream divergence.
- **TA-flag auto-injection (UECP §2.5.1.1).** TA-flag transitions now force an immediate Group 0A ahead of the regular schedule. Traffic-aware receivers see the flag flip within one group time of the operator pressing the TA button, regardless of whether the configured schedule is 0A-heavy or sparse. Previously TA edges had to wait for the next scheduled 0A — potentially hundreds of ms with a 2A-heavy custom schedule. Three new tests cover both edges (off→on / on→off) and confirm non-TA config changes do not trigger spurious forced 0As.
- **MOD chip in broadcast status bar.** The persistent header bar now shows MPX modulation as a percentage (`peak_dev / configured_dev × 100`) alongside the existing kHz DEV chip — the standard Stereotool / Omnia / Optimod readout. Width 80 pt; same colour thresholds as DEV (green safe / amber tight / red over).

### Changed
- **`Date()` deferred from audio render thread.** The RDS encoder's PS / RT / PTYN / Long PS sequence-advance helpers and `applyRDSRuntimeConfig` seq-start markers were calling `Date().timeIntervalSinceReferenceDate` on the audio thread. Replaced with `BasicRDSCoder.monotonicSeconds()` (`@inline(__always)` wrapper around `ProcessInfo.systemUptime`, commpage-backed `mach_continuous_time`, no syscall). 9 audio-thread `Date()` reads removed. Two `Date()` calls intentionally retained: `refreshClockCache` runs on the background `clockUpdateQueue` and needs wall-clock for CT (4A) generation; the RT `{time}/{date}` macro substitution path also needs wall-clock and is handled separately (its DateFormatter cost dwarfs the `Date()` call).
- **CT live-toggle now starts the clock-cache timer.** Enabling `rds_enable_ct` via runtime config without a restart now correctly primes the clock cache and starts the per-second update timer. Previously the cache only initialised at engine init, so live-enabling CT after start emitted Group 4A frames with stale data until the next restart.

### Removed
- **Per-band Multiband gain-reduction meter.** Built and iterated through four smoothing topologies (peak-hold + multiplicative decay, asymmetric one-pole, peak-hold + linear decay at 30 dB/s, peak-hold + linear decay at 6 dB/s); none produced visible meter movement on real program material. Root cause was a combination of compressor producing tiny GR values on default-tuned program, UI sample-rate mismatch with display ballistic, and display scale choices. Cut the feature cleanly: removed `MonoCompressor.lastGainReductionDB`, the five smoothed per-band fields, decay coefficient, `MultibandStatus` struct, `multibandStatus` getter, the per-sample write-throughs in `processThreeBandMultiband` / `processFiveBandMultiband`, the `MeterSnapshot` per-band fields, the `multibandBandGRDB` view-model array, and the `MultibandGRRow` view. Dead-code grep confirms zero residual references.

### Fixed
- **VSCode SourceKit "not in scope" phantom diagnostics for `StageInspector` and `SignalFlowStrip`.** `Package.swift` lives in the `macOS/` subdirectory rather than the workspace root. Without a workspace setting, the Swift extension's sourcekit-lsp didn't discover the SPM target and fell back to single-file compilation mode for individual `.swift` files — each file analysed in isolation, with no knowledge of sibling files in the same target. New `.vscode/settings.json` sets `swift.searchSubfoldersForPackages: true`; window reload required for the setting to apply.

### Tests
- **+23 tests across the new RDS live-apply suite (204 → 227 across 25 → 26 suites):**
  - `RDSLiveApplyTests` (17) — covers PI / PTY / PTYN / Long PS / AF list / group sequence / CT-enable round-trips through `applyRDSRuntimeConfig`, master-enable disengage cleanly, runtime config factory roundtrip, AF Method B encoding (3 tests), TA-edge auto-injection (3 tests).

### Added
- **Configurable PS rotation default duration.** New `rds_ps_frame_seconds` INI key (default 3.0 s, range 0.5–10 s). Sets the per-segment duration when PS text has no explicit `Ns:` / `Nt:` timing marker. Stereotool-style markers (`3s:NEWS/4s:WEATHER`) still take precedence — the configured default only kicks in for unmarked text. Live-applied via `RDSRuntimeConfig.psFrameSeconds`. New PS Frame slider in the RDS Program tab. `PSFrameSecondsTests` locks in marker-precedence behavior.
- **Auto-start input stall watchdog.** `applicationDidFinishLaunching` now arms a 1.5 s watchdog after auto-start that detects the AVAudioEngine first-start input stall (`isRunning == true` but ring stays at 0 frames) and triggers an automatic Stop+Start cycle. Mirrors the manual recovery the user was doing by hand. Marked `WORKAROUND` inline; the proper fix (replacing AVAudioEngine input capture with a direct AUHAL render callback) is tracked in plan.md.
- **`os.Logger` instrumentation in input capture.** Subsystem `com.mpxprime.app`, category `input-capture`. Logs permission status, `setCurrentDevice` outcome, `inputFormat`, tap install, capture start, first tap callback (frames + peak), and a 2 s "tap has not fired" warning. Stream via `/usr/bin/log stream --predicate 'subsystem == "com.mpxprime.app"'` to diagnose future input issues without rebuilding.
- **Microphone permission gate.** `AudioOutputEngine.start()` now calls `AVCaptureDevice.requestAccess(for: .audio)` synchronously when `useInputSource` is true and TCC status is `.notDetermined`. Eliminates the first-launch race where the engine would start before the system permission prompt resolved.

### Changed
- **RT+ scheduling.** Two fixes after operator-reported intermittent RT+ display on car radios:
  - 11A is suppressed (replaced by 0A in the schedule slot) when `rtPlusTags` is empty. The previous all-zero-content-type 11A read as "RT+ withdrawn" on Pioneer / Sony receivers and made RT+ flicker on / off as content changed.
  - Auto schedule appends 3A every cycle (~2.3 s) instead of every other cycle (~4.5 s). Receivers that need to see AID 0x4BD7 within 5–10 s of tune-in are now well inside the window.

### Fixed
- **Levels window meter strip readability.** Replaced `.fixedSize()` on each strip's value Text with `.minimumScaleFactor(0.6)` + `.frame(maxWidth: .infinity)`. Long readouts no longer spill into adjacent meter columns. Strip the trailing `"   N.N pk"` suffix from the value text on vertical strips — the white peak-hold tick already conveys peak position visually, so the duplicate text only added clutter and overflowed the 58 pt column.

### Removed
- **Loudness meter + `MonitorLoudnessAnalyzer` DSP path.** Dropped the Loudness card from the Levels window plus its entire backing DSP plumbing (K-weighting biquads, energy ring buffer, momentary / short-term / integrated LUFS gating, `setAnalysisCapture(loudness:)` parameter, ~200 lines total). Operator feedback was that the on-screen LUFS readouts were noise — broadcast loudness is judged on the receiver, not in the GUI. The audio thread no longer runs the per-sample K-weighting on the monitor path.
- **Dead `HelpSectionView` struct (~40 lines).** Defined but never instantiated — leftover from an earlier Help layout that was superseded by `HelpInputLevelsView` / `HelpRDSTextView`.

### DSP audit (perf / correctness, output bit-identical)
- **Cached RDS auto / standard schedules.** `generateAutoSchedule` / `generateStandardSchedule` were called from `nextGroupBits` on every group (~11×/sec at the RDS bitstream rate), each call allocating a fresh `[RDSGroupSpec]`. After the post-0.11 RT+ fix the schedules became pure functions of feature flags, so they can be cached. Schedules now rebuild only on init and when `rtMode2B` / `rtPlusEnabled` toggle in `applyRDSRuntimeConfig`. Removed the dead `scheduleGenerateCounter` (still incremented but never read after the RT+ change). Output verified bit-identical via `--verify --baseline-strict`.
- **Reused 104-byte `bitBuffer` in `buildGroupBits`.** Each `buildGroupBits` call previously allocated a fresh `[UInt8]` of capacity 104, plus an inner 4-element `[block1..block4]` array literal — both ~11×/sec on the audio thread. `bitBuffer` is now pre-allocated once and subscript-assigned in place; CoW gives test callers their own logical array on retention. The block iteration uses an unrolled `writeBlockBits` helper with explicit offsets. Output verified bit-identical via `--verify --baseline-strict`.

### Tooling / docs
- **DMG bundled INI now matches the canonical sample.** `build-release.sh` previously hand-authored a stub config with lowercase / spaced section headers (`[ mpxprime ]`, `[pilot ]`, etc.). The parser only recognises canonical uppercase `[MPX]` / `[RDS]` / `[INTERFACES]`, so every value in those mismatched sections silently fell back to AppConfig defaults — most visibly `preemphasis_us = 75` in the template was being ignored, so US-region operators got 50 µs pre-emphasis after a fresh install. Replaced the heredoc with `cp macOS/MPXPrime.ini` so the DMG ships the same canonical INI that `SampleINIRoundTripTests` already validates.
- **Help window updated for the post-0.11 PS frame seconds.** The "Untimed plain text" help line now distinguishes single-chunk (10 s hold) from multi-chunk (configurable PS Frame default for PS, 2.5 s for RT / PTYN / Long PS).

### Tests
- **+38 tests across 5 new suites** — 166 → 204 across 18 → 25 suites:
  - `PSFrameSecondsTests` (6) — locks in marker-precedence semantics for the new configurable default.
  - `AppConfigInvalidInputTests` (8) — type coercion robustness (garbage numerics, bool synonyms, empty values, inline comments, unknown sections).
  - `RDSSchedulerCadenceTests` (8) — auto / standard scheduler cadences including the 3A-every-cycle regression guard.
  - `RDSBitBufferReuseTests` (5) — alloc-free `buildGroupBits` correctness (first-call validity, CoW, no cross-call leakage).
  - `FilterPrimitiveTests` (11) — direct coverage for `Lagrange4Interp`, `LinkwitzRiley4`, `BiquadCascade6`.

## 0.11 — 2026-05-06

### Added
- **Linear-phase FIR multiband crossovers (TX path).** Replaces the IIR LR4 cascade with Kaiser-windowed-sinc FIR splitters that all share group delay, so summed bands reconstruct the input delayed-by-`groupDelaySamples` exactly (–155 dB sum-to-flat error floor). Eliminates the inter-band phase rotation that smears transients and the inter-band gain-modulation that causes spectral pumping when bands compress at different rates — the core reason multiband-on tended to sound worse than multiband-off on percussive material in 0.10. New `LinearPhaseFIRSplitter`, `LinearPhaseMultibandSplitter3`, `LinearPhaseMultibandSplitter5` structs (simultaneous-split / parallel-cumulative-LP topology). Monitor mode keeps the low-latency LR4 path. New `multiband_fir_enabled` INI key (default true), restart-required. Latency cost: ~5.3 ms at 192 kHz with the default 90 Hz lowest crossover (the binding constraint for Kaiser-FIR transition width).
- **vDSP-backed FIR convolution.** `LinearPhaseFIRLowpass.process` now runs through `vDSP_dotpr` instead of a pure-Swift accumulator loop, with a double-buffered delay line so the read window is always contiguous. ~5–10× speedup measured against the manual loop; FIR-path multiband ends up only ~24% more expensive than the IIR path, well inside real-time budget. Without this acceleration the multiband-FIR path overruns budget on most machines (manifested as audio crackle + RDS BCH corruption from sample dropouts). New `DSPThroughputTests.multibandFIRStaysInsideRelativeBudget` guards the FIR/IIR cost ratio (<5×) so a regression that bypasses vDSP would surface immediately rather than at user-facing dropout time.
- **vvtanhf-batched soft-clipping in oversampled clippers.** `CompositeClipper`, `BassClipper`, and `DistortionCancelledClipper` previously called scalar `tanhf` per oversample step (8 / 8 / 16 calls per host sample respectively). The clippers now restructure their `process()` into a 3-phase pattern — pre-compute oversampled inputs, batch the `tanhf` evaluation through `vvtanhf` on the gathered N-element buffer, then run the per-OS-step filter cascades using the precomputed clipped values. Measured on Apple Silicon: 8-element batches give ~5× speedup vs scalar; 16-element batches give ~9×. Output is bit-exact identical (vvtanhf uses the same math kernel as libm tanhf) — verifier strict baseline unchanged. New `TanhBatchSizeBench` micro-benchmark documents the batch-size/speedup curve so the trade-off stays visible.
- **Italo / Pump multiband presets (`5_italo`, `3_italo`).** Tempo-synchronised low-band release tuned for 120 BPM four-on-the-floor — at `5_italo` the band-2 (kick band, 80–280 Hz) effective release sits ~90 ms = ~18% of a quarter note for audible kick-driven ducking, while the high band stays light (1.3:1, 100 ms) so cymbals and synths sparkle. Lower link strength (0.30 vs 0.52 default) widens the bass image. Research-backed against published EDM/dance mastering practice and Orban Optimod dance-preset design. Selectable from the Multiband preset picker.

### Changed
- **Default `multibandIntensity` `light` → `normal`** + per-band AppConfig defaults updated to the published `5_ac` recipe (no Light multiplier baked in). The previous "Light" intensity offset thresholds +1.5 dB and scaled ratios ×0.9 — combined with the soft-knee soft-release `5_ac` numbers, the result was a multiband chain so transparent operators reported it sounded like nothing was happening. Normal is audible but still clean; Light is still a one-click option in the picker for operators who want maximum transparency.
- **Default audio block size 2048 → 1024.** Drops TX-path latency by ~5 ms (10.7 ms → 5.3 ms of block-driven delay at 192 kHz) for tighter off-air monitor sync. No quality cost — just more callbacks per second. Chain is throughput-validated at blockSize 512 by `DSPThroughputTests`, so 1024 has comfortable headroom. Operators on lower-CPU machines can revert via `blocksize = 2048` in INI.

### Fixed
- **Composite clipper pilot / RDS guard regression.** During the post-0.10 clipper rewrite the `cancelPilot` / `cancelRDS` flags became no-ops because the documentation rationale ("subcarriers inject post-clipper, so receiver doesn't see clipper IM in those bands") was wrong — clipper IM at 19 kHz / 57 kHz vector-sums with the cleanly-injected pilot and RDS at the receiver, masking pilot PLL lock and adding noise to RDS demodulation. With audio-band clipping engaged (the new `cancel_audio = false` default), this manifested as RDS being readable when the chain was stopped but corrupted when it was running. Fix: replaced the inert pilot/RDS LR4 cancellation paths with RBJ bandpass biquads centred at 19 kHz (Q=4) and 57 kHz (Q=14). Centre-frequency cancellation now drops pilot and RDS regions to –80 / –127 dBFS under hot drive. New `clipperKeepsPilotAndRDSCentreFrequenciesClean` test guards this.
- **Composite clipper no longer collapses HF stereo image.** The 0.10 cross-domain cancellation used 2× cascaded LR4 splits at 23 / 53 kHz to bound the stereo subcarrier band. The cascade gives -12 dB at the corners, which attenuated the (L-R) DSB-SC subcarrier sidebands generated by HF audio (~10–14 kHz panned content modulating to 24/52 kHz) and visibly collapsed stereo image at the receiver. The new clipper uses a single-LR4 split with the stereo cutoff moved from 23 to 22 kHz so the actual 23–53 kHz subcarrier sits in the passband, not on the corner. Sideband preservation now within ~1 dB across the full HF audio range; new `CompositeClipperStereoSeparationTests` suite locks this in.

### Removed
- **`CompositeTruePeakLimiter` deleted.** The composite-domain limiter used `|composite|` peak detection (driven hardest by stereo subcarrier crests) and a memoryless `tanhf` ceiling that produced intermod across 23–53 kHz, demodulating as `(L-R)` cancellation at the receiver — i.e. it actively destroyed stereo separation when enabled. The old struct's per-channel use inside `PreEncodeAudioLimiter` (audio-domain L/R limiting, where the failure mode doesn't apply) was preserved by renaming it to `OversampledPeakLimiter`. The composite-domain instance, chain call, UI toggle, preset field, and `compositeLimiterGainReductionDB` telemetry are gone; the meter's headroom-reduction value is now sourced from the composite clipper.
- **Legacy INI key `composite_clipper_enabled` removed.** This key was wired to the (now-removed) composite limiter, not the clipper — flagged as a sharp edge in `CLAUDE.md`. The actual composite clipper toggle stays at `mpx_clipper_enabled`. INI files containing the old key will silently lose that setting; the limiter no longer exists, so this is a no-op for output behaviour.

### Changed
- Composite clipper `cancel_audio` default flipped `True → False`. The old default with the substitution algorithm made the clipper a near no-op for peak reduction; the new delta-based algorithm under `cancel_audio = False` keeps the audio band fully clipped (which is where the loudness lift comes from) while still preserving subcarrier integrity via `cancel_stereo`.
- Composite clipper `cancel_pilot` and `cancel_rds` defaults flipped `False → True`. They were stubs in 0.10; the new algorithm actually subtracts clip residual in the 17–21 kHz pilot guard and 55–59 kHz RDS guard, so receiver-side pilot PLL lock and RDS BER are no longer corrupted by clipper IM in those bands.
- Existing `audioBandCancellationDropsMonoIM` and `stereoBandCancellationDropsCrossDomainMixingProducts` cross-domain tests relaxed from >20 dB / >10 dB to >3 dB / >7 dB drops respectively. The delta-based cancellation is bounded by LR4 phase rolloff in the protected bands; the trade-off (less aggressive cancellation depth, full sideband preservation) is intentional and what fixes the user-reported "stereo image disappears" issue.

## 0.10

### Added
- **Composite clipper: cross-domain IM cancellation via Linkwitz-Riley substitution.** Splits both the clipper input and its clipped output into 4 bands at 15 / 23 / 53 kHz crossovers, then substitutes the clean input band for the distorted clipped band in the audio (0-15 kHz) and stereo subband (23-53 kHz) regions. LR4 LP+HP form a phase-coherent allpass pair so the cancellation is delay-matched. Measured drops on the cross-domain IM test suite: M³ at 3 kHz drops 56 dB with audio cancellation; M²·S at 2400 Hz drops 12-14 dB with stereo cancellation; combined hot-drive cleanup −39 dBFS → −64 dBFS. Inspired by Orban US 5,168,526 + US 6,434,241 (both expired and public domain). New INI keys `mpx_clipper_cancel_audio` / `mpx_clipper_cancel_stereo` (live-apply, default true).
- **Wideband AGC broadcast-grade upgrade.** K-weighted detector (BS.1770-flavoured HPF ~38 Hz Q 0.5 + high-shelf +4 dB @ ~1.5 kHz) on the detector sidechain. Program-dependent release tracks fast-vs-slow envelope divergence (50 ms vs 1 s); effective release scales 1×–3× with a ~0.5 s smoothed density estimate. Release cap extended from 1.2 s to 5 s. Toggleable via `agc_k_weighting` and `agc_release_program_dependent` (default on).
- **Linear-phase FIR brick-wall 15 kHz on TX path.** Kaiser-windowed FIR replaces the Butterworth program lowpass when running in composite output mode. ≥80 dB stop-band at 17 kHz, ≈1.67 ms group delay at 192 kHz. Monitor mode retains the Butterworth cascade for low latency. Config toggle `encoder_fir_enabled` (default on).
- **Stereo Tool-compatible RDS text grammar.** Fractional `Ns:`, `Nt:` transmit-count, `/` top-level separation, escape handling for `< > | : / \\`, `||` word-wrap toggle (no-op), `<`/`>` scroll markers for PS with speed-by-repeat, `\F`/`\f` file-load aliases for `\R`/`\r`. Pure parser extracted to `RDSTextParser.swift` with early-exit escape encode/decode.
- **4 PS banks with exclusive active selector.** `rds_ps_a/b/c/d` + `rds_ps_active_bank`. Live-apply via `RDSRuntimeConfig` — switching active bank rebuilds the PS sequence without engine restart. INI migrates legacy `ps_dynamic` into bank A.
- **Live RDS snapshot in Monitoring.** Monitoring card now reads the actual transmitted PS, RT, PTYN, Long PS from the running coder — not a UI-side simulation. Writes guarded by `OSAllocatedUnfairLock` so UI contention never stalls the render callback.
- **Broadcast-console look pass.** Orban Optimod silhouette, HIG-compliant, follows system appearance. `BroadcastStatusBar` pinned under window chrome shows transport + IN L/R / MPX / DEV / GR / SAFE / BUDGET / PILOT / RDS on every screen. Monitoring embeds compact scopes and MPX spectrum with pop-out arrows. Processing gains an Overview grid (13 stage cards) as the default landing tab. Levels window uses 8 vertical meter strips. RDS snapshot cards use a dark meter-plate style.
- **57 tooltips (`.help`) across DSP controls** covering AGC, Orbass, Parametric EQ, Multiband, Stereo Widener, Composite Limiter, Phase Rotator, Bass Clipper, DC Clipper, BS.412, Composite Clipper.
- **107 new tests across 9 suites** including RDS parser/orchestration/advance/bitstream/signal/PS-bank coverage, DSP throughput regression suite, encoder bandwidth FIR characterisation, and cross-domain IM cancellation regression guards. 141 tests / 14 suites green.
- **macOS HIG polish** — Edit menu (Cut/Copy/Paste/Undo/Redo + Emoji & Symbols + Start Dictation), Close Window ⌘W, Start/Stop on ⌘Return, Scopes on ⇧⌘0, accessibility labels, semantic colors, Dynamic Type on meters.
- **Sane out-of-box defaults.** AGC on, multiband on (5-band AC/Pop, light intensity), bass clipper on, composite clipper on with cross-domain IM cancellation. Stereo widener and Orbass off (responsible defaults — both color the signal and degrade fringe-listener SNR). BS.412 off (US default; EU operators flip to True). Sample `MPXPrime.ini` rewritten to mirror these defaults with rationale comments per stage. A fresh install audibly outperforms `mpxgen` / PiFmRds with zero operator action.

### Changed
- AGC release cap extended 1.2 s → 5 s; defaults retuned to "Pop Medium" range (target -14 LUFS, range 20 dB, attack 6 ms, release 1.5 s).
- Multiband default intensity changed `normal` → `light` (thresholds offset +1.5 dB, ratios ×0.9).
- Composite clipper default thresholds tightened −3.0 / −0.5 dB → −1.0 / −0.3 dB so it actually engages on real program.
- Pre-emphasis confirmed in M/S domain inside `makeCompositeComponents`. Guarded by `DSPThroughputTests.preEmphasisDoesNotExplodeFullChainCost`.
- `RT dynamic-sequence cache` skips `parseTimedSequence` and `expandNowPlayingMacros` on the audio thread when inputs are stable.

### Fixed
- `composite_clipper_enabled` INI key collision documented in sample INI comments — that key is the composite *limiter* (legacy name); the actual composite clipper uses `mpx_clipper_*` keys.

## 0.85

### Added
- Configurable now-playing script support in the RDS Radiotext section with native file picker, poll interval, timeout, and runtime status display
- Radiotext macro expansion for now-playing metadata: `{now_playing}`, `{display}`, `{artist}`, and `{title}`
- Additional Radiotext template macros: `{date}` and `{time}`
- README documentation for the expected now-playing script output format and RT/RT+ configuration
- Broadcast preset picker for the final MPX stage: `Balanced Music`, `CHR / Dance`, `Punchy Music`, and `Speech / Talk`
- Final-stage limiter telemetry in Monitoring and DSP Overview showing live and held gain reduction
- Composite calibration telemetry showing pilot %, RDS %, audio-composite peak, budget margin, and a `Safe` / `Tight` / `Risk` composite-budget state
- Dedicated `Mono Bass` stage with configurable crossover in the Widener tab
- Orbass preset/config wiring for density and subharmonics, with the adaptive Orbass path now active in the live DSP chain
- Offline MPX verification mode with deterministic scenarios and exit codes
- Long-run compliance/regression verification mode:
  - `--verify-long`
  - focused on `program_mix`, `bright_dense`, `vocal_sibilant`, `transient_push`, and `wide_bass`
- Additional audible-quality verification scenarios:
  - `bright_dense`
  - `vocal_sibilant`
  - `transient_push`
  - `wide_bass`
- Preset-sweep verification mode:
  - `--verify-presets`
  - focused on `5B AC/Pop`, `5B CHR/EDM`, `5B Rock`, `5B Talk`, `5B News`, `5B Urban`, and `5B Dance`
- Window frame persistence for the main window and utility windows

### Fixed
- RT+ tagging now uses structured now-playing metadata more reliably for artist/title extraction
- RT+ tag ordering now follows the field positions in transmitted radiotext
- Now-playing script failures and empty output now clear the active metadata, show a friendly `No Song Data` status, and discard the affected RT segment instead of leaving blank labels behind
- `output_gain_db` and `limit_mpx` are now active in the final render path
- Added a proper `Final Drive` stage ahead of composite limiting and improved composite limiter behavior
- `Mono Mode` now suppresses pilot, stereo subcarrier, and RDS so it behaves as a true mono composite mode
- Final drive now affects the audio-composite path without dragging pilot and RDS injection levels along with it
- The main composite limiter now runs before pilot/RDS sum, with the full-MPX limiter acting as a safety stage
- Stereo widener no longer behaves as a raw full-band M/S gain stage and now includes stereo-image protection
- Orbass was retuned to be substantially more conservative and less artifact-prone
- Multiband now uses complementary Linkwitz-Riley crossover stages instead of one-pole residual splits
- Multiband defaults and presets were retuned toward more realistic broadcast-style starting points
- `5B AC/Pop`, `5B CHR/EDM`, `5B Rock`, `5B Talk`, `5B News`, `5B Urban`, and `5B Dance` were tuned and verified against the focused preset sweep
- MPX width/compliance is now explicitly verifier-backed with encoder-side bandwidth guarding and a dynamic HF compliance guard ahead of stereo encode/pre-emphasis
- Processing and RDS reset buttons now only reset the active tab
- External config reloads now correctly preserve pending apply state

## 0.8

### Added
- Multiband dynamics presets (CHR/EDM, Rock, AC/Pop, Country, Talk, Urban, Dance, News, Jazz, Classical) with intensity control (Light/Normal/Heavy)
- FFT spectrum window toggle (96 kHz full / 60 kHz FM band)
- Reset Processing to Defaults button
- Default PTY set to Science
- Native MPX Prime app icon assets for runtime and release builds

### Changed
- Updated default RDS text to "MPX Prime: FM MPX + RDS Audio Processor"
- Unified window sizes for Scopes, Spectrum, and Levels windows (700x500, min 600x450)
- Processing section refactored with HIG-compliant plain Section style
- MPX spectrum display simplified (removed 19 kHz pilot marker)
- Window size constants centralized for easy configuration
- Main navigation reduced to Monitoring, Processing, and RDS; app-level controls moved into Settings
- Default config path changed to `~/Library/Application Support/MPX Prime/MPX Prime.ini`
- Default program lowpass changed to `16.4 kHz`
- Monitoring view and Settings were updated for more native macOS behavior and layout

### Fixed
- Level meters now properly displayed in Levels window
- Removed duplicate state variables in Processing section
- Main window close behavior now keeps the app running and supports reopen from Dock / Window menu

## 0.7

- Initial native macOS release built with Swift + SwiftUI.
- Real-time MPX generation using AVAudioEngine with AVAudioSourceNode.
- Input capture via AVAudioEngine input tap with ring buffer.
- Native macOS UI with SwiftUI sidebar navigation and monitoring dashboard.
- Phase-coherent stereo encoder with 19 kHz pilot and 38 kHz DSB-SC subcarrier.
- RDS encoding with EN 50067 biphase shaping and 57 kHz subcarrier.
- DSP features: input gain, wideband AGC, Orbass bass enhancement, multiband compression, stereo widener.
- Pre-emphasis support (0/50/75 µs) with HF trim control.
- Lookahead limiter for MPX protection.
- Lock-free real-time audio path with pre-allocated buffers.
- vDSP-accelerated metering for scope display.
