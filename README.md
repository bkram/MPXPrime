# MPX Prime

Version: 0.11

MPX Prime is a native macOS FM composite (MPX) generator written in Swift and SwiftUI. It takes live audio input or a test tone, applies optional broadcast-style processing, generates stereo FM baseband with pilot and optional RDS, and sends MPX plus optional decoded monitor audio to Core Audio devices.

MPX Prime is experimental and not suitable for production broadcast use. It targets core behavior from EN 50067 / IEC 62106 and common FM stereo practice, but it is not certified and no compliance warranty is implied.

## Positioning

**Goal: be the best amateur-grade FM processor available** — for hobbyist LPFM, community radio, pirate, SDR-fed exciters, and DIY broadcast workflows. MPX Prime is *not* trying to be a $5–15k Optimod / Omnia / Stereo Tool replacement; it is trying to be the obvious choice where commercial processors are unaffordable or overkill. See [`plan.md`](plan.md) "Positioning" for the full scope-in / scope-out list.

**Compared to open-source FM generators** (mpxgen, PiFmRds), MPX Prime runs a real processing chain in front of the encoder — phase rotator, wideband AGC with K-weighted detector + program-dependent release, 4-band parametric EQ, PrimeBass, mono bass, stereo widener, 3- or 5-band multiband compressor with per-band expander and limiter, linear-phase FIR multiband crossovers in TX path, bass clipper, audio-band distortion-cancelled clipper, pre-encode L/R true-peak limiter, BS.412, and an 8× oversampled composite clipper with delta-based per-band IM cancellation — and enforces the professional invariant that pilot and RDS bypass all peak control (post-clipper subcarrier injection). Add to that linear-phase Kaiser-windowed FIR encoder lowpass with ≥80 dB stop-band, 19 kHz pilot notch on the audio path, pilot-locked RDS with 301-tap biphase + optional Gaussian shaping, lock-free real-time DSP with vDSP/vForce SIMD acceleration on hot loops, and an offline verification harness with scenario / stereo / width tables. Open-source generators typically emit a valid MPX waveform without any of that.

**Compared to commercial processors**, MPX Prime's topology matches what Orban / Omnia / Stereo Tool publish, and individual stages (phase rotator, multiband with linear-phase FIR crossovers and stereo linking, post-clipper subcarrier injection, BS.412, delta-based per-band IM cancellation in the composite clipper — public-domain Orban patents US 4,460,871 + US 5,737,434 inspired the cancellation primitive) are implemented at professional quality. What's deliberately *out of scope* for amateur-grade: MPX-over-AES3 / Baseband192 transport, studio automation (Livewire/Dante/Ravenna), multi-site clustering, ITU-R SM.1268 RF-mask feedback at production grade, multipath mitigation. Lower-priority polish items still pending: heavier (16–32×) oversampling on the clipping nonlinearities, dynamic pre-emphasis, input-side restoration (declipper, dehumfilter). See [`plan.md`](plan.md) "Next up" for the current roadmap.

In short: well past the hobbyist baseline, sized for amateur broadcast use. Use MPX Prime for LPFM, community radio, pirate, prosumer broadcast-style encoding, and study of FM signal processing — not for certified production broadcast.

## Current app structure

- `Monitoring`: live status, transport, interfaces summary, DSP status, RDS snapshot
- `Processing`: core DSP, AGC, PrimeBass, multiband, widener, limiter
- `RDS`: control (master enable + injection + live status + runtime flags), identity (PI / PTY / PTYN / ECC + PS banks), radiotext (RT / RT+ / Now Playing), long PS, alt. frequencies (AF), schedule (group sequence + clock-time), subcarrier (physical layer)
- `Settings`: configuration path, interfaces, audio engine, spectrum options
- Separate windows: `Scopes`, `Spectrum`, `Levels`, `Help`

