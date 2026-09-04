# MPX Prime Meter -- post-audit plan (0.45+)

## Context

The 2026-08-31 three-way Meter audit (measurement engine / input+SDR+recording /
GUI, 57 findings) and the RTL-SDR bench run that followed it are both closed on
`develop/v.045`: every P0-P3 finding shipped across seven commits
(c120c83 .. fafc7db), the stdin/file back-pressure defect the bench exposed is
fixed (1021b11), and the narrow-IQ default the audit argued for was reverted
after the bench A/B refuted it (c6ba9a8). This file is the plan for what the
audit and the bench left OPEN. History and full finding detail stay in
`plan.md` ("Meter audit (2026-08-31)"); this file is the actionable remainder.

## Code review of the shipped fixes (2026-08-31, this session)

Spot-checked the shipped claims against the tree -- all verified present:

- Validity flags: `peakValid` / `devScaleValid` / `exceedanceValid` /
  `pilotRDSPhaseValid` etc. on the snapshot (`MeterAnalysis.swift:31-76`),
  with `devScaleValid` derived from an actual scale, not a default.
- Tuner drop counters: `mpxtuner_iq_drops()` in the C ABI, counted in BOTH
  backends (`tuner/include/rtl_sdr_device.h:78`,
  `tuner/include/sdrplay_device.h:109`) and folded into the badge via
  `SDRLibraryInputSource.swift:137`.
- De-emphasis setting: `--deemphasis <50|75>` parsed and documented in the
  CLI (`MPXPrimeMeter/main.swift:80,534`); live picker on the GUI input bar.
- Back-pressure: producer-side wait API on `StereoInputRingBuffer.swift:300`
  wired through `MPXInputSource.swift:19`; `StereoInputRingBufferTests` cover it.
- IQ-rate default: reverted to 1000 kHz at `MeterViewModel.swift:165`, with
  the bench measurement recorded at the declaration site (line 151+).
- The underlying tuner channel-filter defect is still present AS INTENDED:
  `fm_demod.cpp` ctor leaves `m_bandwidthMode = 0` unapplied and
  `setBandwidthHz` early-returns on `selected == m_bandwidthMode`
  (`tuner/src/fm_demod.cpp:34,122`). The fix is deliberately deferred -- see A1.

No drift found between plan.md's SHIPPED claims and the code. Nothing below
re-opens a shipped fix.

## Invariants (from the audit -- carry into every item below)

- **A new readout ships with its validity gate, or it does not ship.** Never
  publish a scale-derived kHz figure without `devScaleValid`.
- **Two paths that must agree get a test that proves they agree** (actual vs
  predicted rate, packed vs complex SDR path, CLI vs GUI flag handling).
- **A live value is read only inside the isolation wrapper** -- check WHERE it
  is read, not just that a telemetry object exists (the rfSpan-chip lesson).
- **Measurement-semantics changes need the standard re-checked** (SM.1268-5 /
  BS.412-9 / EN 50067) and a deterministic known-answer test; a gate that
  would also pass without the fix is not a gate.
- All of it headless: `swift test` + replay through
  `MPXPrimeMeter --stdin --full-scale-khz 150 --no-monitor`; the shipped SDR
  capi is only reachable headless via a scratch harness against
  `mpxtuner_open` + the cmake objects (the checked-in `tuner/build-release`
  cache is stale -- use a scratch cmake dir).

## Status update (2026-08-31, implementation session)

