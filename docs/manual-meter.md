# MPX Prime Meter — User Manual

MPX Prime Meter is the receive/analyze counterpart to the MPX Prime Studio
encoder, shipped as `MPX Prime Meter.app` in the same DMG. It takes an FM MPX
composite, decodes stereo + full RDS, and shows everything on one dashboard
window. Use it to check your own air signal, compare against other stations, or
validate a chain.

For the encoder, see the [MPX Prime Studio manual](manual.md). For a project
overview see the [README](../README.md); to build from source see
[BUILDING.md](BUILDING.md); for the measurement-engine internals see
[ARCHITECTURE.md](ARCHITECTURE.md). The RDS PI/ECC country and PTY code tables
that the Meter decodes are in the Studio manual's appendices
([PI/ECC](manual.md#appendix-rds-pi-and-ecc-country-table),
[PTY](manual.md#appendix-rds-programme-type-pty-codes)).

## Launching

- Double-click `MPX Prime Meter.app`, or run `macOS/.build/release/MPXPrimeMeter --gui`.
- Headless terminal dashboard: `./run-meter.sh --device <spec>` (audio-device
  input) or `./run-meter.sh --stdin` (a composite piped on stdin). The in-process
  SDR is GUI-only; with no arguments `./run-meter.sh` opens the window and
  auto-detects a dongle. Use `--sdr-freq <MHz>` to open the GUI pre-tuned.

The Meter **remembers your last-used settings** (frequency, input source, all SDR
controls, channel, monitor, pilot reference / calibration, record format,
spectrum span, and the selected devices) between launches; they are stored in the
standard macOS preferences and restored on the next start. Pass `--sdr-freq`
to override the saved frequency for that launch.

## Window layout

The toolbar carries only the frequent commands -- **Start/Stop** (⌘Return),
the **Source** switch (Audio / SDR), and the **Monitor** toggle. The detailed
input settings for the selected source (audio device + channel, or SDR
frequency / AGC / gain) live in a translucent **input bar** directly below the
toolbar. The scopes, spectrum, vectorscope, and trend graphs are deliberately
dark instrument displays in both Light and Dark appearance (the convention for
audio/SDR instruments) so the traces stay legible; the surrounding window
chrome follows the system appearance.

## Input

The **Source** defaults to **SDR** when a dongle (SDRplay RSP or RTL-SDR) is
detected at launch, otherwise to **Audio**.

- **Audio device** (`Source -> Audio`): pick the input carrying the composite
  and the channel (L / R / Mix). The Meter raises the device to 192 kHz on
  start and restores the prior rate on exit. RDS at 57 kHz needs a capture rate
  >= 128 kHz, so the default input prefers a 192 kHz-capable device.
- **RTL-SDR** (`Source -> SDR`): set the frequency and Start. The Meter decodes
  the dongle **in-process** -- it links the vendored tuner (a stripped subset of
  FM-SDR-Tuner, from `tuner/`) as a library and runs the RTL-SDR capture + FM
  demod on its own thread, delivering the mono MPX at 192 kHz with absolute
  calibration (full scale = 150 kHz). No helper process, no Homebrew, no
  separately-placed binary -- just a connected dongle. The librtlsdr / liquid-dsp
  dylibs ship inside the app. **SDR support makes MPX Prime Meter Apple-Silicon
  only** (the RTL-SDR libraries are arm64-only); the MPX Prime Studio encoder
  remains universal. (For a headless terminal SDR readout, pipe an external
  `fm-sdr-tuner`/`mpx-tuner` composite into `./run-meter.sh --stdin`; the
  in-process SDR backend is GUI-only.) Tested with **Rafael Micro R820T** and
  **Elonics E4000** tuner dongles; other librtlsdr-supported tuners (R828D,
  FC0012/0013, FC2580) should work but are untested.

  **SDRplay RSP** is also supported and **auto-preferred** when an RSP is
  attached (its 14-bit ADC and front end give cleaner audio, better separation,
  and a lower MPX-power noise floor than an RTL dongle). It needs SDRplay's API
  service installed (the SDRplay driver); the app loads it at runtime and falls
  back to RTL-SDR if it's absent. Tested on an RSPdx.

  When a dongle is attached at launch the Meter opens **already capturing** in
  SDR mode with audio monitoring on, so it comes up live. Every numeric control
  below (Frequency, Gain, **LNA**, **PPM**, and the **IF BW** menu) also steps on
  **mouse-wheel / trackpad scroll** while the pointer is over it -- no need to
  type or open the menu.

  All SDR controls apply **live** -- no restart, no audio gap:
  - **Frequency** -- retunes in place (also clears the prior station's meters).
  - **IF BW** -- the IF channel bandwidth. RTL shows the demod channel-FIR steps
    (Auto, or 56-311 kHz); **SDRplay shows the RSP's analog IF filter widths**
    (Auto = 600, or 1536 / 600 / 300 / 200 kHz). Narrower **rejects adjacent-
    station interference** but rolls off the composite top; 300 kHz still passes
    the full composite, 200 kHz starts to lose the top (SCA / high RDS). Start
    wide; narrow only to fight a strong neighbour.
  - **Auto Gain** -- automatic gain (RTL: tuner gain mode; SDRplay: AGC on the IF
    gain). Off reveals a manual gain field -- RTL tuner gain in **dB**, or the
    SDRplay **IF** gain.
  - **LNA** (SDRplay only) -- the front-end LNA gain-reduction step (0 = most
    gain), separate from the IF gain / AGC. Raise it to relieve front-end
    overload on strong broadcast signals. (SDRplay thus has both gain stages:
    LNA front-end + IF.)
  - **Antenna** (SDRplay only) -- selects the RSP antenna input (e.g. A / B / C
    on an RSPdx).
  - **Bias-T** -- 5V bias tee to power an active antenna / inline LNA (RTL-SDR v3,
    or RSP models that support it). Never feed it into a DC short.
  - **PPM** / **RTL AGC** (RTL-SDR only) -- ppm frequency trim, and the RTL2832
    digital AGC separate from the tuner gain.

## What it shows

- **Audio**: IN / L / R / M / S levels and L/R correlation (CORR: +1 = mono,
  ~0.7-0.95 = normal stereo, negative = out-of-phase / mono-incompatible).
- **Deviation**: pilot / RDS / total (MAX) deviation meters, on the top row
  beside the audio levels. MAX is the highest excursion in the last second
  (50 ms peak-hold slots, the ITU-R SM.1268 display convention). RDS is the
  **peak deviation of the 57 kHz subcarrier, measured coherently -- the
  injection level the RDS encoder was set to** (encoders normalize the
  shaped data waveform by its peak, and EN 50067's +/-1.0 to +/-7.5 kHz
  deviation range is a peak range). It is a solid reading that data
  modulation does not move; set 2.0 kHz on the encoder and this reads 2.0.
- **Modulation**: **MPX POWER** (ITU-R BS.412: uniform sliding 60 s window,
  in dBr vs a +/-19 kHz sine) with the worst 60 s window since reset shown
  inline as "max" -- the number BS.412 compliance is judged on; it needs a
  full 60 s of signal before it reads. **PEAK + / -** deviation over the
  last 60 s (50 ms peak-hold slots -- a single impulse ages out instead of
  pinning the reading; a persistent +/- asymmetry suggests a carrier offset
  or one-sided clipping). **OVER 77 kHz** -- the ITU-R SM.1268 compliance
  statistic: the share of deviation samples above 77 kHz (75 kHz + the
  2 kHz measurement tolerance) since reset. Regulators treat more than
  0.0001 % as over-deviation; rare single peaks are not a violation. Plus
  best stereo separation, and Reset to clear the held values. MPX power and
  the peaks turn amber near and red at/over the limit (0 dBr, 75 kHz). On
  SDR it also shows **SIGNAL** -- a relative received-level (dBFS) RSSI
  indicator (green strong / red weak); most meaningful with Auto Gain off.
  The same figures are printed by the headless CLI dashboard as a `MOD`
  line (`MPX ... dBr (max ...)   PK +/- kHz   >77k ...%`).
- **Vectorscope**: stereo goniometer (vertical = mono, tilt = single channel,
  horizontal spread = out-of-phase / mono-incompatible). On the second row,
  beside the trends.
- **Trends**: deviation (kHz) and MPX power (dBr) over ~60 s, with limit lines.
- **Scopes**: composite, decoded L, decoded R. Click a decoded scope to toggle
  it between waveform and its audio spectrum (0-20 kHz).
- **Spectrum** with band captions (Mono L+R, 19 kHz Pilot, Stereo L-R, 57 kHz
  RDS, 67.65 kHz Direct Band, 92 kHz SCA). A **60 / 100 kHz** span toggle in the
  header picks the display range; 60 kHz (the default) focuses on the modulated
  bands, 100 kHz shows the full baseband including SCA.
- **RDS**: PI / PTY (code + name) / PTYN / ECC / PS / RT / RT+ / Long PS / CT /
  AF / group histogram and live block-error rate. The **RDS** row (top of the RDS
  panel) shows sync, PI, the TP/TA/MS flags, and **BER** at the end (BER under
  ~5% is a clean link). PI and PTY are decoded against the reference tables in
  the [Studio manual's appendices](manual.md#appendix-rds-pi-and-ecc-country-table).

Deviation is referenced to a 75 kHz total. The deviation/MPX-power
measurement path is DC-tracked (an SDR tuning offset otherwise skews the
+/- peaks apart) and band-limited to 60 kHz with a linear-phase FIR so the
FM demod noise triangle above the modulated bands doesn't inflate the
readings -- linear-phase because a steep IIR filter overshoots on a clipped
composite's edges and reads deviation the transmitter never emitted. The
scopes, spectrum, and IN meter stay unfiltered so noise remains visible.

## Recording

The input bar (right side) has a format toggle and a **Record** button. Choose:

- **Stereo** -- the decoded L/R audio (a clean, high-quality stereo capture of
  what the decoder produced).
- **MPX** -- the raw MPX composite (mono): pilot + L-R + RDS, the same signal
  the analyzer sees. Useful to re-analyze a capture later or feed another tool.

Press **Record** while capturing to choose a file and start; press it again to
stop and finalize. Both formats are 24-bit PCM WAV at the **capture rate**
(192 kHz for SDR -- the composite needs the bandwidth for the pilot /
subcarriers / RDS, and the stereo file stays at the native rate so recording adds
no real-time resampling that could disturb capture; resample the file afterwards
with any tool if you want a 48 kHz copy). They are written as canonical RIFF/WAV
(no padding chunks) so any audio player or FFT/analysis tool reads them.
Recording is only available while capturing.

## Calibration and measurement validity

**SDR needs no level calibration.** On the SDR path the deviation scale is a
fixed property of the FM discriminator (kHz per sample is set by math, not by
the tuner gain, AGC, or RF level), so amplitude maps directly to kHz with no
calibration step. Tuning to an unmodulated carrier is unnecessary -- and FM
broadcast has none anyway (even dead air carries the 19 kHz pilot). The
audio-device path, by contrast, needs a reference because the analog input gain
is unknown. The **Calibrate** switch on the audio input bar picks how:

- **Pilot** (default, `pilot_ref_khz`, default 6.75) -- scales deviation by
  assuming the 19 kHz pilot equals the **Pilot Ref (kHz)** field. Set it to the
  source's actual pilot deviation: 6.75 kHz is 9%, but stations vary, and a pilot
  that is really 5.7 kHz read against 6.75 inflates every kHz value by ~18%.
- **0 dBFS = N kHz** -- an absolute scale anchored to a known input level, the way
  MPXTool-style monitors calibrate (against a tuner's known composite output, a
  Bessel-null, or a known-deviation tone). If you feed the composite so that
  75 kHz peak deviation lands at -6 dBFS, set N = 150; deviation then comes
  straight off the input amplitude, **independent of pilot recovery** -- the
  robust choice, and identical to what the SDR path does internally.

Both apply live; the SDR path is always absolute and ignores them. Two caveats:
(1) pilot-referencing only fixes the *overall* scale -- if the source's composite
output rolls off above the audio band, the 57 kHz RDS reads low relative to the
pilot no matter the reference, so use the SDR path for an accurate RDS-injection
figure; (2) the only frequency trim is **PPM** for precise tuning; the
sample-clock error scales readings by far less than 0.01% at any sane ppm, so it
does not affect deviation.

**MPX power is only valid on a strong, clean signal.** MPX power follows
ITU-R BS.412 (the limit -- average power over 60 s must not exceed that of a
sinusoidal tone at +/-19 kHz peak deviation) measured under the ITU-R SM.1268
conditions: roughly >= 73 dBf signal, >= 50 dB signal-to-noise, and no
multipath (a directional antenna is effectively required). On a weak, noisy, or
multipath RTL-SDR reception both the peak deviation and MPX power **read high**
-- that is a reception artifact, not over-modulation and not a calibration
error. Rule of thumb: if the peak deviation exceeds about +/-80 kHz and the
station is not genuinely over-deviating, the signal is too poor for a valid
BS.412 measurement. For reference, on a clean signal:

| MPX power | Peak deviation of an equivalent sine |
|-----------|--------------------------------------|
| 0 dBr     | +/-19 kHz (the reference)            |
| 3 dBr     | +/-27 kHz                            |
| 6 dBr     | +/-38 kHz                            |
| 10 dBr    | +/-60 kHz                            |

## Reference-receiver validation (Profline SFP-X)

MPX Prime Meter's readings were cross-validated against a Profline SFP-X
measuring receiver on a live commercial station (2026-07-07): pilot and RDS
matched exactly (5.6-5.7 / 3.5-3.7 kHz on both instruments), and max deviation
agreed within 1-2 kHz measured side-by-side at the same moment -- inside
ITU-R SM.1268's +/-2 kHz instrument accuracy requirement. When comparing peak
deviation against any reference receiver, always compare **live at the same
moment**: deviation peaks are program-dependent, and a weaker reception path
(multipath) inflates them. (The Studio encoder's transmit-side output was
separately validated on the same SFP-X -- see the
[Studio manual](manual.md#reference-receiver-validation-profline-sfp-x).)