The RDS detail tabs are organised per UECP message-class taxonomy
(AF is a peer of PS, RT+ lives under ODA, etc.). Every operationally
toggled RDS setting applies live without restarting the transport —
PI, PTY, PTYN, TP/TA/MS/DI flags, AF list, group sequence, CT
enable, all RT/PS/Long PS text. Only physical-layer settings
(`rds_level`, `rds_freq`, Gaussian shaping FIR taps/BW) require a
transport restart since they reconfigure the modulator.

## Features

- Native macOS app built with Swift + SwiftUI + AppKit windowing
- Real-time MPX generation with 19 kHz pilot and 38 kHz stereo subcarrier
- Optional RDS generation with pilot-locked 57 kHz subcarrier
- Live input source or built-in test tone source
- Optional wideband AGC, HPF, program lowpass, HF trim, PrimeBass, mono bass, stereo widener, and multiband processing
- Broadcast-style final MPX stage with `Final Drive`, 8× oversampled composite clipper, and live clipper telemetry
- Composite budget telemetry with pilot/RDS/audio visibility and safety-limiter readout
- Broadcast preset picker for AGC/final-stage tuning (`Balanced Music`, `CHR / Dance`, `Punchy Music`, `Speech / Talk`)
- Italo / disco / dance multiband presets (`5B Italo`, `3B Italo`) with pumped low-band character
- Decoded MPX monitor output on a selectable monitor device
- Scopes, spectrum, levels, sticky peaks, and live monitoring views
- Config persisted to `~/Library/Application Support/MPX Prime/MPX Prime.ini`

## Requirements

- macOS 15+
- Xcode command line tools / Swift 6 toolchain
- Core Audio device capable of your chosen output rate; 192 kHz is recommended for full stereo MPX output
- Input devices may run at lower rates; the app handles conversion internally

## Build

```bash
swift build --package-path macOS
```

## Run

From repo root:

```bash
swift run --package-path macOS MPXPrime
```

Headless mode:

```bash
swift run --package-path macOS MPXPrime --nogui
```

Fixed runtime:

```bash
swift run --package-path macOS MPXPrime --seconds 10
```

Offline verification:

```bash
swift run --package-path macOS MPXPrime --verify --seconds 5
```

Preset sweep verification:

```bash
swift run --package-path macOS MPXPrime --verify-presets --seconds 5
```

Long-run compliance/regression verification:

```bash
swift run --package-path macOS MPXPrime --verify-long --seconds 30
```

Custom config file:

```bash
swift run --package-path macOS MPXPrime --config "/path/to/MPX Prime.ini"
```

## Quick start (first-time use)

This is the minimum to hear MPX Prime processing your audio and feeding a transmitter / SDR / loopback. Defaults are tuned to sound good out of the box — the chain ships processing-on with AGC, multiband, bass clipping, and the composite clipper engaged.

**1. Plug audio in and out.** MPX Prime reads from a Core Audio input device and writes the composite (MPX) signal to a Core Audio output device. Typical setups:

- Soundcard input from your studio mixer / streaming source → soundcard output into an FM exciter that accepts MPX baseband.
- BlackHole 2ch (virtual loopback) input from a music player or DAW → soundcard output into an SDR transmitter or RF generator.
- Test tone source (built-in) → output to verify metering and routing without external audio.

192 kHz output is recommended — it is the rate at which the full FM stereo composite (M + 38 kHz DSB-SC + 19 kHz pilot + 57 kHz RDS) fits inside Nyquist with headroom for oversampled limiting. 96 kHz works (RDS sits near the band edge); below 96 kHz, the composite cannot represent RDS.

**2. Set your region.** Pre-emphasis differs by region:

- **USA / Canada / South Korea**: 75 µs
- **Everywhere else (EU, ROW)**: 50 µs (current default)

Edit `~/Library/Application Support/MPX Prime/MPX Prime.ini`, set `preemphasis_us = 75` if you are in a 75 µs region. Wrong pre-emphasis will sound either dull (50 into 75 deemph) or shrill / over-modulated (75 into 50 deemph). EU operators required to comply with ITU-R BS.412 should also flip `bs412_enabled = True`.

