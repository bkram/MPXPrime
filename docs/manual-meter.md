# MPX Prime Meter — User Manual

MPX Prime Meter is the receive/analyze counterpart to the MPX Prime Studio
encoder, shipped as `MPX Prime Meter.app` in the same DMG. It takes an FM MPX
composite, decodes stereo + full RDS, and shows everything on one dashboard
window. Use it to check your own air signal, compare against other stations, or
validate a chain.

> **Platform: macOS only.** The Meter is a native macOS app and is
> **Apple-Silicon-only** (it statically links the arm64 RTL-SDR / SDRplay
> tuner for in-process SDR). **There is no Linux or Intel build of the
> Meter.** The MPX Prime Studio *encoder* runs on macOS and Linux; the Meter
> does not. To analyze a signal from a Linux box, capture it on a Mac running
> the Meter.
>
> The Meter also has **no REST API or web interface** — the remote-control
> REST API + web dashboard is an encoder (MPX Prime Studio) feature. The
> Meter is driven from its own window, or the headless terminal modes below.

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

Measurement integrity (0.45): the Quality card raises a red **SAMPLES
DROPPED** badge if the capture pipeline ever dropped input samples -- from
that moment the peak-hold and accumulated readings (MAX, PEAK +/-, OVER
77 kHz, the distribution, MPX POWER max) contain a gap artefact and should
not be quoted; press **Reset Peaks** to clear the badge and start the
accumulators clean. A red **NO INPUT** badge means the input device stopped
delivering samples while capture is still running (USB power management, a
stalled SDR stream): the readings on screen are frozen, not live. Stopping
capture (or losing the device) blanks the dashboard back to its idle state,
so anything you see with the meter stopped is never mistaken for a live
reading.

An amber **MONO DECODE** badge means a signal is present but the 19 kHz pilot
is too weak to recover the stereo subcarrier, so the decoded audio is mono
(M only) -- as it also is on a genuinely mono station. Deviation, pilot level
and MPX power stay valid; the readings that describe the stereo image
(**SEPARATION**, **L / R BALANCE**, **PHASE CORR**) read `--` instead of
describing the mono decode, and a stereo recording made in this state will
have identical channels. Improve reception, or check that the station is
actually transmitting a pilot.

Capture refuses to start below 128 kHz (0.45): composite measurement needs the
0-60 kHz band and RDS sits at 57 kHz, so readings at lower rates would silently
exclude the stereo sidebands and count them as noise. If the Meter reports the
rate as too low, set the interface to 192 kHz in Audio MIDI Setup. The analyzer
always runs at the rate the device actually opened at, even when a slow USB
rate switch lands on a different rate than requested.

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

With **more than one SDR attached** (any mix of RSPs and RTL dongles) an **SDR
picker** appears in the input bar: Auto (prefers SDRplay) or a specific unit,
remembered by **serial number** so the choice survives replugging. If the
chosen unit is absent at start, the Meter starts on Auto with a note and keeps
your selection. To meter two stations at once, launch the app twice and give
each instance its own SDR -- and its own **Out** device (below).

The input bar's right side has a **DC block** checkbox (default on): a
transmitter carrier offset becomes DC after FM demod -- an off-center
vectorscope, offset waveforms, and DC in the monitor audio and recordings
(common on wireless audio links). Broadcast FM has no legitimate DC, so
leave it on; deviation measurements are always DC-tracked separately.

The input bar's right side also has an **Outputs** button opening the routing
popover (all live-apply; capture, analysis, and recording are untouched;
remembered by device UID):

- **Monitor (decoded audio)** -- where the decoded stereo plays (System
  Default, or any output device). With two Meter instances, give each its
  own output.
- **MPX pass-through (raw composite)** -- plays the received composite
  (pilot + stereo subcarrier + RDS) to its own output device, in addition
  to the decoded monitor. Feed a 192 kHz-capable DAC into an FM exciter
  (instant rebroadcast / translator) or into a hardware analyzer. The
  device is switched to the capture rate (192 kHz) while the pass-through
  runs and restored afterwards -- a 48 kHz output would low-pass away the
  pilot and subcarriers, so use a genuinely 192 kHz-capable interface.
  A **Gain** field (0..+12 dB, live) matches the analog level to your
  analyzer or exciter: at 0 dB the scale is the SDR convention (0 dBFS =
  150 kHz, so a 75 kHz station peaks at -6 dBFS); +6 dB puts 75 kHz at
  digital full scale, but deviation beyond that then clips the DAC --
  leave ~1 dB of headroom (+5 dB covers peaks to ~84 kHz).

