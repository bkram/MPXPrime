# MPX Prime Studio -- Settings and API Reference

Configuration keys, the processing-stage settings, the RDS text grammar, the
now-playing script protocol and the REST API. For installing the encoder,
setting levels and day-to-day operation, start with the [Operator
Guide](studio-operator-guide.md).

## The configuration file

> **Linux (web dashboard encoder):** the encoder also runs on Linux as a
> service operated from the dashboard (`--web`; the GUI and the Meter are macOS apps). The same INI works, with two differences:
> the default config path is `~/.local/share/MPX Prime Studio/MPX Prime
> Studio.ini`, and the `input_device_uid` / `output_device_uid` keys hold
> ALSA PCM names (`default`, `hw:0,0`, `plughw:...`) instead of CoreAudio
> UIDs. See docs/BUILDING.md "Linux (web dashboard encoder)" for setup and device notes.
>
> **A missing audio device does not crash the encoder.** If the configured
> ALSA device can't be opened at start, the control server still comes up;
> open the dashboard, pick a present device on the **Audio I/O** page, and
> press **Start**. Note that USB cards can change their `hw:CARD=<name>`
> across reboots when two audio cards are present (ALSA assigns Device /
> Device_1 by probe order) -- if the service comes up stopped after a
> reboot, reselect the device in the dashboard.

Default config location (the same INI format and keys on every platform; `--config <path>` overrides, and the resolved path is printed at startup):

| Platform | Default config file |
|---|---|
| macOS (GUI app or `--nogui`) | `~/Library/Application Support/MPX Prime Studio/MPX Prime Studio.ini` |
| Linux, run by hand from a source build | `~/.local/share/MPX Prime Studio/MPX Prime Studio.ini` |
| Linux, Debian/Ubuntu package (`mpxprime` service) | `/var/lib/mpxprime/MPXPrime.ini` |

The per-device calibration memory (`<config>.devicecal.json`) and the preset slots (`<config>.snapshots.json`) live next to the INI on all three.

Relevant config sections:

- `INTERFACES`: input/output/monitor device UIDs and channels, source mode, monitor enable, block size
- `MPX`: processing, levels, stereo coding, limiter behaviour
- `RDS`: programme service, radiotext, flags, carrier settings

## Processing stages: what to enable and what each key does

For typical FM broadcast use (clean / community / LPFM), the recommended set of processing stages to **enable** is:

- **Phase Rotator** -- voice waveform symmetrization (f ~ 200 Hz)
- **AGC** -- long-term level riding (target ~ -14 dBLU, range +/-10 dB, K-weighted, programme-dependent release, 150 ms attack -- a gain rider that leaves transients to the limiters; the 6 ms attack of earlier builds ducked the whole mix on every drum hit)
- **Parametric EQ** -- 4-band tonal shaping (shelf + 2 peaks + shelf)
- **Multiband** -- 3 or 5 bands (`Bands`; the 2-band mode is gone), linear-phase FIR crossovers on the TX path; the `5_jazz` preset is a balanced starting point for mixed music + speech
- **Expander** -- per-band downward expander, gates noise floor (threshold ~ -45 dB, ratio 2.0 = a true 1:2 below threshold; 1.0 = off. Until 2026-10-16 the ratio was applied off by one: 2.0 acted as 1:3)
- **Band Limiter** (per-band limiter, `multiband_limiter_*`) -- per-band peak control (threshold ~ -3 dB, atk 0.5 ms, rel 50 ms)
- **Audio Clipper** (`dc_clipper_*`) -- distortion-cancelled audio-band clipping: 8x oversampled, it removes its own clipping distortion below the `Cancellation Frequency` (default 2 kHz) with a zero-phase linear-phase cancellation path, so it never adds distortion (until 2026-10 an LR4 error path added up to +4.3 dB around the corner); about 2.6 ms latency at 48 kHz with the 2 kHz corner
- **HF Limiter** -- pre-emphasis-aware, gain-riding HF control (`Sound` -> `HF Limiter`; `hf_limiter_enabled`, `hf_limiter_threshold_db`, `hf_limiter_top_threshold_db` (Advanced), `hf_limiter_attack_ms` 1.5, `hf_limiter_release_ms` 20, `hf_limiter_max_reduction_db` 12). On by default in every Format Profile (0.45). It rides only the pre-emphasis *boost*: a cymbal or hi-hat that overshoots after pre-emphasis briefly loses part of its boost instead of being clipped or dragging the whole mix down in the Audio Limiter, and it can never cut HF below the flat (un-emphasised) programme level. Since 0.65 it only starts a ride it can finish: a programme gate on two short peak-hold envelopes, one pair per channel, opens the stage only when that channel's own boost covers its excess over the threshold (since 2026-10; one shared gate let a bass peak in one channel duck the other channel's treble), so a kick with a quiet hat is left to the Audio Limiter instead of flooring the HF gain on every crest (the 0.45 guard keyed on 20 % of the peak and did exactly that); once open, the gain law lands exactly on the threshold, never removes more than the excess and never raises a peak. The threshold now sits 0.5 dB ABOVE the Audio Limiter's per profile (Music -- Clean -0.4 dB, Loud -0.9, Speech -0.6, Classical -0.2), Orban's ordering, so the stage sees only HF excess; `hf_limiter_top_threshold_db` (default 1 dB tighter) is the ceiling for the band above 13 kHz -- the detector slides between the two thresholds by the share of boost energy above 13 kHz, one gain on the whole boost, zero latency. The receiver's fixed de-emphasis turns the action into a brief, bounded HF dip -- the trade every broadcast HF limiter makes (Optimod topology). All controls live-apply. `--verify-hf-transients` reports the stage's own HF loss (0.3-0.7 dB on the shipped profiles, bound 1.0 / 1.5) and its gain ripple on a sustained wash (bound 0.3 dB) next to the hat and ride SINAD. A separate, fixed 2 dB "encoder HF guard" ahead of the encoder lowpass stays in the chain: it protects receiver-side HF stereo separation (composite-clipper IM) at levels where this limiter does not engage.
- **Audio Limiter** -- pre-encode L/R true-peak limiter with default-on Phase 1 + Phase 2 look-ahead (Dolby `US 5,579,404`, HF-subband-aware) -- see 0.30 CHANGELOG. `Enable Audio Limiter`; `Threshold` reads -6.0 to -0.0 dBFS and is stored linear as `pre_encode_threshold` (0.5-0.999); `Look-Ahead`; `Stereo Link` (`pre_encode_stereo_link`, 0-1, default 1 = both channels take the louder channel's gain; lower values let the quieter channel keep more of its level while the louder one limits, at the cost of a momentary image shift; live); `Look-Ahead on HF Transients Only` under Advanced. Its 4x interpolator is a linear-phase Kaiser FIR (7 samples of extra latency at 48 kHz)
- **Composite Clipper** -- 16x oversampled differential composite clipper (threshold -1.0 dB, ceiling -0.3 dB, drive 6 dB). Oversampling factor is configurable (`mpx_clipper_oversampling`, default 16; Composite Clipper > Advanced > Oversampling, applies live): 8 for older hardware that needs the CPU back, 32 for Omnia.9-class spec-sheet parity at roughly double this stage's CPU cost. See the comment block in the sample `MPXPrime.ini` for when each value makes sense. Two keys changed in the 2026-10 overhaul, both live: `mpx_clipper_lookahead_depth_db` (`Clip Depth`, 0-6 dB, default 1.0 in every Format Profile; Composite Clipper > Advanced) is how far above the ceiling the 2 ms look-ahead lets the composite run before it rides, so the oversampled kernel clips that depth -- 0 restores the pre-overhaul behaviour, where the look-ahead rode every overshoot and the kernel read 0.16 dB at any drive; `mpx_clipper_stereo_guard` (`Protect Stereo Subcarrier`, 0.00-1.00, shown in percent) defaults to 0.5 (was 1.0), the share at which the clipper's distortion cancels in a receiver's quiet channel (60 dB or more of decoded separation on hard-panned programme through Music - Loud against 25 dB at 1.0 and 27 dB at 0.0; `--verify-stereo-guard` prints the table). The legacy `mpx_clipper_cancel_stereo = True/False` still loads as 1.00/0.00.
- **Safety Limiter** (final MPX limiter; `Sound` -> `Loudness and Output`) -- `limit_mpx` (`Enable Safety Limiter`, default `True`), `limit_threshold` (default `1.0` since the 2026-10 overhaul, was 0.98; accepted 0.5-1.0, read in dBFS on both front ends; it is normalised onto the audio-composite budget per sample, so 1.0 means "the budget" and a lower value is a deliberate bite out of it -- a hand-set value is kept on upgrade), `limit_lookahead_enabled` / `limit_lookahead_ms` (5 ms). All restart-class. Its detector reads the 4x true peak of the audio composite, so nothing above the threshold leaves between samples either; about 0.8 dB of gain reduction on dense programme at the default clip depth is the restored guard-band share of the clipping, not a fault. MPX Output only (`ChainFeature.finalStage`; the processed-audio modes bound their peaks with the true-peak guard instead); `Threshold` sits under Advanced on both front ends.
- **Mono Bass** (`Sound` -> `PrimeBass`, Mono Bass card) -- `mono_bass_enabled` (default `True`) and `mono_bass_freq_hz` (`Mono Below`, 60-250 Hz, default `110.0`), both live. Per Format Profile: 110 Hz on Music - Clean, Speech / Talk and Music - Dense, 115 Hz on Music - Loud, 90 Hz on Classical / Wide Dynamics. Clean and Speech were 140 Hz until 2026-10-30: 140 Hz is the high end of broadcast practice (80-120 Hz) and that corner alone kept bass-heavy programme from meeting the verifier's width goal. The split is linear-phase and sums flat; latency about 1070 / corner-Hz ms (10 ms at 110 Hz).

Recommended **off** by default (enable only when needed):

- **PrimeBass** -- psychoacoustic bass enhancer (missing-fundamental synthesis): the band below `primebass_freq_hz` (F0) is isolated with 24 dB/oct band-passes, normalised by its own envelope so the harmonic level tracks the fundamental exactly, run through an asymmetric generator that makes a real 2nd + 3rd (+5th) series, band-limited to F0..5 F0 and added to the dry signal; an envelope guard keeps peak growth under +1.5 dB and the Bass Clipper holds the rest. Knobs: `primebass_amount` = series level relative to the fundamental; `primebass_harmonics` = balance from 2nd-dominant (0) to 3rd/5th-dominant (1); `primebass_drive` = hardness of the odd device (soft cubic to hard clip); `primebass_density` = bounded upward compression of the harmonic layer (gain FALLS with level, Big Bottom's law; 0 = exact tracking); `primebass_subharmonics_*` = octave divider, off by default. Ranges, measured with `--sweep-primebass` so the top of each slider is still useful: amount 0..0.5, freq_hz 40..120, harmonics 0..0.5, drive 0..1.5 (the slider starts at 0.2), density 0..1, subharmonics_amount 0..0.4; a saved value outside them is pulled in on load. Rebuilt in 0.65: the old generator was odd-symmetric (no 2nd harmonic at all), fed by a 6 dB/oct one-pole that let the midrange intermodulate, and gated per sample. Gate: `--verify-primebass` (harmonic levels, level invariance, midrange isolation, no DC, no steps, peak growth, bit-identity when off). Useful for thin source material; enable per-format.
- **Bass Clipper** -- engage only when LF transients are pushing the chain past the downstream limiters; if PrimeBass is off, usually unnecessary. `Threshold` is the ceiling the low band cannot exceed; since 0.65 the curve bends smoothly into it over roughly the last decibel instead of stepping, so peaks that just cross it no longer come out with a notch in the crest. `Drive` and `Threshold` keep their meanings.
- **Stereo-image protection** -- `stereo_image_protect_enabled` (default `False`) and `stereo_image_max_side_ratio` (1.0-3.0, default 1.55), both live-apply, on the PrimeBass page's `Stereo Image` card under Advanced; FM paths only (`mpx`, `fm`). A side/mid envelope limiter ahead of pre-emphasis: the side (L-R) is held under the ratio times the mid (L+R), or under 1.16 times the source's own ratio where that is higher (floor 1.025), 10 ms attack / 300 ms release, reference delay-matched to the processing latency, idle without a mid reference so anti-phase content passes. Always on until 2026-10 (the removed widener's safety net, with its default baked in); off now because with every dynamics stage stereo-linked the only width left to limit was the source's own -- an anti-phase tone lost 24 dB of level and wide material was clamped to S/M 1.55 (stereo audit A3). Off is bit-identical to a chain without the stage. Enable it only where an exciter or STL needs the L-R held down; `--verify-receiver` prints its cost on panned programme and L-only tones in either direction.
- **BS.412 MPX Power Limiter** -- required only for regulatory compliance in DE/AT/CH/SE/CZ/SI. NL, US, UK, FR, ES, IT etc. do not enforce BS.412; leaving it off recovers loudness headroom. Two keys: `bs412_enabled` and `bs412_ceiling_dbr`. See "When to leave BS.412 and the Composite Clipper off" below.
- **Advanced Dynamics** -- the default levelling: a single-stage leveller that REPLACES the AGC and Multiband stages (`advanced_dynamics_enabled`, on by default and in every Format Profile; the **Levelling Engine** card on the Sound Overview page). See "Advanced Dynamics" below. Switch to AGC + Multiband only if you want to tune the classic chain by hand.
- **SSB Stereo** -- optional SSB-leaning stereo encoder (`mpx_ssb_stereo_enabled` + `mpx_ssb_stereo_amount`: `Enable SSB Stereo` and `SSB Amount` in percent on the dedicated `Stereo Coder` page in both UIs, between Audio Limiter and Composite Clipper -- chain position of the stereo encoder itself). Leans the 38 kHz L-R subcarrier toward single-sideband, always keeping the LOWER sideband (23-38 kHz) like Orban's and Stereo Tool's SSB modes; `amount` 0 is plain DSB, 1 is full SSB, and the two sideband gains always sum to 1 so an ordinary decoder sees the same L-R. The benefit is a narrower RF spectrum with 38-53 kHz freed (multipath and RDS protection), NOT loudness: by construction SSB reclaims no composite headroom and costs up to +3 dB of composite peak on 90-degree L/R programme (+1.6 dB at the default amount 0.7), and a receiver whose 38 kHz reference is 10 degrees off decodes about 21 dB of separation with it on against 42 dB without. Mono-transparent, bit-identical when off. `--verify-ssb-stereo` pins the kept sideband, the phase-error cost and the peak cost. Until 0.65 the stage switched sidebands "opportunistically" between two candidates that have identical envelopes, so the choice was random and the kept sideband wandered. Leave it off unless you field-test it on real receivers.

This is a sensible amateur-grade starting point. Tune from there based on listening A/B against your typical programme material. Heavier formats (CHR, EDM, dance) may benefit from PrimeBass + Bass Clipper on; talk-heavy or classical formats may want Multiband intensity dropped and Composite Clipper drive reduced.

### Advanced Dynamics keys

`advanced_dynamics_enabled` (default `True` since 2026-10-15; every Format Profile turns it on) replaces the wideband AGC **and** the multiband compressor with one fused 5-band levelling stage. The point of the fusion is that slow levelling and per-band density shaping can no longer fight each other (the classic AGC-pulls-down-while-multiband-pushes-up pumping); each band rides toward a target level with programme-adaptive speed -- near-instant on transients, frozen when the band already sits at target, slower on dense material. You configure the sound you want instead of attack/release times:

- `advanced_dynamics_target_db` (default `-16.0`) -- the wideband level the programme is brought toward. Every Format Profile sets it to its AGC target, which matches the classic chain's loudness into the final stage within the 3 dB the A/B gate allows; the two profiles that run PrimeBass (Music - Loud and Music - Dense) set it 2 dB below, which keeps PrimeBass intermodulation under the `--verify-primebass` limit and costs them no peak level. Until 2026-10 every profile was 2 dB below, and the leveller came out 4 dB quieter than the classic chain on dense programme.
- `advanced_dynamics_low_offset_db` / `advanced_dynamics_mid_offset_db` / `advanced_dynamics_high_offset_db` (defaults `0 / 0 / 0`, range -6..+6 dB) -- a tonal TILT relative to the programme's own balance; the 5 bands interpolate between them. 0 everywhere leaves the programme's spectrum as it is.
- `advanced_dynamics_max_gain_db` (default `12.0`) -- maximum lift for quiet programme (the reduction side is fixed at 24 dB). The default was lowered from 18 after field testing: high boost both chases natural fades harder and lowers the silence gate (`target - max_gain - 10 dB`), pumping tails on sparse material. Raise it deliberately for wide-dynamics formats.
- `advanced_dynamics_density` (`0..1`, default `0.5`) -- denser = tighter hold window and faster levelling. Independently of the knob, the release slows itself on already-dense programme (up to 2.5x at zero fast/slow envelope divergence) and runs at full speed on sparse, dynamic programme; until 0.65 the code had this backwards.
- `advanced_dynamics_speed` (`0.25..4`, default `1.0`) -- overall time-constant scale.

How it levels (since 2026-10-15). One wideband gain, measured on the whole programme, carries the loudness and all the adaptive ballistics. Each band then adds a slow correction for a SHORT-TERM departure from its own long-term share of the programme (an 8 s memory), bounded to +3 / -3 dB (-6 dB on the two top bands, which may cut in 5 ms to tame sibilance and cymbal bursts), plus the tilt above. A steady programme therefore keeps its spectrum and, because each band applies one gain to both channels, its stereo image. The earlier law levelled every band to an absolute target: it re-equalised all programme toward one spectrum (up to +10 dB on a single band) and on dense bass cut the correlated bass against lifted upper bands, dropping L/R correlation from 0.90 to 0.74.

A built-in **decay guard** distinguishes "programme actively fading" from "programme is quiet": while the programme's envelope sits well below its recent peak (a note or song decaying naturally), the leveller holds instead of lifting, resuming when the level stabilizes or new material arrives. Without it a solo decaying sound (a bell, a fade-out) gets its fade flattened and extended -- heard as added ringing/sustain.

Band layout follows `multiband_x1_hz..multiband_x4_hz`. All keys are live-apply. When the stage is enabled the AGC and Multiband settings are ignored (those stages are bypassed); when it is disabled the chain is bit-identical to before the stage existed. It is evaluated with `--verify-advanced-dynamics`. A profile carries its levelling character into the stage: its AGC target becomes the leveller target (2 dB lower with PrimeBass on), its multiband intensity the density (light 0.35, normal 0.5, heavy 0.7).

In both front ends the stage is one of two **Levelling** engines, chosen in the **Levelling Engine** card on the Sound Overview page (GUI and web dashboard alike): **Advanced Dynamics** (the default) or **AGC + Multiband** (the classic chain, with the per-band Expander and Band Limiter that run inside the multiband stage). The choice IS `advanced_dynamics_enabled` and applies live. The pages of the engine not in use are hidden -- sidebar, Overview grid, Monitoring signal chain and pill strip -- so there are no dimmed panes to scan past (until 0.65 they stayed visible, ghosted, behind a "bypassed" banner); if one of them was open, the app shows the Overview instead. The Advanced Dynamics page has no enable toggle of its own; the selector is the switch. Its band layout follows the Multiband page's crossovers; switch to AGC + Multiband to edit them.

While the stage is active, the Monitoring dashboard's Signal Chain "AGC" pill switches identity to **Adv Dyn** and reads the leveller's density plus its five per-band gains (low to high, dB); the web dashboard's Headroom card gains the matching "Adv Dynamics" row. The AGC readouts honestly report the AGC as Off (gain 0.0) while it is bypassed -- the leveller replaces it, so a moving "AGC gain" would be stale telemetry. Over the API the same values are `advancedDynamicsActive`, `advancedDynamicsBandGainsDB` (5 floats, low to high), and `advancedDynamicsDensityDB` in `GET /api/meters` (null while the stage is off).

The stored AGC, Multiband, Expander and Band Limiter settings are untouched while Advanced Dynamics is selected -- switching back restores the exact previous behaviour. A test pins the replacement as total: with the leveller on, extreme AGC/multiband settings produce bit-identical output to having those stages off.

### Operating mode

`operating_mode` (`[INTERFACES]`, default `mpx`, restart-class) is the single
key that says what leaves the output device. Everything mode-conditional in
the engine and in both interfaces is derived from it through
`ChainFeature` -- there is no second spelling.

| Value | Output | What is switched off |
| --- | --- | --- |
| `mpx` | FM composite: pilot + stereo subcarrier + RDS | nothing |
| `fm` | FM-shaped stereo L/R for an external coder | stereo coder, composite clipper, BS.412, final MPX stage, RDS, monitor |
| `hd` | flat full-bandwidth L/R with a true-peak ceiling | the above, plus pre-emphasis (forced to 0 for the render), stereo-image protection and the optional final clipper |
| `am` | mono NRSC-shaped feed with asymmetric peaks | the above, plus the FM pre-emphasis picker (AM has its own) |

Outside `mpx` the RDS encoder does not run whatever `en_rds` says, the Now
Playing script is not polled, and the SSB stereo option cannot reach the
chain -- a control with no function is inert, not merely hidden. The same rule
hides a few keys inside a mode: Mono Mode, Mono Bass and the multiband
`Stereo Link` disappear in `am` (the chain is mono before them), and the whole HF
limiter disappears in `hd` (it rides the pre-emphasis boost, and `hd` is
flat). They keep their stored values and come back with the mode.

A pre-0.50 INI carrying `processed_audio_output` / `processed_audio_target` is
migrated on load and rewritten to `operating_mode` on the next save. The REST
API still accepts both old keys and resolves them onto the mode, in any order.

### Sound card level (`GET` / `PATCH /api/mixer`, `card_*_volume_db`)

The live readings are not INI values: they are the DEVICE's own volume
controls, owned by the OS and shared with anything else on the machine, so the
encoder reads them live and never stores the readings. They exist in the API
because that level sits between the encoder and the exciter and a slider a few
percent under unity costs composite level that no meter in the app can show.
On Linux the controls are the output card's ALSA simple-mixer elements (the
rig lost 2 dB to a card knob after a reboot); on macOS they are the output
device's CoreAudio volume and the input device's input volume (the station's
DX3 Pro+ DAC sat at -5 dB while the app also applied -5 dBFS line output, and
nothing in the app could see it). The GUI shows the same two rows on the
`Audio I/O` tab as Device Output Level / Device Input Level with a Set to 0 dB
button.

`GET /api/mixer` answers `{available, card, controls[], note, ...}`; each
control carries `name`, `index`, and, per side, `playbackPercent` /
`capturePercent` (the slider position), the device's own `playbackDB` /
`captureDB` when it reports a dB scale, and the mute state. On macOS the
output device is one control named after the device with `playbackPercent`,
the input device one with `capturePercent`, and the payload adds
`playbackDeviceName` / `captureDeviceName`, the dB ranges `playbackRangeDB` /
`captureRangeDB` (`{minDB, maxDB}`), `playbackSettable` / `captureSettable`
and `playbackDBEstimated` / `captureDBEstimated` (true when the device has no
dB scale and the dB is derived from the slider position). A device without a
volume control (BlackHole) is left out and named in `note`; `note` also
carries the warning for an output below -0.1 dB or muted. When no device has
a control, and on Linux when the output device is the plain ALSA `default`
rather than a named card, `available` is false with a `note` explaining why --
that is a normal `200`, and the dashboard hides its Sound Card Mixer card on
it.

`PATCH /api/mixer` takes `{name, index?, playbackPercent?, capturePercent?,
playbackDB?, captureDB?, playbackMuted?, captureMuted?}` and moves only the
fields present (a dB field wins over the percent for the same side; `name` is
the control name on Linux and the device name on macOS), then answers with a
fresh READ so the operator sees the level the device actually took. A control
the device does not have, or a name that is not the device's, is a `400`.

Keep the output control at 0 dB and calibrate in the encoder with
`output_gain_db` / `mpx_line_output_dbfs`.

A `PATCH` also RECORDS the level the device took, in dB, as
`card_playback_volume_db` / `card_capture_volume_db` (`[INTERFACES]`, empty =
unmanaged, remembered with the installation, never a dashboard widget of their
own; on Linux the card's first playback or capture control, on macOS the
output or input device). The engine then ASSERTS those levels at start and
on every 5 s reconcile tick (the GUI runs the same tick while the engine
runs), logging a correction when something moved them, and unmutes a managed
output. That is deliberate: a level that is only stored cannot beat a hardware
knob or another application; asserting can. To hand the device back to the OS,
blank the two keys. A new installation leaves both unmanaged; while the output
device sits below -0.1 dB or muted at engine start, the status notes say so.
The pre-0.65 names `alsa_playback_volume_db` / `alsa_capture_volume_db` are
aliases of the same two values: an old INI loads, the INI is written under
both spellings, and a `PATCH /api/config` of either spelling lands on both.

Related Linux facts: `blocksize` is the ALSA period on this platform (the
buffer keeps at least 8 periods and 8192 frames); the render thread runs
`SCHED_FIFO 70` and `/api/status` `notes` carries the reason when it could
not (the unit grants `LimitRTPRIO=70` + `CAP_SYS_NICE`); and
`mpxprime --version` prints the version and exits.

### Device channels (multichannel interfaces)

An interface with more than two channels needs to know which of them carry
the signal. Each device key has a channel key beside it in `[INTERFACES]`:

| Key | Picks | Disposition |
|---|---|---|
| `input_channels` | the input channels the programme comes in on | restart-class |
| `output_channels` | the output channels the transmitter feed (or processed feed) goes out on | restart-class |
| `monitor_channels` | the output channels the Monitor plays on | live-apply |

The value is one or two device channel numbers, counted from 1 as the
interface labels them: `3,4` is a stereo pair with the lower number as left,
and `5` alone is mono on that channel. Empty, the default, means `1,2`, and
the app writes `1,2` back as empty. Order does not matter, so `4,3` is read
as `3,4`. A mono output carries the left channel of the feed, which in MPX
Output is the whole composite; a mono Monitor plays left and right summed.
A mono input feeds that one channel to both sides of the chain.

If the chosen channels are not on the device, for example `7,8` on a
two-channel card, the engine uses `1,2` instead and says so in the status
line. Like the device keys, the channel keys belong to the installation: a
reset keeps them, and presets and snapshots never carry them. The Linux
encoder reads the keys but ignores them; pick channels there with an ALSA
`route` plugin in `.asoundrc` and name that PCM as the device.

### Monitor output

The Monitor is a SECOND output device that plays what the box is putting out,
running alongside the transmitter feed in every operating mode. See the
Operator Guide for what it plays per mode.

- `monitor_enabled` (`[INTERFACES]`, default `False`, live-apply): start or
  stop it. Never interrupts the transmitter feed.
- `monitor_device_uid` (`[INTERFACES]`, live-apply): which device it plays on.
  Empty means the Monitor stays off -- it deliberately does NOT fall back to
  the system default, because that default may be the transmitter output. It
  never shares the MPX output's channels: on the same device it runs only
  when `monitor_channels` and `output_channels` do not overlap.
- `monitor_gain_db` (`[INTERFACES]`, default `0.0`, range -40..+6, live-apply):
  its level. Affects nothing on air; boosts above 0 dB are clamped so a hot
  monitor cannot fold over in the converter.

All three apply live, including moving the Monitor to another device: only its
own player restarts. The keys are remembered with the installation, so a
snapshot never carries someone else's monitor rig. On Linux
`monitor_device_uid` is an ALSA PCM name (`hw:CARD=Loopback,DEV=0`, as the
dashboard's device list shows it) and the same rules apply; `default` is
refused whenever the transmitter is on `default` too.

### AM output shaping

- `bs412_enabled` (`[MPX]`, default `False`, live-apply): the ITU-R BS.412-9
  multiplex-power limiter. The MEASUREMENT runs whenever a composite is
  rendered, so enabling this acts on a window that is already full.
- `bs412_ceiling_dbr` (`[MPX]`, default `0.0`, range -10.0 to 0.0,
  live-apply): the ceiling in dBr, where **0 dBr is the Recommendation's own
  limit** -- the power of a sine causing 19 kHz deviation. A negative value is
  an operator margin below the limit, not a different limit. The quantity
  controlled is the average power of the COMPLETE multiplex, pilot and RDS
  included, over any 60 seconds; the window is fixed at 60 s because nothing
  else is BS.412. The controller reduces the audio path only, and reports an
  unachievable configuration rather than attenuating pilot or RDS. Control is
  two stages: a transparent gain ride that predicts from the incoming audio,
  and behind it an exact energy budget that holds EVERY 60-second window at
  or under the ceiling, including the first one and the ones spanning a
  programme change. Settling is deliberately unhurried; the quantity is a
  one-minute average and cannot be corrected faster than it is measured.
  Reported through `/api/meters` as `bs412PowerDBr` (with `bs412PowerValid`,
  `bs412SecondsObserved`, `bs412GainReductionDB`, `bs412OverCeiling`,
  `bs412Unachievable`, `bs412GuardActive`, `bs412ControlSuspended`).

`/api/meters` also carries `nonFiniteInputSamples`: how many NaN / Inf
input samples the DSP ingress guard has replaced with silence since the
engine started. Zero is the normal reading.
  Replaced `bs412_threshold_db` and `bs412_window_seconds` in 0.65. The old
  threshold was dB relative to normalised full-scale power, a scale on which
  its default of -10 meant roughly +4.9 dBr -- above the limit it claimed to
  enforce -- so there is no honest numeric conversion: an INI carrying either
  old key adopts the standard's 0.0 dBr ceiling on load, the encoder says so
  once (status bar in the app, the log on Linux) and saves the INI, so the old
  keys disappear from the file and it matches what runs.

Read only when `operating_mode = am`:

- `am_preemphasis_us` (`[MPX]`, default `75`, values 0 or 75, restart-class):
  NRSC-1 pre-emphasis, or flat when the transmitter already applies it. The
  `75` names the standard, not the FM time constant: NRSC-1-C is the
  MODIFIED 75 us curve, with a pole at 8700 Hz as well as the zero at
  2122 Hz, so it reaches +10.00 dB at 10 kHz instead of the FM curve's
  +13.66 dB. The Monitor removes this curve, not the FM one.
- `am_lowpass_hz` (`[MPX]`, default `10000`, range 3000-10000, restart-class):
  audio bandwidth of the AM feed. NRSC-1 specifies 10 kHz.
- `am_positive_peak_pct` (`[MPX]`, default `125`, range 100-125, live-apply):
  asymmetric modulation per 47 CFR 73.1570. The NEGATIVE side is held at
  100/pct of full scale and positive peaks may use the rest, so the
  transmitter is calibrated on the negative peak. At 100 the feed is
  symmetric. Held by the same peak guard the digital ceiling uses.

Left and right are summed before the processing chain, so every stage acts on
the signal that goes on air, and both output channels carry the mono result.

`processed_audio_ceiling_dbtp` (`[MPX]`, default `-1.0`, range -6..0,
live-apply) is the true-peak ceiling for the digital target. Two stages
hold it: the pre-encode limiter's ceiling is mapped onto this value (less a
0.1 dB margin), and a stereo-linked true-peak guard after the output make-up
rides a 4x reconstruction detector with 2 ms look-ahead, ramping its gain
smoothly over the look-ahead instead of stepping it, because the
limiter's post-clip decimation filter rings on hard transients and its output
alone read up to 1.4 dB over the ceiling on a click programme. The guard is a
pure 2 ms delay below the ceiling and never clips. Measured delivery on
bright, hard-panned and click programmes lands within 0.05 dB of the requested
figure (`digitalTargetTruePeakHoldsOnAdversarialProgram`,
`TruePeakGuardTests`). The same guard runs in `fm`, where the make-up maps
the limiter ceiling to full scale and the guard holds it (2 ms of extra
latency), so dense programme never reaches the hard clamp. The pre-encode
limiter's 4x interpolator is a linear-phase Kaiser FIR, flat to 0.001 dB;
until 2026-10 it was a one-sided Lagrange that rippled +0.32 dB at fs/4.

### Composite deviation and the pilot / RDS reservation

`mpx_deviation_khz` (`[MPX]`, default `75.0`, slider 40-90, the INI accepts
25-100, live-apply; GUI: Audio I/O > Output > "Composite Deviation", MPX
Output only) is the PEAK target of the complete multiplex, pilot and RDS
included. Composite amplitude 1.0 is 75 kHz at every setting, so below
75 kHz the whole budget scales with it: at 50 kHz the multiplex peaks at
50 kHz (the verifier's worst peak is 47 kHz; until 2026-10 it reached
71 kHz, because only the drive and the subcarrier amplitudes followed the
setting). Above 75 kHz the budget stays at full scale, the hard bound of
the digital domain.

The audio composite gets what is left after the pilot / RDS reservation,
which is the nominal on-air peak of each service: `pilot_level` of the
deviation plus `rds_level` in kHz. Pilot and RDS therefore fit at every
allowed setting (pilot 12 % with RDS at 7.5 kHz used to overshoot to
75 kHz and clip both); at the defaults the audio sits about 0.3 dB lower
than before. A service that goes off-air releases its reserve over a few
seconds instead of stepping the budget. The `compositeBudgetMarginDB` readout
in `/api/meters` (`Composite Budget` in the app) is still measured against 75 kHz, so at a
50 kHz setting it reads about 4 dB with the clipper at work.

### MPX line output calibration (dBFS)

`mpx_line_output_dbfs` ([MPX], default `0.0`, slider range -40..0 (the INI accepts down to -60), live-apply; GUI:
Audio I/O > Output > "Line Output", remembered per output device; also on the web dashboard) sets the
ABSOLUTE converter level of 100% modulation: at `-12.0`, a 75 kHz-deviation
composite peaks at -12 dBFS on the output interface. It is applied at the
DAC write, after every processing stage and meter tap -- on both the live
input and the test tone since 0.50, where a bug that limited it to the tone
was fixed -- so deviation readouts,
the composite budget, and all internal levels keep the classic
0 dBFS = 100% convention. Use it to match an exciter's input sensitivity
once, in software: keep the operating system / interface output volume at
0 dB (a mixer attenuation scales pilot and RDS injection along with the
audio, and an accidental 0% mixer silences the transmitter -- calibrate
here instead). `output_gain_db` remains the in-chain MPX level trim that
participates in the composite budget -- and since 0.45 it is **attenuation-only in composite mode** (clamped to <= 0 dB on load; the slider stops at 0): a positive value divided the whole budget by the gain, so the audio composite was clipped deeper while pilot and RDS went on air above their configured injection and nothing got louder (the governor caps the composite regardless). The processed-audio output keeps the full range; the line output is pure output-stage
calibration -- attenuation only. Positive line gain is deliberately not
offered because it is unphysical at a DAC: full scale is the hardware
ceiling, so "+3 dBFS" cannot raise the peak voltage your exciter sees.
All it can do is lift everything below the clamp (pilot 8% becomes 11.3%,
RDS likewise) and clip the summed composite during audio peaks --
momentarily clipping pilot and RDS, which must stay constant-amplitude.
The field symptom is characteristic: deviation looks right (peaks still
stop at full scale) while pilot and RDS read ~3 dB high. If your exciter
under-deviates with the line output at 0.0 dBFS, correct it on the analogue
side: trim the exciter's input sensitivity so full scale equals 75 kHz,
and pilot/RDS return to their configured injection automatically.

## RDS text syntax

MPX Prime Studio accepts the same RDS text grammar as Stereotool for PS, PTYN, Long PS, and Radiotext fields. Unsupported markers are accepted silently where practical so existing Stereotool presets load without modification.

| Marker | Meaning |
| --- | --- |
| `Ns:TEXT` | Timed segment, `N` seconds. Fractional accepted (`1.5s:`). |
| `Nt:TEXT` | Transmit-count segment. Advances after `N` full transmissions of the field. |
| `/` | Separates repeating segments. |
| `<TEXT` / `>TEXT` | Scroll left / right. **PS only** -- too slow to be useful on Radiotext. Repeat the marker for more chars per tick: `<<TEXT` scrolls twice as fast. |
| `\|\|` | Word-wrap toggle. Word-wrap is always on; accepted as a no-op. |
| `\\<`  `\\>`  `\\\|`  `\\:`  `\\/`  `\\\\` | Escape the special character so it transmits literally. |
| `\R"path"` / `\r"path"` | Load file contents (uppercase / as-is). |
| `\F"path"` / `\f"path"` | Aliases for `\R` / `\r`. |
| `\w"url"` | Fetch text from a URL. MPX Prime Studio extension, not in Stereotool. |

Example mixing timing modes and separators:

```text
1.5s:MPX Prime Studio/3t:In STEREO on RDS/10s:Now: {artist} - {title}
```

Scrolling PS marquee (PS is 8 characters wide):

```text
<<MPX PRIME - FM BROADCAST ENCODER
```

Escape a colon so it is not parsed as a timing prefix:

```text
Visit us\: https\://example.com/10s:Alt text
```

**Character set.** RDS fields go on air in the EN 50067 basic character
table, which is essentially ASCII. Every text field -- typed in the GUI, read
from the INI, pushed over the REST API, or produced by the Now Playing script
-- is folded before framing, in this order: Unicode NFC (so a decomposed
`e` + accent behaves like `e-acute`), typographic punctuation to its ASCII
form (curly apostrophes and quotes to `'` / `"`, en/em dashes to `-`, the
ellipsis to `...`, non-breaking and thin spaces to a space, `x` for the
multiplication sign, `(c)` for the copyright sign), then accents stripped
(`Cafe del Mar`, `Bjorn`, `ss` for the German sharp s); `O` with stroke is
sent as its own RDS code. Anything with no Latin form (CJK, Cyrillic, emoji)
becomes `?`. Before 0.50 the punctuation step was missing and a curly
apostrophe in a track title reached receivers as `?`.

Important defaults:

- High-Pass Filter default: `30 Hz`
- Programme Lowpass default: `16.0 kHz` (`program_lowpass_hz`)
- Scope auto gain default: enabled

## Now Playing script output

The RDS Radiotext section can poll an external script for now-playing metadata.

A ready-to-use example poller ships with MPX Prime Studio, in the DMG's
`Now Playing Scripts/` folder and inside the app at
`MPX Prime Studio.app/Contents/Resources/Scripts/`:

- `nowplaying.sh` -- auto-detects the running player and reads its metadata via
  AppleScript: **VLC** (current item, only while playing) first, then
  [**Cog**](https://github.com/losnoco/cog) (current entry via its `currentEntry`
  dictionary). Note: Cog exposes no play/pause state, so it reports the loaded
  track even while paused (it clears the entry on Stop). The shared title cleanup
  and output formatting are written once; only the per-player fetch differs, so use
  it as a template for another player by adding one fetch function.

The script strips parenthetical `(Radio Edit)` / `(feat. X)` and bracketed
`[Official Video]` / `[Remastered]` decorations from the title -- they routinely
push the RadioText / PS over length, e.g. `Song Title (Radio Edit) [Official Video]`
becomes `Song Title`. Both are **on by default**; set `STRIP_TITLE_PARENS=0` and/or
`STRIP_TITLE_BRACKETS=0` in the script's environment to keep them. If stripping
would empty the title, the original is kept.

Copy it somewhere stable (for example your home folder) and point the
Radiotext now-playing script setting at it. The first run prompts once for
Automation permission to control the player.

How the script is launched: an executable file runs directly, so its own
`#!` line picks the interpreter; a file without the execute bit runs through
the first of `/bin/zsh`, `/bin/bash`, `/bin/sh` that exists on the machine
(stock Ubuntu has no zsh, so a Linux script should say `#!/bin/sh` or
`#!/bin/bash`). A path that does not exist is reported as `script not found`
-- the usual cause is a macOS path in a config copied to a Linux box. The
poller reports a result when it CHANGES (new track, recovery, a different
failure), not on every poll.

Expected script behaviour:

- Exit with status `0` only when active playback metadata is available
- Write metadata to `stdout`
- Plain single-line output is accepted and treated as the display text
- Structured `key=value` lines are preferred for correct RT+ tagging

No-data behaviour:

- Exit with status `1` when no song is currently playing or no usable metadata is available
- MPX Prime Studio treats `exit 1` and empty output as `No Song Data`
- Any RT segment containing `{now_playing}`, `{display}`, `{artist}`, or `{title}` is discarded entirely when no song data is available
- This works for both slash-separated timed RT and consecutive timed markers

Supported keys:

- `display`: full on-air text, for example `The Dizzy DJ - I Venti Megamix`
- `artist`: artist field for RT+
- `title`: title field for RT+
- `now_playing`: alias for `display`

Example script output:

```text
display=The Dizzy DJ - I Venti Megamix
artist=The Dizzy DJ
title=I Venti Megamix
```

Example Radiotext / RT+ settings:

```text
Radiotext: 10s:In STEREO on RDS/10s:Now: {artist} - {title}
```

If the script reports no song data, the transmitted RT falls back cleanly to:

```text
10s:In STEREO on RDS
```

When the now-playing script is enabled, RT+ tags are derived automatically from structured script output (`artist`, `title`, `display`). There is no separate RT+ format field to maintain for this workflow.

Available Radiotext macros:

- `{now_playing}`
- `{display}`
- `{artist}`
- `{title}`
- `{date}` as local date in `YYYY-MM-DD`
- `{time}` as local time in `HH:mm`

## REST API

The control server is enabled and secured as described in the Operator
Guide's [Operating it from a browser](studio-operator-guide.md#operating-it-from-a-browser)
section. The endpoints below are what the dashboard itself uses.

### Endpoints

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/status` | running state, platform, version, the sample rate the engine RENDERS at (on macOS the device's rate, which can differ from `sample_rate` -- a `notes` entry says so when it does), uptime, restart-pending; `outputMode` is the operating mode (`mpx` / `fm` / `hd` / `am`); `monitorActive` says whether the Monitor output is playing; `notes` carries routing and health notes, including "Render load at or over 98 %..." when the chain does not fit the CPU (see the operator guide's CPU budget section) |
| GET | `/api/meters` | levels, gain reduction, pilot/RDS injection %, deviation (modulation-domain: output/line trims divided back out; on the fixed scale where composite amplitude 1.0 is 75 kHz, so it is right at any `mpx_deviation_khz`) + `dacPeakDBFS` (electrical: post-trims at the converter; the peak figures are peak-holds that fall about 6.6 dB per second of wall-clock time, so a slow poller reads the hold, not the instant), budget margin, Advanced Dynamics leveller gains when active, (macOS input source) input-ring health, and on Linux `renderXruns` / `captureXruns` plus `renderLoadPercent` -- the worst share of one period the render thread needed in the last ~43 ms; near 100 % xruns follow |
| GET | `/api/meters/stream` | the same object pushed as one JSON line per frame (NDJSON, `application/x-ndjson`) at `?hz=` 5..30 (default 20) for as long as the client reads; `&frames=N` ends it after N lines (`curl -N -H "X-API-Key: ..." "http://host:8737/api/meters/stream?hz=10&frames=5"`). While the engine is stopped the stream sends 2 lines a second whatever `hz` asks. Each stream has its own peak readings, so two clients (or the GUI and a client) never take each other's peaks; plain `/api/meters` polls share one reader. The dashboard's meters read this and fall back to polling `/api/meters` every 300 ms when it is unavailable, and pause the stream and all polling while the tab is hidden |
| GET | `/api/rds` | on-air PS/RT snapshot + PI/PTY/TA/TP and configured text |
| PUT | `/api/rds` | curated update: `{"ps": ..., "rt": ..., "ta": true, "pty": 8, "pi": "83E1", "tp": ..., "enabled": ...}` -- applies live; `ps` writes bank A |
| GET | `/api/config` | every INI setting, grouped by section |
| PATCH | `/api/config` | `{"<ini_key>": "<value>", ...}` -- any key from this manual's tables |
| GET | `/api/schema` | the dashboard's control schema: widget definitions (label/range/unit) + page model for every exposed INI key -- the single source the web UI renders from |
| GET | `/api/config/defaults` | factory defaults, grouped like `/api/config` -- diff against it for "reset to defaults" |
| GET | `/api/presets` | available preset IDs by kind (primebass / multiband / finalstage / format_profile -- all kinds on BOTH backends since 0.44; the widener kind left with its stage in 0.50) |
| GET | `/api/telemetry` | live scope waveforms + MPX spectrum (display-decimated, ~6 KB; `?window_ms=` picks the scope timebase); 503 while stopped or on a platform without a scope tap |
| GET / PATCH | `/api/mixer` | the sound card's own level controls, read live from the device: ALSA simple-mixer elements on Linux, the output / input devices' CoreAudio volume on macOS (since 2026-10). A `PATCH` moves one side (`playbackPercent` / `capturePercent`, or `playbackDB` / `captureDB`, which win), answers with a fresh read and records the level as `card_*_volume_db`, which the engine then asserts at every start and every 5 s. See "Sound card level" above |
| GET | `/api/devices` | the machine's audio devices (CoreAudio / ALSA) with the selected input, output, AND monitor slots (`selectedMonitor` + `monitorEnabled` since 0.44) |
| POST | `/api/nowplaying` | push the current track: `{"artist": ..., "title": ..., "display": ...}` -- feeds the RT / PS / RT+ templates (see "Now-playing push" below) |
| GET | `/api/snapshots` | the 8 operator preset slots (name, saved-at, active/modified) -- shared with the native GUI's Presets sidebar |
| POST | `/api/snapshots/N/save`, `/load` | capture the current config into slot N (body `{"name": ...}` optional) / apply slot N as one full config patch |
| PATCH / DELETE | `/api/snapshots/N` | rename / clear slot N |
| GET | `/api/snapshots/N/export` | the slot's full INI text (doubles as a `--config` file) |
| PUT | `/api/snapshots/N` | import INI text into slot N (body `{"name": ..., "ini": "..."}`) |
| POST | `/api/presets` | `{"kind": "multiband", "id": "3_chr", "intensity": 1.0}` (intensity <0.75 light / >1.25 heavy) |
| POST | `/api/transport/start\|stop\|restart` | engine lifecycle |

`PATCH /api/config` responds with a per-key **disposition**: `live` /
`liveRDS` (hot-applied to the running engine, no restart), `restartRequired`
(saved; takes effect at the next start -- e.g. `rds_level`,
`sample_rate`, devices), `none` (saved and acted on by the backend itself
without a restart -- the sound-card level keys `card_playback_volume_db` /
`card_capture_volume_db` and their `alsa_*` aliases, asserted on the device at
once), or `unchanged`
(value identical after clamping/parsing, or unknown key). The classification is derived from the
same runtime structures the engine hot-applies, so it always matches what
the engine actually does. Every change is saved to the INI immediately.
Values follow INI text conventions (booleans `True`/`False`; no `;` in
values).

When the macOS input source is running, `/api/meters` also reports
capture->render ring health: `inputRingBufferedFrames` (fill level, hovers
near the engine target), `inputRingOverflows` / `inputRingUnderflows`
(input clock faster / slower than render), `inputRingTornReads`,
`inputResampleMode`, and `inputRatioTrim` (the drift corrector's current
adjustment). These are diagnostics for clock-drift between the input and
output devices; steady buffer with zero over/underflows means the bridge is
healthy. They are null in headless/ALSA and when no input source is active.

The now-playing script integration (see RDS) keeps working alongside the
API; automation systems that only need RT/PS updates can use `PUT /api/rds`
instead of a polling script.

### Now-playing push (remote RadioText)

Feed the current track to the encoder over the API instead of a local script --
useful when the player and the encoder are on different machines (players on
your Mac, encoder headless on a Linux box).

`POST /api/nowplaying` with `{"artist": "...", "title": "...", "display": "..."}`
(display optional; defaults to "Artist - Title") writes the same now-playing
state the local script feeds, so your RT / PS / RT+ templates fill in and RT+
artist/title tagging works. The response `{"ok":true,"nowPlayingEnabled":bool}`
reports whether rendering is on.

Setup on the encoder (once): set `now_playing_enabled = True`, an `rt_text`
template using the macros -- e.g. `10s:{artist} - {title}/10s:My Station` --
and leave `now_playing_script` empty (the push is the source). A `/`-segmented
template shows the static segment when nothing is playing; a line whose
`{artist}`/`{title}` is missing is skipped rather than aired half-filled.

From a source checkout on macOS, `scripts/dist/push-nowplaying.sh` does this for
VLC and Cog:

```bash
scripts/dist/push-nowplaying.sh --url http://encoder-host:8737 --api-key <key>
# or: MPXPRIME_URL=... MPXPRIME_API_KEY=... scripts/dist/push-nowplaying.sh --interval 5
```

It reuses `scripts/dist/nowplaying.sh` for extraction and pushes only on track
change (no RadioText thrash), clearing the track when playback stops.