**3. Launch and Start.** Open MPX Prime, pick your input and output devices in `Settings`, then press `Start` (⌘Return) on the toolbar. The status bar at the top of the window shows live IN L/R, MPX peak, deviation in kHz, modulation as a percentage of the configured deviation target (MOD), gain reduction, safety-limiter GR, composite budget, and pilot/RDS injection — if those move with your audio, the chain is processing.

**4. Calibrate composite output level.** On `Monitoring`, watch the `Composite Budget` chip:

- **Safe**: nominal modulation, headroom available
- **Tight**: near 100% modulation, fine for normal broadcast
- **Risk**: peaks exceeding 100% — back off `MPX Output Level` on the `Limiter` tab

`Final Drive` controls perceived loudness; `MPX Output Level` calibrates the final voltage to your exciter / SDR. Use `Final Drive` for loudness and `MPX Output Level` only for hardware calibration.

**5. Verify on a receiver.** Tune a real FM radio or RTL-SDR to your transmitter's frequency. You should hear stereo audio with a steady stereo-pilot indicator, see RDS PS and Radiotext on the radio's display (if your radio supports RDS), and the audio should sound louder and more present than the same source through `mpxgen` / PiFmRds.

If you cannot hear anything, check `Settings` → output device routing, that the engine is started, and that `processing_bypass` is `False` in the INI (the default).

## Configuration

Default config location:

```text
~/Library/Application Support/MPX Prime/MPX Prime.ini
```

Relevant config sections:

- `INTERFACES`: input/output/monitor device UIDs, source mode, monitor enable, block size
- `MPX`: processing, levels, stereo coding, limiter behavior
- `RDS`: program service, radiotext, flags, carrier settings

### Final-stage presets and clipper workflow

The `Processing` -> `Final Stage` tab contains the main loudness-building controls for the FM chain.

- `Broadcast Preset`: loads a matched AGC + final-stage starting point
- `Final Drive`: drives the composite clipper harder or softer
- `MPX Output Level`: final output calibration, not the main loudness control

Included presets:

- `Balanced Music`: general-purpose music default
- `CHR / Dance`: hotter final stage for denser contemporary music
- `Punchy Music`: more assertive than balanced, but less hot than CHR
- `Speech / Talk`: tighter AGC with lower final drive

Clipper telemetry in `Monitoring` and `DSP Overview` shows:

- `Drive`: current configured final drive
- `GR`: live composite clipper gain reduction
- `Max`: held peak gain reduction
- `Safe`: full-MPX safety limiter gain reduction
- `Peak`: final MPX output peak

Practical tuning target:

- `GR` occasionally in the `1 to 3 dB` range is a healthy working zone
- sustained higher GR usually means `Final Drive` is too high for the source
- use `MPX Output Level` only for exciter or interface calibration

Monitoring also shows composite calibration status:

- `Pilot`: configured pilot injection
- `RDS`: configured RDS injection
- `Audio`: audio-composite peak before pilot/RDS sum
- `Margin`: estimated remaining composite headroom
- `Composite Budget`: `Safe`, `Tight`, or `Risk`

### Stereo image control

The `Processing` -> `Widener` tab now contains two separate image controls:

- `Mono Bass`: collapses low-frequency side energy below a configurable crossover
- `Stereo Widener`: applies restrained upper-band widening with stereo-image protection

Recommended starting point:

- `Mono Bass`: on
- `Bass Mono Freq`: `110-140 Hz`
- `Width`: around `0.50`
- `Center`: around `0.50`
- `Mix`: around `0.70-1.00`

This keeps bass more mono-compatible while leaving the upper image open enough for FM.

### PrimeBass and multiband

The current low-frequency enhancement and multiband stages are now tuned more conservatively than earlier builds.

