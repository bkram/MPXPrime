# PrimeBass -- correctness review and alternatives (2026-10-10)

The field report is "PrimeBass does not sound good". This review checks the
stage against the bass-enhancement literature and the processors it was
modelled on, then ranks what to do about it. Line numbers refer to
`Sources/MPXPrime/MPXGenerator.swift` at `1ffbf10`.

## What the stage does today

- Runs on the mid signal after the multiband compressor and before the
  Bass Clipper (`processProgramStereo`, 3717-3724). That placement matches
  Stereo Tool, Omnia and Orban: enhance, then let the bass clipper hold the
  peaks.
- Input "band" is a one-pole 6 dB/oct lowpass at F0 (default 95 Hz), not a
  band-pass (`DSP/DSPSupport.swift:125-141`).
- Two waveshapers on an allpass-rotated copy of that band (4440-4448):
  `tanh(nlDrive * x) - tanh(k * x)` (labelled odd) and `x * |x|` (labelled
  even). Per-order "ISO 226" weights are a Gaussian in log-frequency centred
  on 150 Hz (2652-2659). Output band: 2nd-order HPF at 1.6 F0, LPF at 5 F0.
- A Big Bottom style LF envelope scales the boost UP with level (4396-4421);
  a Werrbach transient detector adds 0.7..1.4x on onsets (4467-4489); an
  octave divider makes the optional subharmonic (4494-4506).
- Three per-sample nonlinearities wrap all of it: an input gate that returns
  the dry signal whenever both |mid| and |low| are small (4380-4382), an
  instantaneous makeup ratio (4515-4526) and `limitStereoDeltaPeak`, which
  scales the enhancement so it never exceeds about 1.04x |input| at any
  sample (4530-4536).
- Defaults `AppConfig.swift:331-339`; only the "Music -- Loud" profile
  enables it (`PresetCatalog.swift:477`). `PrimeBassMaxxBassTests` sums
  energy at 2..5 F0 and compares 3rd to 5th; nothing asserts a 2nd harmonic.

## Findings, most audible first

1. **No even harmonics exist.** `x * |x|` is odd-symmetric (f(-x) = -f(x)),
   and so is the tanh difference. A sine at F0 yields 3 F0, 5 F0, 7 F0 only;
   the "even generator" comment, `primeBassHarmEvenWeight` and the 2 F0 term
   in the tests weight nothing. With F0 = 95 Hz and the LPF at 475 Hz the
   synthesised content is essentially one tone at 285 Hz. Oo, Gan and
   Hawksford (AES 2011) show the missing-fundamental effect needs an
   asymmetric device (half-wave rectifier, exponential, polynomial) so the
   full series 2 F0, 3 F0, 4 F0 ... exists; a lone 3rd gives weak pitch and a
   hollow, nasal tone. This alone explains "not warm". Certain (mathematics).
2. **The input band is not isolated.** A 6 dB/oct lowpass at 95 Hz still
   passes 300 Hz at about -10 dB and 1 kHz at about -20 dB, so vocals and
   snare reach the waveshapers and intermodulate with the bass; the sum and
   difference products land in 100-600 Hz, which is mud. Every reference
   design (MaxxBass, the DAFx-20 hybrid, Larsen and Aarts) uses a steep
   band-pass before the nonlinearity and a steep band-pass after it. High
   confidence.
3. **The per-sample gate switches the stage off near every zero crossing**
   (gate floor about 0.036 at typical levels) while the allpass, filters and
   envelopes are not advanced; the 3rd harmonic is non-zero where the
   fundamental is zero, so the output steps roughly 2 F0 times a second.
   Heard as buzz and grit locked to the bass line. High confidence.
4. **`limitStereoDeltaPeak` is an instantaneous waveform limiter.** Where
   |input| is small it clamps the added harmonics to about 1.04x |input|,
   chopping them twice per cycle: a strong second nonlinearity on top of the
   first. High confidence.
