# MPX Prime Studio -- Settings and API Reference

Configuration keys, the processing-stage settings, the RDS text grammar, the
now-playing script protocol and the REST API. For installing the encoder,
setting levels and day-to-day operation, start with the [Operator
Guide](studio-operator-guide.md).

## The configuration file

> **Linux (experimental CLI port):** the encoder also runs headless on Linux
> (`--nogui`; no GUI, no Meter). The same INI works, with two differences:
> the default config path is `~/.local/share/MPX Prime Studio/MPX Prime
> Studio.ini`, and the `input_device_uid` / `output_device_uid` keys hold
> ALSA PCM names (`default`, `hw:0,0`, `plughw:...`) instead of CoreAudio
> UIDs. See docs/BUILDING.md "Linux (CLI-only)" for setup and device notes.
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

- `INTERFACES`: input/output/monitor device UIDs, source mode, monitor enable, block size
- `MPX`: processing, levels, stereo coding, limiter behavior
- `RDS`: program service, radiotext, flags, carrier settings

## Processing stages: what to enable and what each key does

For typical FM broadcast use (clean / community / LPFM), the recommended set of processing stages to **enable** is:

- **Phase Rotator** -- voice waveform symmetrization (f ~ 200 Hz)
- **Wideband AGC** -- long-term level riding (target ~ -14 dBLU, range +/-10 dB, K-weighted, program-dependent release, 150 ms attack -- a gain rider that leaves transients to the limiters; the 6 ms attack of earlier builds ducked the whole mix on every drum hit)
- **Parametric EQ** -- 4-band tonal shaping (shelf + 2 peaks + shelf)
- **Multiband Compressor** -- 3-band LR4 (or 5-band FIR on TX path); the `5_jazz` preset is a balanced starting point for mixed music + speech
- **Downward Expander** -- gates noise floor (threshold ~ -45 dB, ratio 2.0:1)
- **MB Limiter** -- per-band peak control (threshold ~ -3 dB, atk 0.5 ms, rel 50 ms)
- **DC Clipper** -- distortion-cancelled audio-band clipping with pilot/RDS protection
- **HF Limiter** -- pre-emphasis-aware, gain-riding HF control (`Processing` -> `HF Limiter / Clipper`; `hf_limiter_enabled`, `hf_limiter_threshold_db` -2 dB, `hf_limiter_attack_ms` 1.5, `hf_limiter_release_ms` 20, `hf_limiter_max_reduction_db` 12). On by default in every Format Profile (0.45). It rides only the pre-emphasis *boost*: a cymbal or hi-hat that overshoots after pre-emphasis briefly loses part of its boost instead of being clipped or dragging the whole mix down in the Audio Limiter, and it can never cut HF below the flat (un-emphasised) program level. Bass-driven peaks with little HF boost are ignored, so a kick cannot flutter the highs. The receiver's fixed de-emphasis turns the action into a brief, bounded HF dip -- the trade every broadcast HF limiter makes (Optimod topology). Threshold: set at or a little below the Audio Limiter threshold. All controls live-apply. Measured with `--verify-hf-transients`: on Music - Loud it keeps the decoded hi-hat SINAD at 18 dB where the HF clipper gave 12 dB. Note that a separate, fixed 2 dB "encoder HF guard" ahead of the encoder lowpass stays in the chain: measurements showed it protects receiver-side HF stereo separation (composite-clipper IM) at levels where this limiter does not engage.
- **Audio Limiter** -- pre-encode L/R true-peak limiter with default-on Phase 1 + Phase 2 look-ahead (Dolby `US 5,579,404`, HF-subband-aware) -- see 0.30 CHANGELOG
- **Composite Clipper** -- 16x oversampled differential composite clipper (threshold -1.0 dB, ceiling -0.3 dB, drive 6 dB). Oversampling factor is configurable (`mpx_clipper_oversampling`, default 16): 8 for older hardware that needs the CPU back, 32 for Omnia.9-class spec-sheet parity at roughly double this stage's CPU cost. See the comment block in the sample `MPXPrime.ini` for when each value makes sense.

Recommended **off** by default (enable only when needed):