- `PrimeBass` (formerly `Orbass`, renamed in 0.12) uses adaptive low-band enhancement with restrained harmonics, optional subharmonics, and gated makeup behavior to avoid obvious bass pumping and synthetic overhang. 0.12 modernised the harmonic synth with MaxxBass-style equal-loudness weighting (per-order ISO 226 phon-curve weights for 2nd–5th harmonics) and an Aphex-style pre-waveshaper allpass at F0 that decorrelates harmonic phase from the direct boost — the perceived bass weight shifts onto the weighted harmonics, which buys headroom downstream without changing subjective bass.
- `Multiband` uses linear-phase Kaiser-windowed FIR crossovers in TX mode (parallel-cumulative-LP topology, sum-to-flat at `−155 dB`), so percussive transients land time-aligned across all bands and the recombined signal only changes spectral balance when the band gains move — not when bands fall out of phase. Monitor mode keeps the IIR Linkwitz-Riley 4 cascade for low latency. Both 3-band and 5-band modes are supported. INI key `multiband_fir_enabled` toggles the FIR path (default on).

Recommended starting point:

- `PrimeBass`: `AC/Pop` or `Rock` preset first
- `Multiband`: `5B AC/Pop` for general music, `5B Talk` for speech, `5B CHR/EDM` for a denser contemporary result, `5B Italo` / `3B Italo` for italo / disco / dance pumping character

The current defaults are intentionally moderate and are meant to be tuned upward from a clean starting point, not downward from a hyped one.

### Now Playing script output

The RDS Radiotext section can poll an external script for now-playing metadata.

Expected script behavior:

- Exit with status `0` only when active playback metadata is available
- Write metadata to `stdout`
- Plain single-line output is accepted and treated as the display text
- Structured `key=value` lines are preferred for correct RT+ tagging

No-data behavior:

- Exit with status `1` when no song is currently playing or no usable metadata is available
- MPX Prime treats `exit 1` and empty output as `No Song Data`
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

### RDS text syntax

MPX Prime accepts the same RDS text grammar as Stereotool for PS, PTYN, Long PS, and Radiotext fields. Unsupported markers are accepted silently where practical so existing Stereotool presets load without modification.

| Marker | Meaning |
| --- | --- |
| `Ns:TEXT` | Timed segment, `N` seconds. Fractional accepted (`1.5s:`). |
| `Nt:TEXT` | Transmit-count segment. Advances after `N` full transmissions of the field. |
| `/` | Separates repeating segments. |
| `<TEXT` / `>TEXT` | Scroll left / right. **PS only** — too slow to be useful on Radiotext. Repeat the marker for more chars per tick: `<<TEXT` scrolls twice as fast. |
| `\|\|` | Word-wrap toggle. Word-wrap is always on; accepted as a no-op. |
| `\\<`  `\\>`  `\\\|`  `\\:`  `\\/`  `\\\\` | Escape the special character so it transmits literally. |
| `\R"path"` / `\r"path"` | Load file contents (uppercase / as-is). |
| `\F"path"` / `\f"path"` | Aliases for `\R` / `\r`. |
| `\w"url"` | Fetch text from a URL. MPX Prime extension, not in Stereotool. |

Example mixing timing modes and separators:

```text
1.5s:MPX Prime/3t:In STEREO on RDS/10s:Now: {artist} - {title}
```

Scrolling PS marquee (PS is 8 characters wide):

```text
<<MPX PRIME - FM BROADCAST ENCODER
```

Escape a colon so it is not parsed as a timing prefix:

```text
Visit us\: https\://example.com/10s:Alt text
```

Important defaults:

- Input HPF default: `30 Hz`
- Program lowpass default: `16.4 kHz`
- Scope auto gain default: enabled

## Monitoring and output notes