- **Audio device** (`Source -> Audio`): pick the input carrying the composite
  and the channel (L / R / Mix). The Meter raises the device to 192 kHz on
  start and restores the prior rate on exit. RDS at 57 kHz needs a capture rate
  >= 128 kHz, so the default input prefers a 192 kHz-capable device.
- **RTL-SDR** (`Source -> SDR`): set the frequency and Start. The frequency
  field spans the active tuner's full range (RTL-SDR ~24-1766 MHz, SDRplay
  RSP 0.1-2000 MHz) at **1 kHz resolution** -- not just the broadcast band's
  100 kHz raster. Any FM-stereo signal measures the same way, including
  analog audio links and license-exempt stereo transmitters (e.g. 864.540);
  typing takes 1 kHz precision, scrolling steps 0.1 MHz. Off-grid carriers
  otherwise show up as DC offset after demod (see DC block). The Meter decodes
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

- **Audio**: IN / L / R / M / S levels and the **PHASE CORR** readout (L/R
  phase correlation: +1 = mono, ~+0.7-0.95 = normal stereo, negative =
  out-of-phase / mono-incompatible -- it turns amber near zero and red when
  negative). Hover any readout, meter, or control for an explanation tooltip.
- **Deviation**: pilot / RDS / total (MAX) deviation meters, on the top row
  beside the audio levels. MAX is the highest excursion in the last second
  (50 ms peak-hold slots, the ITU-R SM.1268 display convention). RDS is the
  **peak deviation of the 57 kHz subcarrier, measured coherently -- the
  injection level the RDS encoder was set to** (encoders normalize the
  shaped data waveform by its peak, and EN 50067's +/-1.0 to +/-7.5 kHz
  deviation range is a peak range). It is a solid reading that data
  modulation does not move; set 2.0 kHz on the encoder and this reads 2.0.
  Under the bars, **AVE / MIN** are the mean and lowest of the same last
  second of 50 ms slots MAX is drawn from. MAX far above AVE is a peaky,
  lightly-processed signal; MAX close to AVE is a dense one running near its
  ceiling continuously.