- **PrimeBass** -- bass-enhancement harmonics; useful for thin source material, but adds harmonic content that competes with the audio composite headroom. Enable per-format.
- **Bass Clipper** -- engage only when LF transients are pushing the chain past the downstream limiters; if PrimeBass is off, usually unnecessary.
- **HF Clipper** -- pre-emphasis-aware HF *clipper* (same tab; `hf_clipper_*`). Off by default and no longer used by any profile: it is a waveshaper on the pre-emphasised high band, so it distorts the cymbals and hi-hats it controls (the 2026-08 field finding). Keep it as a last resort for maximum HF density on dense EDM after the HF Limiter is already on; leave off for talk / classical. Controls live-apply.
- **BS.412 MPX Power Limiter** -- required only for regulatory compliance in DE/AT/CH/SE/CZ/SI. NL, US, UK, FR, ES, IT etc. do not enforce BS.412; leaving it off recovers loudness headroom. See "When to leave BS.412 and the Composite Clipper off" below.
- **Advanced Dynamics** -- experimental single-stage leveler that REPLACES the AGC and Multiband stages while enabled (`advanced_dynamics_enabled`; `Processing` -> `Adv Dyn`). See "Advanced Dynamics" below. Leave off until you have A/B'd it against your tuned AGC+Multiband on your own program material.
- **SSB Stereo Encoder** -- experimental SSB-leaning stereo encoder (`mpx_ssb_stereo_enabled` + `mpx_ssb_stereo_amount`, the dedicated `Stereo Coder` tab/page in both UIs, between Audio Limiter and Composite Clipper -- chain position of the stereo encoder itself). Leans the 38 kHz L-R subcarrier toward single-sideband, opportunistically keeping whichever sideband currently peaks lower. Decode-compatible (coherent separation measured 81+ dB with it on) and mono-transparent, but the loudness benefit is not yet demonstrated on synthetic program -- treat it as a listening experiment, verify with `--verify-ssb-stereo` and a real receiver, and leave it off otherwise.

This is a sensible amateur-grade starting point. Tune from there based on listening A/B against your typical program material. Heavier formats (CHR, EDM, dance) may benefit from PrimeBass + Bass Clipper on; talk-heavy or classical formats may want Multiband intensity dropped and Composite Clipper drive reduced.

### Advanced Dynamics keys

`advanced_dynamics_enabled` (default `False`) replaces the wideband AGC **and** the multiband compressor with one fused 5-band leveling stage. The point of the fusion is that slow leveling and per-band density shaping can no longer fight each other (the classic AGC-pulls-down-while-multiband-pushes-up pumping); each band rides toward a target level with program-adaptive speed -- near-instant on transients, frozen when the band already sits at target, slower on dense material. You configure the sound you want instead of attack/release times:

- `advanced_dynamics_target_db` (default `-16.0`) -- the level every band is brought toward.
- `advanced_dynamics_low_offset_db` / `advanced_dynamics_mid_offset_db` / `advanced_dynamics_high_offset_db` (defaults `0 / -3 / -9`) -- tonal balance anchors relative to the target; the 5 bands interpolate between them (the same low/mid/high anchor scheme the multiband compressor uses).
- `advanced_dynamics_max_gain_db` (default `12.0`) -- maximum lift for quiet program (the reduction side is fixed at 24 dB). The default was lowered from 18 after field testing: high boost both chases natural fades harder and lowers the silence gate (`target - max_gain - 10 dB`), pumping tails on sparse material. Raise it deliberately for wide-dynamics formats.
- `advanced_dynamics_density` (`0..1`, default `0.5`) -- denser = tighter hold window and faster leveling.
- `advanced_dynamics_speed` (`0.25..4`, default `1.0`) -- overall time-constant scale.

A built-in **decay guard** distinguishes "program actively fading" from "program is quiet": while a band's envelope sits well below its recent peak (a note or song decaying naturally), the leveler holds instead of lifting, resuming when the level stabilizes or new material arrives. Without it a solo decaying sound (a bell, a fade-out) gets its fade flattened and extended -- heard as added ringing/sustain.

Band layout follows `multiband_x1_hz..multiband_x4_hz`. All keys are live-apply. When the stage is enabled the AGC and Multiband settings are ignored (those stages are bypassed); when it is disabled the chain is bit-identical to before the stage existed. It is evaluated with `--verify-advanced-dynamics` and must pass program-material A/B plus listening before any preset enables it.

In the GUI the stage lives at `Processing -> Adv Dyn` (sidebar entry "Advanced Dynamics", between Multiband and Expander, with a card on the Processing Overview grid); in the web dashboard it has its own "Advanced Dynamics" page.