- `MPX Output Device` is the composite/baseband output device
- `Monitor Output Device (Decoded MPX Simulation)` is used when monitor output is enabled
- The orange microphone indicator in the macOS menu bar is the system privacy indicator and appears when MPX Prime is actively using audio input
- `Mono Mode` now transmits true mono composite and suppresses pilot, stereo subcarrier, and RDS while enabled

## Offline verification

MPX Prime includes an offline MPX verification mode that renders deterministic test scenarios without opening audio devices.

Example:

```bash
./macOS/.build/debug/MPXPrime --verify --seconds 5
```

For key multiband-preset validation:

```bash
./macOS/.build/debug/MPXPrime --verify-presets --seconds 5
```

The report includes:

- MPX peak in dBFS
- estimated deviation in kHz
- composite clipper gain reduction
- safety limiter gain reduction
- audio-composite peak before pilot/RDS sum
- pilot and RDS injection percentages
- composite budget margin
- AGC reduction
- decoded-audio quality metrics per scenario:
  - input/output correlation
  - input/output side-to-mid ratio
  - RMS drift

Current deterministic scenarios include:

- `mono_1khz`
- `stereo_diff_400hz`
- `program_mix`
- `bright_dense`
- `vocal_sibilant`
- `transient_push`
- `wide_bass`

`--verify-presets` runs a shorter focused sweep across the main 5-band presets:

- `5B AC/Pop`
- `5B CHR/EDM`
- `5B Rock`
- `5B Talk`
- `5B News`
- `5B Urban`
- `5B Dance`

Current post-build preset sweep status:

- `5B AC/Pop`: `OK`
- `5B CHR/EDM`: `OK`
- `5B Rock`: `OK`
- `5B Talk`: `OK`
- `5B News`: `OK`
- `5B Urban`: `OK`
- `5B Dance`: `OK`
- `5B Urban`: `OK`
- `5B Dance`: `OK`

Current verification is strongest for composite safety and budget behavior. It is not yet a full listening-quality oracle for multiband crossover tone, stereo-image feel, or PrimeBass character, so final tuning still requires real program listening.

Exit status:

- `0` means no obvious composite-budget or safety-limiter issue was found
- `1` means the configuration is close to the limit and should be reviewed
- `2` means at least one verification warning was triggered

## Processing bypass

The `Bypass` control does not create a true wire bypass. It disables the creative processing blocks while keeping essential FM encode stages active.

Always active:

- Input gain
- Program lowpass
- Pre-emphasis
- MPX encoding
- Final drive, deviation scaling, and limiting
- Output gain

Disabled by bypass:

- Wideband AGC
- HF trim
- PrimeBass
- Mono bass
- Multiband processing
- Stereo widener

## Release build

Build a release app bundle / DMG:

```bash
./build-release.sh 0.11
```

Artifacts are written to `macOS/dist/`.

## References

- Standards PDFs and notes live in `documents/`
- Project-specific workflow guidance lives in `AGENTS.md`

## Appendix: RDS PI and ECC Country Table

RDS country identity is derived from:

- the top hex digit of the `PI` code, also called the country identifier or PI symbol
- the `ECC` value transmitted in group `1A`

Together they identify a country or area. There is no special "pirate" country code.

This appendix is a practical reference table for the published RDS country and area allocations. It is grouped the same way the published tables are grouped, so some countries and areas appear in more than one regional list.

### Europe / EBU area