- **Quality** (second row, beside the vectorscope): **SIGNAL QUALITY** rates
  reception on a 5-step scale from Unusable to Excellent, with the figure it
  is derived from -- how much energy sits *above* the modulated baseband
  (over 60 kHz), where nothing is legitimately transmitted, so it is demod
  noise and interference. That band degrades first, which is why it decides
  whether the rest of the numbers can be trusted: deviation and RDS level
  lose accuracy before pilot and MPX power do. Reposition the antenna to
  improve it. **CARRIER OFFSET** is the transmitter's frequency error -- an
  FM demod turns an offset carrier into composite DC, so this reads it
  directly (on an audio input it is whatever DC the interface presents
  instead); deviation measurements are DC-corrected either way. **L / R
  BALANCE** is the standing level difference between the decoded channels,
  heavily smoothed, + meaning left is louder; real programme averages to
  about 0 dB, and a persistent offset means the stereo encoder or its feed is
  lopsided.
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
  best stereo separation, the **RDS PHASE** compliance readout (see "RDS
  subcarrier phase" below), and
  Reset to clear the held values. MPX power and
  the peaks turn amber near and red at/over the limit (0 dBr, 75 kHz). On
  SDR it also shows **SIGNAL** -- the received level (green strong / red
  weak). See "Signal level and dBm" below for the units.
  The same figures are printed by the headless CLI dashboard as a `MOD`
  line (`MPX ... dBr (max ...)   PK +/- kHz   >77k ...%`).
- **Vectorscope**: stereo goniometer (vertical = mono, tilt = single channel,
  horizontal spread = out-of-phase / mono-incompatible). On the second row,
  beside the trends. The display gain automatically rides the program level
  so the figure fills the scope, hardware-goniometer style -- fast shrink
  when the program gets hot, slow grow as it quiets.
- **Trends**: deviation (kHz) and MPX power (dBr) over ~60 s, with limit
  lines, plus the **Deviation Distribution**. The distribution is the
  accumulated histogram of the same 50 ms peak-hold slots MAX uses, in 1 kHz
  bins since the last Reset: for every deviation on the x-axis it plots what
  share of the programme reached that value *or more*. Read it at the dashed
  75 kHz line and you have the number that matters -- how much of the signal
  is at or over the limit. The header shows the highest bin ever filled, the
  share at or above 75 kHz, and the sample count. Give it 15-60 minutes of
  programme before drawing conclusions: it needs representative material, and
  it is the one view that describes modulation in a way a single MAX number
  cannot.
- **Scopes**: composite, decoded L, decoded R. Click a decoded scope to toggle
  it between waveform and its audio spectrum (0-20 kHz).
- **Spectrum** with band captions (Mono L+R, 19 kHz Pilot, Stereo L-R lower/upper sideband, 57 kHz
  RDS, 67.65 kHz Direct Band, 92 kHz SCA). A **60 / 100 kHz** span toggle in the
  header picks the display range; 60 kHz (the default) focuses on the modulated
  bands, 100 kHz shows the full baseband including SCA.

  On the SDR input the header also carries an **MPX | RF** switch. **MPX** is
  the demodulated baseband described above. **RF** is the band around the tuned
  carrier, straight from the tuner's IQ -- the view an SDR application shows:
  the station's own RF footprint, its neighbours on the 100/200 kHz raster, and
  any splatter between them. Use it to spot an adjacent channel that is
  degrading reception, or to check a carrier is where it should be. The centre
  line marks the tuned frequency and the grid follows the 100 kHz FM raster.

  The RF span is the **Sample Rate** in the input bar: *1 MSPS* (the default)
  shows about +/-0.5 MHz, *2 MSPS* about +/-1 MHz, and *Narrow* is the minimum
  the demodulator needs and shows only the tuned carrier. Changing it restarts
  the capture. It cannot affect any measurement -- the FM demodulator always
  runs at its own fixed rate behind a decimator whatever the capture rate is,
  so widening the view only costs USB bandwidth and CPU. Drop to *Narrow* if a
  dongle struggles at the higher rate.
- **RDS**: PI / PTY (code + name) / PTYN / ECC / PS / RT / RT+ / Long PS / CT /
  AF / group histogram and live block-error rate. **Groups** shows each type's
  count *and its share* of the stream; **Order** shows the last 18 groups in
  the order they were transmitted. The counts say what an encoder sends, the
  order shows how it interleaves them -- a repeating scheduler pattern, a
  starved group type, or one type bursting and crowding out the rest. The **RDS** row (top of the RDS
  panel) shows sync, PI, the TP/TA/MS flags, and **BER** at the end (BER under
  ~5% is a clean link). The subcarrier's **phase angle** is measured too, but
  it is shown in the Modulation card as **RDS PHASE** -- see the next section. The readout is **gated by reception quality**: an RDS
  block decoder syncs on noise easily and would hallucinate random PI/PTY, so
  the panel shows `no usable RDS -- BER ..% . .. kHz` until the link is
  plausible (BER at or under ~15% to open, over ~25% to close again, a
  detectable 57 kHz subcarrier, and a few valid blocks decoded); after 10 s
  gated the decoder is cleared so stale garbage never flashes when it opens.
  Tick **Force** in the panel header to bypass the gate and watch the raw
  decoder output (diagnostics -- expect garbage on noise). PI and PTY are decoded against the reference tables in
  the [Studio manual's appendices](manual.md#appendix-rds-pi-and-ecc-country-table).

### Signal level and dBm

The **SIGNAL** readout can show three units, picked by **Signal** in the SDR
input bar:

- **dBFS** (default) -- the raw channel power relative to the ADC's full
  scale. Always available, always correct, but *relative*: it moves when the
  gain moves, so it only tracks field strength with Auto Gain off.
- **dBm** -- absolute power at the antenna.
- **dBuV** -- the same thing in the unit measuring receivers use (in 50 ohm,
  dBuV = dBm + 107).

The absolute units are computed as **channel power - system gain +
calibration**. The middle term is read back from the tuner rather than
assumed, so the reading stays correct while AGC and the LNA move it around --
the **SYSTEM GAIN** readout in the Quality card shows the value being used.

The last term is the honest part. Neither an SDRplay RSP nor an RTL dongle
carries a factory power calibration, so nothing can supply the absolute
reference for you: set the **cal** offset once, against a signal generator or
a calibrated receiver, and it holds for that antenna and cable. (Tune both
instruments to the same strong station, read the difference, type it in.)
Until you do, dBm and dBuV are correctly gain-compensated and correct
relative to each other, but their zero point is arbitrary.

SDRplay reports a true system gain, so the RSP path is the accurate one. On
RTL-SDR only the tuner stage is knowable and its gain table is approximate and
varies unit to unit -- treat an RTL dBm reading as indicative.

### RDS subcarrier phase

**RDS PHASE** in the Modulation card is the angle between the 57 kHz RDS
subcarrier and the third harmonic of the 19 kHz pilot -- the "RDS phase"
reading of a Belar RDS-1 or a DEVA analyzer. EN 50067 sec 1.2 allows **two**
answers, each within 10 degrees:

| Reading | Meaning |
| --- | --- |
| `0 deg (in phase)` .. `10 deg` | Locked in phase with the pilot's third harmonic -- the common convention, and what MPX Prime Studio transmits. |
| `80 deg` .. `90 deg (quadrature)` | Locked in quadrature -- also fully legal (historic BBC practice). |
| anything between | `out of spec`, shown amber: the encoder is not truly pilot-locked. |

An out-of-spec angle is worth a trim on the encoder, but it is not an
emergency: most receivers recover the 57 kHz carrier from the subcarrier
itself and decode either convention. It matters for receivers that
regenerate 57 kHz by tripling the pilot -- for those, ~45 degrees (equally
far from both conventions) is the worst case. A reading that will not settle
usually means the RDS generator is free-running rather than locked to the
pilot at all.

Two caveats when judging a transmitter by this number. The standard specifies
the tolerance **at the transmitter's MPX input**, whereas the Meter measures
off-air (or off the audio input), so exciter and receive-path group delay add
a few degrees you cannot attribute to the encoder. And the reading is known
modulo 180 degrees, because RDS is suppressed-carrier DSB -- an anti-phase
subcarrier is the in-phase case with inverted data, which no receiver can
distinguish either. The readout shows `--` when there is no pilot, or less
than 0.8 kHz of RDS, or the subcarrier is too noisy to measure; it is taken
from the subcarrier itself, so it still reads while the decode readout is
gated.
The headless CLI dashboard prints it on the `DEV` line as `PHASE nn deg ...`.

The readout follows the same conventions as a Pira P175/P275 FM Broadcast
Analyzer, so the two can be compared number for number: both fold the angle
to an unsigned 0-90 (the Pira manual puts it as "we can equate 90 degrees =
-90 degrees"), both apply the +/- 10 degree tolerance, and both show no value
when the pilot and subcarrier are not in a stable phase relation. Pira
specifies its error as +/- 4 degrees; the Meter's DSP error measured on
synthetic composites is under 0.15 degrees across the whole range and under
0.01 degrees for a pilot frequency offset, so off-air accuracy is set by
reception and transmitter path, not by the measurement. Pira's manual also
notes the angle drifts a little with transmission-equipment temperature, so
judge an encoder after it has warmed up.

Deviation is referenced to a 75 kHz total. The deviation/MPX-power
measurement path is DC-tracked (an SDR tuning offset otherwise skews the
+/- peaks apart) and band-limited to 60 kHz with a linear-phase FIR so the
FM demod noise triangle above the modulated bands doesn't inflate the
readings -- linear-phase because a steep IIR filter overshoots on a clipped
composite's edges and reads deviation the transmitter never emitted. The
scopes, spectrum, and IN meter stay unfiltered so noise remains visible.

## SDR troubleshooting

- **"Device lost" while capturing**: the dongle dropped off the USB bus (or
  was unplugged). The Meter stops and deliberately abandons the dead handle
  -- closing it would crash inside the USB stack -- which keeps that unit's
  USB claim until you **replug it or quit the app** (the status line says
  so). Replug the dongle before reusing it.
- **SDRplay missing from the picker**: if a previous Meter was killed
  uncleanly (force-quit, crash), the SDRplay service can briefly hold the
  RSP for the dead process. Replug the RSP or restart the SDRplay service.
  Normal quits -- including `kill`/logout, which the Meter handles
  gracefully -- always release it.
- A wedged RTL dongle (garbage demod, BER pinned near 75%) needs a physical
  replug; no software reset recovers it.
- **RDS panel shows "no usable RDS"**: the reception-quality gate is holding
  back the decode readout because BER is too high or the 57 kHz subcarrier is
  too weak -- the signal genuinely has no trustworthy RDS (many audio links
  carry none at all). The BER/level evidence stays live in that line; Force
  (panel header) shows the raw decoder output anyway.

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

Recordings are crash-safe and honest about failure (0.45): the WAV header is
updated every couple of seconds while recording, so a capture interrupted by a
crash, forced quit or power loss stays readable up to the last update instead
of parsing as an empty file. A recording that can no longer be written -- the
disk filled up, the volume disappeared, or the file reached the classic WAV
4 GB size limit (about 62 minutes of stereo at 192 kHz; the file is finalized
cleanly at that point) -- stops itself and the status line says why, rather
than keeping the record light on while silently discarding audio. Overloaded
or non-finite decode samples are clamped into range instead of crashing the
app. For captures longer than the 4 GB limit, start a new file when the
status reports the limit was reached.

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