While the stage is active, the Monitoring dashboard's Signal Chain "AGC" pill switches identity to **Adv Dyn** and reads the leveler's density plus its five per-band gains (low to high, dB); the web dashboard's Headroom card gains the matching "Adv Dynamics" row. The AGC readouts honestly report the AGC as Off (gain 0.0) while it is bypassed -- the leveler replaces it, so a moving "AGC gain" would be stale telemetry. Over the API the same values are `advancedDynamicsActive`, `advancedDynamicsBandGainsDB` (5 floats, low to high), and `advancedDynamicsDensityDB` in `GET /api/meters` (null while the stage is off).

While the stage is enabled, both UIs ghost the stages it replaces: the AGC, Multiband, Expander, and MB Limiter tabs/cards dim, their controls disable, a "bypassed" banner links back to Advanced Dynamics, and the sidebar/overview enabled-dots show the EFFECTIVE state (off while bypassed). The stored flags are untouched -- disabling Advanced Dynamics restores the exact previous AGC/Multiband behavior. A test pins the bypass as total: with the leveler on, extreme AGC/multiband settings produce bit-identical output to having those stages off.

### MPX line output calibration (dBFS)

`mpx_line_output_dbfs` ([MPX], default `0.0`, slider range -40..0 (the INI accepts down to -60), live-apply; GUI:
Audio I/O > Output > "Line Output", remembered per output device; also on the web dashboard) sets the
ABSOLUTE converter level of 100% modulation: at `-12.0`, a 75 kHz-deviation
composite peaks at -12 dBFS on the output interface. It is applied at the
DAC write, after every processing stage and meter tap -- deviation readouts,
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
under-deviates with the line output at 0.0 dBFS, correct it on the analog
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

- Input HPF default: `30 Hz`
- Program lowpass default: `16.0 kHz` (`program_lowpass_hz`)
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

Expected script behavior:

- Exit with status `0` only when active playback metadata is available
- Write metadata to `stdout`
- Plain single-line output is accepted and treated as the display text
- Structured `key=value` lines are preferred for correct RT+ tagging

No-data behavior:

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
| GET | `/api/status` | running state, platform, version, sample rate, uptime, restart-pending; `outputMode` is `mpxComposite` / `processedAudio` / `monitorAudio` |
| GET | `/api/meters` | levels, gain reduction, pilot/RDS injection %, deviation (modulation-domain: output/line trims divided back out) + `dacPeakDBFS` (electrical: post-trims at the converter), budget margin, Advanced Dynamics leveler gains when active, and (macOS input source) input-ring health (subset on Linux) |
| GET | `/api/rds` | on-air PS/RT snapshot + PI/PTY/TA/TP and configured text |
| PUT | `/api/rds` | curated update: `{"ps": ..., "rt": ..., "ta": true, "pty": 8, "pi": "83E1", "tp": ..., "enabled": ...}` -- applies live; `ps` writes bank A |
| GET | `/api/config` | every INI setting, grouped by section |
| PATCH | `/api/config` | `{"<ini_key>": "<value>", ...}` -- any key from this manual's tables |
| GET | `/api/schema` | the dashboard's control schema: widget definitions (label/range/unit) + page model for every exposed INI key -- the single source the web UI renders from |
| GET | `/api/config/defaults` | factory defaults, grouped like `/api/config` -- diff against it for "reset to defaults" |
| GET | `/api/presets` | available preset ids by kind (primebass / multiband / finalstage / format_profile -- all kinds on BOTH backends since 0.44; the widener kind left with its stage in 0.50) |
| GET | `/api/telemetry` | live scope waveforms + MPX spectrum (display-decimated, ~6 KB; `?window_ms=` picks the scope timebase); 503 while stopped or on a platform without a scope tap |
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
`sample_rate`, devices), or `unchanged` (value identical after
clamping/parsing, or unknown key). The classification is derived from the
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

From a source checkout on macOS, `dist-scripts/push-nowplaying.sh` does this for
VLC and Cog:

```bash
./dist-scripts/push-nowplaying.sh --url http://mpxbox:8737 --api-key <key>
# or: MPXPRIME_URL=... MPXPRIME_API_KEY=... ./dist-scripts/push-nowplaying.sh --interval 5
```

It reuses `dist-scripts/nowplaying.sh` for extraction and pushes only on track
change (no RadioText thrash), clearing the track when playback stops.