| Country or area | ISO | PI symbol | ECC |
| --- | --- | --- | --- |
| Albania | ALB | 9 | E0 |
| Algeria | ALG | 2 | E0 |
| Andorra | AND | 3 | E0 |
| Austria | AUT | A | E0 |
| Azores [Portugal] | AZR | 8 | E0 |
| Belgium | BEL | 6 | E0 |
| Belarus (ex-USSR) | BLR | F | E3 |
| Bosnia-Herzegovina (ex-Yugoslavia) | BIH | F | E4 |
| Bulgaria | BUL | 8 | E1 |
| Canaries [Spain] | CNR | E | E0 |
| Croatia (ex-Yugoslavia) | HRV | C | E3 |
| Cyprus | CYP | 2 | E1 |
| Czech Republic | CZE | 2 | E2 |
| Denmark | DNK | 9 | E1 |
| Egypt | EG | F | E0 |
| Estonia (ex-USSR) | EE | 2 | E4 |
| Faroe Islands [Denmark] | DK | 9 | E1 |
| Finland | FI | 6 | E1 |
| France | FR | F | E1 |
| Germany | DE | D or 1 | E0 |
| Gibraltar [United Kingdom] | GI | A | E1 |
| Greece | GR | 1 | E1 |
| Hungary | HU | B | E0 |
| Iceland | IS | A | E2 |
| Iraq | IQ | B | E1 |
| Ireland | IE | 2 | E3 |
| Israel | IL | 4 | E0 |
| Italy | IT | 5 | E0 |
| Jordan | JO | 5 | E1 |
| Latvia (ex-USSR) | LV | 9 | E3 |
| Lebanon | LB | A | E3 |
| Libya | LY | D | E1 |
| Liechtenstein | LI | 9 | E2 |
| Lithuania (ex-USSR) | LT | C | E2 |
| Luxembourg | LU | 7 | E1 |
| North Macedonia (ex-Yugoslavia) | MK | 4 | E3 |
| Madeira [Portugal] | PT | 8 | E2 |
| Malta | MT | C | E0 |
| Morocco | MA | 1 | E2 |
| Moldova (ex-USSR) | MD | 1 | E4 |
| Monaco | MC | B | E2 |
| Netherlands | NL | 8 | E3 |
| Norway | NO | F | E2 |
| Palestine | PS | 8 | E0 |
| Poland | PL | 3 | E2 |
| Portugal | PT | 8 | E4 |
| Romania | RO | E | E1 |
| Russian Federation (ex-USSR) | RU | 7 | E0 |
| San Marino | SM | 3 | E1 |
| Slovakia | SK | 5 | E2 |
| Slovenia (ex-Yugoslavia) | SI | 9 | E4 |
| Spain | ES | E | E2 |
| Sweden | SE | E | E3 |
| Switzerland | CH | 4 | E1 |
| Syrian Arab Republic | SY | 6 | E2 |
| Tunisia | TN | 7 | E2 |
| Turkey | TR | 3 | E3 |
| Ukraine (ex-USSR) | UA | 6 | E4 |
| United Kingdom | GB | C | E1 |
| Vatican | VA | 4 | E2 |
| Yugoslavia | YU | 6 | E3 |

### African broadcasting area