5. **The level law is an upward expander.** Big Bottom (US 5,359,665, claim
   2) raises gain when bass is LOW and lowers it when bass is high. Here
   `boostGain` and `harmonicGain` grow with the LF envelope, on top of the
   x^2 / x^3 growth the waveshapers already have, so loud bass gets the most
   enhancement and drives the bass clipper hardest. High confidence.
6. **The fundamental leaks in anti-phase.** The tanh difference keeps a large
   linear term (about 1.6x at defaults); the 2nd-order HPF at 1.6 F0 removes
   only about 8 dB of F0, and the allpass has rotated it by 180 degrees, so
   a frequency-dependent copy of the fundamental is subtracted from the
   direct path, with about 4.7 ms of group delay at F0. Partial cancellation
   and smeared kicks. Medium confidence.
7. **`primeBassDirectGainReduction` does not do what the roadmap says.** It
   scales only the ADDED boost (0.93 at defaults), never the dry bass; no
   headroom is bought by "shifting bass onto harmonics". It is not the cause
   of thinness, the makeup floor and the delta limiter are. High confidence.
8. Minor: no oversampling around the waveshapers at 48 kHz; the loudness
   weights are static per order at F0 rather than per note; the single
   octave divider mistracks on polyphonic bass and keeps the odd harmonics
   of its square wave (dbx used four narrow bands for a reason).

## What the others do

| Design | How it works | Strengths | Weaknesses | Used by | Patents |
| ------ | ------------ | --------- | ---------- | ------- | ------- |
| Clip-then-shape bass limiter | Band-limit, clip or limit the bass, then lowpass-shape the clip products (Stereo Tool: full to 100 Hz, none at 300 Hz; Orban: time-aligned, bandwidth-controlled) | Harmonics only on loud bass, time-aligned by construction, raises bass level without peaks | Needs oversampling; fixed harmonic colour | Orban, Stereo Tool, Omnia | Decades-old prior art |
| Asymmetric NLD virtual bass | Steep BPF, half-wave rectifier plus exponential or polynomial, BPF F0..4 F0, delay-matched sum | Full harmonic series; best on transients (DAFx-20) | Intermodulation on polyphonic bass; spectrum changes with level | Larsen and Aarts, NTU | Rectifier patents expired |
| MaxxBass feedback multiplier | Recursive multiply with a 2nd-order HPF in the loop, 4th-order elliptic output HPF, upward compressor at ratio 0.8 | Harmonic-to-fundamental ratio normalised by the compressor | Needs the loop compressor | Waves | US 5,930,373 expired 2017 |
| Phase vocoder or hybrid | Pitch-shift the tonal part, NLD on transients | Exact harmonic control, level-independent | Smearing, latency, CPU; rated below an ATSR NLD in listening tests | Research | Several active (DTS, NTU) |
| Big Bottom dynamic low shelf | LP band, compressor whose gain falls with level, summed out of phase | Longer bass notes, no peak growth | Mud when overdriven | Aphex | US 5,359,665 expired 2012 |
| Sub synthesiser below 80 Hz | Narrow-band octave dividers | Weight on thin material | Mistracking | dbx 120, Orban 8700i | Expired |
| Low-band transient shaper | Fast/slow envelope ratio on the bass band | Punch without level | Pumps if fast | Omnia.9, SPL | SPL DET, likely expired; verify |

## Recommendations, ranked

1. **Make the Bass Clipper the enhancer and turn PrimeBass off in "Music --
   Loud".** Add a post-clip shaping lowpass (full below 100 Hz, none at
   300 Hz) and a program-dependent low-shelf drive ahead of `BassClipper`
   (`DSP/AudioClippers.swift:110`). This is what the three broadcast
   processors ship. Louder, cleaner bass with no midrange grit. Verify with
   `--verify-program-ab` plus a `primebass_enabled` variant, the IMD and
   crest metrics, and listening. Two to three days. Patent-free.