Late addition, same day: the instrument-reconciliation work (SM.1268
true-peak vs a hardware monitor's integrating detector; pilot agreement
proved the scales matched while program MAX differed by ~10 kHz) produced
the **monitor-ballistics deviation readout** -- `MonitorDeviationMeter`
(Core, 0.5 ms sliding mean on the measurement path, test-pinned), a
Modulation-card checkbox + `--monitor-dev` CLI flag, validity-gated,
alongside MAX and never feeding any compliance statistic. VERIFIED same
day: 640 tests / 100 suites green (incl. `MonitorDeviationMeterTests` +
`RFOverloadGateTests`), swiftlint 0, `--verify --baseline-strict` zero
drift, tuner tools clean-configure build, and a known-answer CLI smoke
(a 997 Hz tone composite reads MON 29.1 vs the analytic window-mean 28.7
with MAX true at 52.1; flag off leaves the DEV line byte-identical). A
review pass the same evening fixed: the --tone restore reading source_mode
from the wrong INI section, swallowed rtl_sdr/measure failure statuses, the
single-window saturation gate, an unconditional cmake prereq, and RF
OVERLOAD detection moved to PRE-decimation raw samples on the wide paths
(post-decimation was desensitized exactly when capture is wide -- the
factor-1 packed path keeps the demod's raw-byte count).

A3 and the same-IQ half of the B-queue are DONE and their theories settled;
A2 is RESOLVED (root cause was not what the bench note said); the closed-loop
calibration shipped as `calibrate-tx.sh` with the Meter-integrated version
designed below. Tools delivered: `mpx-offline` (tuner CMake, device-free
demod harness -- see tuner/README.md) and `calibrate-tx.sh` (repo root).
The sections below keep the details; superseded text is marked.

## A. Software fixes and decisions (evidence-gated, agent-doable once unblocked)

### A1. Tuner channel filter: make "auto" bandwidth mean something (BLOCKED on B1)

The bench proved that at factor 1 with `bandwidth_khz = 0` nothing band-limits
the IQ ahead of the FM demod, inflating every peak-sensitive reading (+21 kHz
MAX deviation, +46% RDS, +50% noise; phase wandering). Proposed fix, written up
but deliberately NOT applied: call `setBandwidthHz` unconditionally at open
with an explicit FM MPX default (200 kHz) instead of leaving mode 0 unapplied.
Alternative: make the ctor apply its own +/-110 kHz design as a real mode so
"auto" means what it says.

- **Why blocked:** it changes the shipped demod for every user on ONE dongle's
  evidence. Wants a second RTL or an SDRplay cross-check first (B1).
- **Gate when unblocked:** re-run the 3-row A/B table (narrow/auto,
  wide/auto, narrow/200k -- rows 2 and 3 must agree, row 1 must now match
  them), plus an SFP-X comparison. Then revisit whether the narrow default
  question reopens (the byte-exact packed path argument is only valid once
  factor 1 is band-limited).
- Keep the RTL IQ-rate revert (1000 kHz) and the manual-meter.md warning
  until this lands.

### A2. SIGNAL QUALITY scale on an RTL path -- RESOLVED 2026-08-31

The bench premise was wrong: the identical 4.1 kHz "8-bit demod floor" was
**front-end saturation under auto tuner gain**, not a converter limit.
Same-station A/B: an auto-gain capture rails 10-40% of the IQ samples and
reads noise 4.14 kHz / Unusable (reproducing the bench's 4.12 exactly); a
correctly-set manual gain reads 1.15 kHz / Poor on the same dongle, RDS at
0.0% block errors both times.

**Implemented** (per the validity invariant -- surface the state, do not move
thresholds): the demod's saturation detector (raw bytes packed path, shared
amplitude threshold complex path) is exported via `mpxtuner_iq_overload()`,
debounced by `RFOverloadGate` (MPXPrimeCore, `RFOverloadGateTests`: fires
above 0.1% railed, holds 2 s), and shown as an amber **RF OVERLOAD** badge on
the Quality card; the SIGNAL QUALITY grade is withheld while it is up (the
noise figure stays -- it is a real measurement, of the clipping products).
Remaining, folded into B1: the SDRplay comparison run, now only for the
8-bit-vs-14-bit scale-tightness caveat, no longer for a defect.

### A3. Pilot-to-RDS phase dispersion on SDR paths -- DONE 2026-08-31, theory REFUTED

Measured with `mpx-offline` exactly as planned (known-phase synthetic
composite FM-modulated through the shipped demod wiring, plus one recorded
IQ capture replayed to both output rates):

- Injected 0 deg reads 0-1 deg and injected 30 deg reads 29 deg on EVERY
  variant: packed and complex path, bw auto and explicit 200 kHz, 192 and
  256 kHz output, resampler in and bypassed. The digital chain's dispersion
  is at most ~1 deg -- nothing to correct.
- The same recorded capture replayed to 192 and 256 kHz reads the identical
  angle (82 deg both), so the bench's 88-vs-76 deg was capture-to-capture:
  multipath rotates 19 and 57 kHz differently and changes between captures,
  plus possible analog front-end terms. Not the digital chain.

**Decision taken:** no per-chain correction (nothing to correct), no
SDR-specific verdict suppression (the chain is trustworthy; what varies is
the air path, which no input-kind flag can detect). The manual caveat is
rewritten to the true mechanism: expect a few degrees of wander between
off-air measurements on reception alone; the category is robust.
`PilotRDSPhaseMeter` untouched, as required.

### A4. Studio<->Meter closed-loop calibration (script SHIPPED; Meter-integrated version designed)

`calibrate-tx.sh` (repo root) closes the loop today, headless: reads Studio's
configured pilot injection (pilot_level x mpx_deviation_khz) over the REST
API, measures actual off-air pilot deviation through the honest chain
(auto-finds the highest non-railing RTL gain, refuses railed captures,
explicit 200 kHz channel filter via `mpx-offline`), trims `output_gain_db`
until they agree; the pilot is constant-amplitude so program can stay on air.
Attenuation-only respected: an under-deviating transmitter is reported as
"raise the exciter's input sensitivity by N dB" plus a `--watch` mode that
prints a fresh measurement every few seconds while that trimmer is turned.
Validated on air 2026-08-31 (85.8 MHz test rig): repeatability +/-0.06 dB
pass-to-pass, and it caught a real deployment fault on the way (USB output
device UID embeds the port -- a re-plugged exciter feed fell back to the
default output device, composite on the speakers, silence on the carrier).

**Next: the same loop inside MPX Prime Meter** (the "cooler" version, and the
plan's parked C item now that the control API exists -- no export path
needed when the Meter runs the loop itself). Design:

- `CalibrationController` (MPXPrimeCore, pure + test-pinned): given target
  pilot kHz, measured pilot kHz, current output_gain_db -> next gain
  (clamped <= 0), verdict (converged / adjusting / needs-exciter-drive +N dB),
  tolerance and pass limits. All decision logic testable without a GUI.
- `StudioCalibrationClient` (Meter target): URLSession against /api/status,
  /api/config (GET + PATCH), X-API-Key support.
- View model: a calibration task that requires the SDR input running with
  `devScaleValid`, no SAMPLES DROPPED, and `rfOverloadActive` false before it
  trusts a reading (the badges already encode all of it), averages the pilot
  readout over a few seconds per pass, and drives the controller.
- GUI: a "Calibrate Studio..." sheet (URL + API key fields, live log,
  Start/Cancel), HIG-native. Meter has no web dashboard, so no parity leg.
- Blocked this session only by the no-builds-while-on-air rule (the TX was
  live on the bench); first build-capable session can land it.

## B. Hardware validation queue (maintainer; agent prepares harnesses)

1. **Second RTL / SDRplay cross-check of the A1 bandwidth fix** -- unblocks A1
   and feeds A2. Reuse the bench method: scratch cmake build of `mpx-tuner`,
   capture composite, replay via `--stdin`; the capi harness for the shipped
   path already exists as a pattern (~45 lines against `mpxtuner_open`).
2. **Offline factor/path A/B on recorded IQ -- DONE 2026-08-31** with
   `mpx-offline`: one 85 s capture of 105.9 through the packed byte-exact
   path and the unpack->complex path reads IDENTICALLY to display precision
   (B12 settled); same capture with and without the 200 kHz channel filter
   isolates the filter's own effect (RDS +7%, MAX +3%, >77 kHz share 2.7x,
   noise +10%) -- real but modest; the big term in the live bench table was
   auto-gain overload (see A2).