| Country or area | ISO | PI symbol | ECC |
| --- | --- | --- | --- |
| Ascension Island | - | A | D1 |
| Cabinda | - | 4 | D3 |
| Angola | AO | 6 | D0 |
| Algeria | DZ | 2 | E0 |
| Burundi | BI | 9 | D1 |
| Benin | BJ | E | D0 |
| Burkina Faso | BF | B | D0 |
| Botswana | BW | B | D1 |
| Cameroon | CM | 1 | D0 |
| Canary Islands [Spain] | ES | E | E0 |
| Central African Republic | CF | 2 | D0 |
| Chad | TD | 9 | D2 |
| Congo | CG | C | D0 |
| Comoros | KM | C | D1 |
| Cape Verde | CV | 6 | D1 |
| Cote d'Ivoire | CI | C | D2 |
| Djibouti | DJ | 3 | D0 |
| Egypt | EG | F | E0 |
| Ethiopia | ET | E | D1 |
| Gabon | GA | 8 | D0 |
| Ghana | GH | 3 | D1 |
| Gambia | GM | 8 | D1 |
| Guinea-Bissau | GW | A | D2 |
| Equatorial Guinea | GQ | 7 | D0 |
| Republic of Guinea | GN | 9 | D0 |
| Kenya | KE | 6 | D2 |
| Liberia | LR | 2 | D1 |
| Libya | LY | D | E1 |
| Lesotho | LS | 6 | D3 |
| Mauritius | MU | A | D3 |
| Madagascar | MG | 4 | D0 |
| Mali | ML | 5 | D0 |
| Mozambique | MZ | 3 | D2 |
| Morocco | MA | 1 | E2 |
| Mauritania | MR | 4 | D1 |
| Malawi | MW | F | D0 |
| Niger | NE | 8 | D2 |
| Nigeria | NG | F | D1 |
| Namibia | NA | 1 | D1 |
| Rwanda | RW | 5 | D3 |
| Sao Tome and Principe | ST | 5 | D1 |
| Seychelles | SC | 8 | D3 |
| Senegal | SN | 7 | D1 |
| Sierra Leone | SL | 1 | D2 |
| Somalia | SO | 7 | D2 |
| South Africa | ZA | A | D0 |
| Sudan | SD | C | D3 |
| Swaziland | SZ | 5 | D2 |
| Togo | TG | D | D0 |
| Tunisia | TN | 7 | E2 |
| Tanzania | TZ | D | D1 |
| Uganda | UG | 4 | D2 |
| Western Sahara | EH | 3 | D3 |
| Zaire | ZR | B | D2 |
| Zambia | ZM | E | D2 |
| Zanzibar | - | D | D2 |
| Zimbabwe | ZW | 2 | D2 |

### Former Soviet Union allocations

| Country or area | ISO | PI symbol | ECC |
| --- | --- | --- | --- |
| Armenia | AM | A | E4 |
| Azerbaijan | AZ | B | E3 |
| Belarus | BY | F | E3 |
| Estonia | EE | 2 | E4 |
| Georgia | GE | C | E4 |
| Kazakhstan | KZ | D | E3 |
| Kyrgyzstan | KG | 3 | E4 |
| Latvia | LV | 9 | E3 |
| Lithuania | LT | C | E2 |
| Moldova | MD | 1 | E4 |
| Russian Federation | RU | 7 | E0 |
| Tajikistan | TJ | 5 | E3 |
| Turkmenistan | TM | E | E4 |
| Ukraine | UA | 6 | E4 |
| Uzbekistan | UZ | B | E4 |

### ITU Region 2

| Country or area | ISO | PI symbol | ECC |
| --- | --- | --- | --- |
| Anguilla | AI | 1 | A2 |
| Antigua and Barbuda | AG | 2 | A2 |
| Argentina | AR | A | A2 |
| Aruba | AW | 3 | A4 |
| Bahamas | BS | F | A2 |
| Barbados | BB | 5 | A2 |
| Belize | BZ | 6 | A2 |
| Bermuda | BM | C | A2 |
| Bolivia | BO | 1 | A3 |
| Brazil | BR | B | A2 |
| Canada | CA | C | A1 |
| Cayman Islands | KY | 7 | A2 |
| Chile | CL | C | A3 |
| Colombia | CO | 2 | A3 |
| Costa Rica | CR | 8 | A2 |
| Cuba | CU | 9 | A2 |
| Dominica | DM | A | A3 |
| Dominican Republic | DO | B | A3 |
| Ecuador | EC | 3 | A2 |
| El Salvador | SV | C | A4 |
| Falkland Islands | FK | 4 | A2 |
| Greenland | GL | F | A1 |
| Grenada | GD | D | A3 |
| Guadeloupe | GP | E | A2 |
| Guatemala | GT | 1 | A4 |
| Guiana | GF | 5 | A3 |
| Guyana | GY | F | A3 |
| Haiti | HT | D | A4 |
| Honduras | HN | 2 | A4 |
| Jamaica | JM | 3 | A3 |
| Martinique | MQ | 4 | A3 |
| Mexico | MX | F | A4 |
| Montserrat | MS | 5 | A4 |
| Netherlands Antilles | AN | D | A2 |
| Nicaragua | NI | 7 | A3 |
| Panama | PA | 9 | A3 |
| Paraguay | PY | 6 | A3 |
| Peru | PE | 7 | A4 |
| Puerto Rico | PR | 8 | A3 |
| Saint Kitts | KN | A | A4 |
| Saint Lucia | LC | B | A4 |
| St Pierre and Miquelon | PM | F | A6 |
| Saint Vincent | VC | C | A5 |
| Suriname | SR | 8 | A4 |
| Trinidad and Tobago | TT | 6 | A4 |
| Turks and Caicos Islands | TC | E | A3 |
| United States of America | US | 1..9, A, B, D, E | A0 |
| Uruguay | UY | 9 | A4 |
| Venezuela | VE | E | A4 |
| Virgin Islands [British] | VG | F | A5 |
| Virgin Islands [USA] | VI | F | A5 |

