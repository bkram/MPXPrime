# MPX Prime Meter -- Roadmap and Open Work

## Context

The 2026-08-31 three-way Meter audit (57 findings) and the RTL-SDR bench run
that followed are closed; every finding shipped and the theories the bench
opened were settled by measurement (history and numbers in CHANGELOG). This
file holds only what is still open. Pruned 2026-09-05.

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

## A. Software fixes and decisions (evidence-gated, agent-doable once unblocked)

### A1. Tuner channel filter: make "auto" bandwidth mean something (READY)

The bench proved that at factor 1 with `bandwidth_khz = 0` nothing band-limits
the IQ ahead of the FM demod, inflating every peak-sensitive reading (+21 kHz
MAX deviation, +46% RDS, +50% noise; phase wandering). Proposed fix, written up
but deliberately NOT applied: call `setBandwidthHz` unconditionally at open
with an explicit FM MPX default (200 kHz) instead of leaving mode 0 unapplied.
Alternative: make the ctor apply its own +/-110 kHz design as a real mode so
"auto" means what it says.

- **No longer blocked (operator decision 2026-09-05):** one RTL-SDR is
  representative of all RTL-SDR sticks -- they share the tuner path, and what
  differs between them is front-end gain, which the RF OVERLOAD badge already
  surfaces. The single-dongle bench evidence is therefore enough to change the
  shipped demod.
- **Gate:** re-run the 3-row A/B table on the bench RTL (narrow/auto,
  wide/auto, narrow/200k -- rows 2 and 3 must agree, and row 1 must now match
  them instead of reading +21 kHz MAX / +46% RDS). Then revisit whether the
  narrow-default question reopens (the byte-exact packed-path argument is only
  valid once factor 1 is band-limited).
- Keep the RTL IQ-rate revert (1000 kHz) and the meter-operator-guide.md
  warning until this lands.
- The fix touches the shared `FMDemod`, so the SDRplay backend check (B1)
  should re-confirm the bandwidth behaviour there once hardware is at hand --
  but it does not gate the RTL work.

### A4. Studio<->Meter closed-loop calibration inside the Meter (designed; script version shipped as `calibrate-tx.sh`)

The headless script closes the loop today (REST read of the configured pilot injection, off-air pilot measurement through the honest chain, `output_gain_db` trim; validated on air 2026-08-31, +/-0.06 dB repeatability). The same loop inside the Meter, design:

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
- Needs a build-capable session with the bench TX off air (no builds while on air).

## B. Hardware validation queue (maintainer; agent prepares harnesses)

Only ONE SDR-hardware item remains: RTL-SDR needs no cross-device work (see
"Deliberately NOT doing"), while SDRplay is a separate backend and does.

1. **SDRplay backend check** -- the RSPdx wide-capture path has been
   hardware-unverified since 0.43; the same session should confirm the A1
   bandwidth behaviour on that backend and settle the 8-bit-vs-14-bit SIGNAL
   QUALITY scale caveat (a caveat, not a defect: the bench's "8-bit floor" was
   auto-gain overload, now surfaced by the RF OVERLOAD badge). Reuse the bench
   method: scratch cmake build of `mpx-tuner`, capture composite, replay via
   `--stdin`; the capi harness for the shipped path already exists as a
   pattern (~45 lines against `mpxtuner_open`).
2. **Reference-receiver side-by-side re-check post-P1** -- conventions did not
   change (bench confirmed pilot 5.77 / RDS 3.87 on 88.6, consistent with
   2026-07-07), so this should be a formality; do it before quoting 0.45
   numbers against the reference receiver.
3. **75 us station check** for the de-emphasis setting (a real 75 us market
   signal, not synthesized).
4. **VoiceOver pass over the Meter** (the P3 accessibility work is in; the
   audit checklist item is the human pass).
5. **Long SDR + RF-spectrum GUI run with Instruments** -- "View Body" on the
   root should now be 0 Hz (rfSpan chip isolation fix); also re-checks the
   0.34-class leak stays fixed in the one mode it regressed in.

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

- Cross-RTL validation (operator decision 2026-09-05): if a change works on
  one RTL-SDR it works on all of them -- same tuner path, and the per-stick
  differences are front-end gain, which the RF OVERLOAD badge surfaces.
  A second RTL proves nothing new, and neither does chasing a stick with a
  known ppm error (the decoder PLL fix is already measured offline with
  `mpx-offline`: 24.8 -> 64.4 dB separation at 100 ppm). SDRplay is the
  exception: it is a different backend, not a different dongle, so it keeps
  its own item (B1).

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
- Per-chain pilot-to-RDS phase correction or SDR-specific verdict suppression:
  `mpx-offline` proved the digital chain's dispersion is <= 1 deg on every
  variant; the angle wander between off-air captures is reception (multipath).