3. **RTL with a known ppm error, before/after the decoder PLL fix** -- field
   confirmation of the measured 24.8 -> 64.4 dB separation improvement.
4. **SFP-X side-by-side re-check post-P1** -- conventions did not change
   (bench confirmed pilot 5.77 / RDS 3.87 on 88.6, consistent with
   2026-07-07), so this should be a formality; do it before quoting 0.45
   numbers against SFP-X.
5. **75 us station check** for the new de-emphasis setting (a real 75 us
   market signal, not synthesized).
6. **VoiceOver pass over the Meter** (the P3 accessibility work is in; the
   audit checklist item is the human pass).
7. **Long SDR + RF-spectrum GUI run with Instruments** -- "View Body" on the
   root should now be 0 Hz (rfSpan chip isolation fix); also re-checks the
   0.34-class leak stays fixed in the one mode it regressed in.
8. **RSPdx wide-capture path** -- still hardware-unverified since 0.43.

## C. Parked / larger items (decision or dependency first)

- **Meter CLI on Linux** -- the tuner C++ is already portable and SDRplay is
  dlopened; needs a target split (the Meter executable is macOS-only today)
  and an ALSA/file input story. Do after the encoder's Linux tier stabilizes.
- **Studio<->Meter closed-loop RF trim** -- the Meter's RF spectrum as the
  sensor for auto-trimming clipper drive against occupied-bandwidth targets.
  The deviation-calibration half of this shipped 2026-08-31 (see A4:
  `calibrate-tx.sh` + the Meter-integrated design); what remains parked here
  is the occupied-bandwidth / clipper-drive loop, which still wants the RF
  spectrum as its sensor.
- **Off-air input conditioning** -- if the Meter ever needs to decode noisy
  off-air composite beyond what the tuner delivers, conditioning goes in the
  METER's input path, never back into the shared `MPXDecoder` (the pre-demod
  notches cost 40+ dB of HF separation once already; see plan.md "Settled
  findings").

## Deliberately NOT doing (do not re-litigate without new evidence)

- Narrow (factor 1) IQ default: refuted by the bench A/B; stays 1000 kHz
  until A1 lands and is re-measured.
- Moving SIGNAL QUALITY thresholds to make RTL readings look better: that is
  relabelling a measurement, not fixing one (A2 decides properly).
- B20 (per-block allocation in the consumer loop): examined -- the only
  remaining allocation is `isolatedSnapshot()`, which must copy to be correct
  and runs ~23/s on a non-realtime thread.
- `[R82XX] PLL not locked!` at open: librtlsdr's own init message (Homebrew's
  `rtl_sdr` prints it too), not our bug.
- Simplifying `PilotRDSPhaseMeter` to reuse `PilotPLL` or giving its two
  paths different filters: the identical-chains design is what cancels the
  capture clock's pilot-frequency offset.