### ITU Region 3

| Country or area | ISO | PI symbol | ECC |
| --- | --- | --- | --- |
| Afghanistan | AF | A | F0 |
| Saudi Arabia | SA | 9 | F0 |
| Australia - Australian Capital Territory | - | 1 | F0 |
| Australia - New South Wales | - | 2 | F0 |
| Australia - Victoria | - | 3 | F0 |
| Australia - Queensland | - | 4 | F0 |
| Australia - South Australia | - | 5 | F0 |
| Australia - Western Australia | - | 6 | F0 |
| Australia - Tasmania | - | 7 | F0 |
| Australia - Northern Territory | - | 8 | F0 |
| Bangladesh | BD | 3 | F1 |
| Bahrain | BH | E | F0 |
| Myanmar [Burma] | MM | B | F0 |
| Brunei Darussalam | BN | B | F1 |
| Bhutan | BT | 2 | F1 |
| Cambodia | KH | 3 | F2 |
| China | CN | C | F0 |
| Sri Lanka | LK | C | F1 |
| Fiji | FJ | 5 | F1 |
| Hong Kong | HK | F | F1 |
| India | IN | 5 | F2 |
| Indonesia | ID | C | F2 |
| Iran | IR | 8 | F0 |
| Iraq | IQ | B | E1 |
| Japan | JP | 9 | F2 |
| Kiribati | KI | 1 | F1 |
| Korea [South] | KR | E | F1 |
| Korea [North] | KP | D | F0 |
| Kuwait | KW | 1 | F2 |
| Laos | LA | 1 | F3 |
| Macau | MO | 6 | F2 |
| Malaysia | MY | F | F0 |
| Maldives | MV | B | F2 |
| Micronesia | FM | E | F3 |
| Mongolia | MN | F | F3 |
| Nepal | NP | E | F2 |
| Nauru | NR | 7 | F1 |
| New Zealand | NZ | 9 | F1 |
| Oman | OM | 6 | F1 |
| Pakistan | PK | 4 | F1 |
| Philippines | PH | 8 | F2 |
| Papua New Guinea | PG | 9 | F3 |
| Qatar | QA | 2 | F2 |
| Solomon Islands | SB | A | F1 |
| Western Samoa | WS | 4 | F2 |
| Singapore | SG | A | F2 |
| Taiwan | TW | D | F1 |
| Thailand | TH | 2 | F3 |
| Tonga | TO | 3 | F3 |
| UAE | AE | D | F2 |
| Vietnam | VN | 7 | F2 |
| Vanuatu | VU | F | F2 |
| Yemen | YE | B | F3 |

### Notes

- The `PI symbol` is the top hex digit of the four-digit `PI` code.
- The remaining three hex digits identify the programme service within the country or area allocation.
- The United States uses `RBDS` PI allocation rules, so the country row above is only the country-area level identifier.
- Australia commonly uses a state-based `PI` symbol scheme in practice, which is why the published list is shown by state and territory rather than one national symbol.

## License

GPL-3.0. See `LICENSE`.