2. **Fix the generator so it is a real missing-fundamental device.** In
   `processPrimeBass`: replace `x * |x|` with an asymmetric device (half-wave
   rectifier plus tanh, or x + k x^2), replace the one-pole input with a
   4th-order band-pass (0.5..1.0 F0), 4th-order output HPF at 1.6 F0,
   delay-match the direct path to the filters' group delay, drop the
   allpass. Add a test that asserts a lift at 2 F0 (none exists). Two to
   three days. Expired prior art.
3. **Remove the three per-sample nonlinearities** (gate, delta limiter,
   instantaneous makeup) in favour of one block-rate envelope (10 ms /
   300 ms). Half a day, and the buzz goes first.
4. **Invert the level law to Big Bottom's** (gain inversely proportional to
   the LF envelope) at 4421 and 4489, keeping the transient burst. One day.
   US 5,359,665 expired; stay clear of DTS US 9,712,916 by not coupling the
   gain to instantaneous headroom.
5. **Replace the octave divider** with two narrow-band dividers (48-72 Hz,
   72-112 Hz) or drop the subharmonic option. One day.

Do 3 first (cheap, removes the grit), then decide between 1 and 2 by A/B:
if the shaped bass clipper alone sounds right, PrimeBass can stay off by
default and 2 becomes optional polish.

## Fix landed (2026-10-10)

Recommendations 2, 3 and 4 are implemented in `processPrimeBass`; the new
`--verify-primebass` gate and twelve unit tests pin the behaviour; the
Bass Clipper as enhancer (recommendation 1) is left for the A/B now that
the stage works. Measured at the defaults, 50 Hz at -20 dBFS: 2 F0 at
-18.8 dB and 3 F0 at -22.5 dB relative to the fundamental, fundamental
change +0.03 dB, energy above 5 F0 -49 dB, DC -149 dBFS, peak growth
+1.36 dB, 2 F0 ratio change over 20 dB of level 0.04 dB, 950 / 1050 Hz
intermodulation on a 50 Hz + 1 kHz pair -85 dB, a lone 1 kHz tone passes
within -132 dB, disabled path bit-identical. The series arrives about
18 ms after the fundamental (filter group delay) with no cancellation at
F0 or 0.5 F0, so no dry delay was added. The direct path stays dry: a
Big Bottom shelf would move 1 kHz and lift most when there is no bass;
`density` carries the inverse law on the harmonic layer instead. One new
helper, `LR4Section` (Double state), exists because a Float biquad with a
corner below 100 Hz at 192 kHz amplifies its own rounding noise toward DC;
the Bass Clipper's Float LR4 at 768 kHz has the same -80 dBFS floor, noted,
not touched.

## Sources

- Oo, Gan, Hawksford, "Perceptually-motivated objective grading of nonlinear
  processing in virtual-bass systems", AES 2011:
  <https://aes2.org/publications/elibrary-page/?id=16149>
- NTU virtual bass summary: <https://www3.ntu.edu.sg/home/ewsgan/img/projects/VBS.pdf>
- Eloi et al., hybrid virtual bass, DAFx-20:
  <https://acris.aalto.fi/ws/portalfiles/portal/51973173/Eloi2020_Virtual_bass_DAFx2020.pdf>
- Larsen and Aarts, Audio Bandwidth Extension (Wiley 2004):
  <https://www.sps.tue.nl/rmaarts/BWE_Book/bwebook.html>
- Waves MaxxBass, US 5,930,373: <https://patents.google.com/patent/US5930373A/en>
- Aphex Big Bottom, US 5,359,665: <https://patents.google.com/patent/US5359665A/en>
- Sonos bass enhancement, US 11,297,433: <https://patents.google.com/patent/US11297433B2/en>
- Orban Bass Impact Engine: <https://www.radioworld.com/?p=97524>
- Stereo Tool bass boost thread: <https://forums.stereotool.com/viewtopic.php?p=3730>
- Omnia.11 bass stages: <https://www.telosalliance.com/news/Omnia-Reveals-Clear-and-Loud-Audio-with-its-New-Omnia11-at-NAB-2010>
- dbx 120XP review: <https://www.soundonsound.com/reviews/dbx-120xp>
