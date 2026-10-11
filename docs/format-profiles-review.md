# Format Profiles -- review against industry presets (2026-10-10)

Asked: do the presets make sense, what can be learned from Orban, Omnia and
Stereo Tool, and which station sounds can be approximated. Values are the
profile's after intensity scaling, from `PresetCatalog.swift` at `1ffbf10`.

## Our profiles

| Profile | Format | AGC target / atk / rel / range | Multiband (thr dB, ratio, atk, rel: low / mid / high) | Drive | Pre-encode | Composite thr / ceil | Bass clip | PrimeBass | Mono bass | Phase rot | Verdict |
| ------- | ------ | ------------------------------ | ---------------------------------------------------- | ----- | ---------- | -------------------- | --------- | --------- | --------- | --------- | ------- |
| Music -- Clean (default) | AC / general | -16 / 200 / 1200 / +/-12 | 5_ac normal: -17.5 1.75 28 375 / -16 1.55 19 300 / -14.5 1.28 13 225 | 4 | 0.90 | -1.0 / -0.3 | off | off | 140 | off | Sensible; Orban ROCK-MEDIUM / Omnia Natural philosophy |
| Music -- Loud | CHR | -15 / 150 / 900 / +10 -9 | 5_chr normal: -23 2.25 20 320 / -21 1.9 13 240 / -19 1.6 8 180 | 8 | 0.85 | -0.8 / -0.2 | on | on | 115 | off | Sensible (pre-0.45 CHR verbatim); no spectral shaping |
| Speech / Talk | News / talk | -16 / 100 / 750 / +10 -8 | 5_talk light: -11 1.12 58 644 / -10.3 1.06 48 518 / -9.7 1.0 36 414 | 4.5 | 0.88 | -1.0 / -0.3 | off | off | 140 | on | Questionable: slowest and weakest multiband in the catalogue |
| Classical / Wide | Classical, jazz | -18 / 200 / 1200 / +/-12 | 5_classic light: -15.5 1.35 43 518 / -14.5 1.26 36 414 / -13.5 1.13 24 322 | 3 | 0.92 | -1.2 / -0.4 | off | off | 140 | off | Mostly sensible; AGC range too wide, mono bass too high |

BS.412, band limiter, expander, PEQ, HF limiter threshold, AGC release,
stereo guard and Advanced Dynamics are left untouched by every profile.

## Findings

1. **Speech multiband is backwards.** Light scaling turns the talk preset
   into ratios 1.12 / 1.06 / 1.0 (the high band clamps to bypass) with
   414-644 ms releases, the slowest in the table. Orban: only NEWS-TALK and
   SPORTS use a fast release, to "quickly equalize substandard material".
   Omnia Talk: phase rotator and fast multiband attack and release. We have
   the rotator but not the density.
2. **Final-stage AGC targets are silently overridden.** `applyFinalStage`
   sets -14 (speech) / -16 (balanced); the profile then writes -16 / -18,
   so the stored final-stage preset id no longer describes the AGC.
3. **Classical AGC has pop-music range.** +/-12 dB and 1200 ms release come
   from "balanced". Orban's CLASSICAL preset runs the AGC at about 2:1,
   PROTECTION at about 0 dB gain reduction; BBC classical distribution keeps
   an LRA of 15 LU against 3 LU for pop. 12 dB of lift chases pianissimo.
   Mono bass at 140 Hz also folds orchestral LF space on the "purist"
   profile.
4. **HF limiter threshold vs limiter threshold.** `hf_limiter_threshold_db`
   stays -2.0 in all profiles; Classical's pre-encode 0.92 (-0.7 dB) leaves
   1.3 dB where the HF limiter rides string tone before any peak exists.
   (See `docs/hf-limiter-review.md`, finding 2.)
5. **Bass clipper rationale contradicts itself.** The default is on ("Orban
   and Omnia run bass clipping in every factory preset", which is true),
   three of four profiles turn it off and the reference calls it "usually
   unnecessary". Orban's answer for speech is a 0 dB threshold, not
   removal.
6. **Profiles do not switch Advanced Dynamics off.** With it enabled a
   profile rewrites AGC and multiband settings that are bypassed; the
   leveling does not change. No profile should run under it while its
   default flip is blocked.
7. **Fresh install differs from the default profile.** `formatProfileID`
   defaults to Music -- Clean, but `AppConfig()` is AGC -14, bass clipper
   on, drive 6, limiter 0.85, look-ahead 0 ms; the drift test compares only
   three ids.
8. Fine as is: Loud's 20 ms low-band attack (Orban exposes 4-50 ms); HF
   clipper off everywhere (now removed); BS.412 left to the operator
   (country, not format).

## Proposed changes

Speech: multiband intensity light -> normal; the talk preset rows -> -14
1.8 25 220 / -13 1.7 18 180 / -12 1.5 12 140 (fast-release talk density);
AGC target -16 -> -14 (honour the speech final-stage preset).

Classical: a new final-stage preset `classical` (target -18, attack 200,
release 3000, max lift 6, min -12: a gentle 2:1-style ride, no pianissimo
lift); mono bass 140 -> 90 Hz; HF limiter threshold -1.0 to sit a little
below the 0.92 limiter.

Music -- Clean: bass clipper on at the defaults (every vendor structure
bass-clips; distortion-cancelled, idle at drive 4); HF limiter threshold
-1.5 (0.5 dB under the 0.90 limiter).

Music -- Loud: PEQ on with +1.5 dB at 80 Hz and +1.0 dB at 3 kHz Q 1
(Orban GREGG "<100 Hz lift", IMPACT presence), listening-gated; band
limiter on (-3 dB, 0.5 / 50 ms; roadmap B4: density before more clipping).

All profiles: set `advancedDynamicsEnabled = false`; carry the AGC target in
the final-stage presets instead of overriding it; align `AppConfig()` with
Music -- Clean or widen the drift test.

One additional profile, **Music -- Dense**: 0.45 folded EDM (dance heavy,
+9 dB) and Urban into Loud and dropped the top density tier; Orban ships
Open / Medium / Dense flavours per format, and the Stereo Tool community's
most shared presets are "CHR Dense" / "Loud Dense". Proposed: multiband
dance heavy, final stage chr, AGC -15, PrimeBass on, mono bass 110,
composite -0.6 / -0.2 with 2 ms look-ahead, drive 9, pre-encode 0.85, MPX
limiter on, HF limiter on, bass clipper on, band limiter on, phase rotation
off. Rock, Jazz and AC-Warm are NOT proposed: Orban itself aliases them to
a multiband-preset swap on a medium structure.

## Applied (2026-10-10)

Every proposed change landed in `PresetCatalog.swift`, pinned by 19 tests
in `FormatProfileTests`: Speech multiband normal intensity with the fast
talk rows (-14 1.8 25/220, -13 1.7 18/180, -12 1.5 12/140) and AGC -14;
a `classical` final-stage preset (-18, 200 / 3000 ms, +6 / -12) and mono
bass at 90 Hz; Clean bass-clips at the defaults; Loud gains the presence
tilt and the band limiter; every profile switches Advanced Dynamics off;
the AGC target now lives in the final-stage preset; `AppConfig()` equals
Music -- Clean (drive 6 -> 4, pre-encode 0.85 -> 0.90, AGC -14 -> -16
with 200 / 1200 ms and +/-12 dB, mono bass 125 -> 140, composite look-ahead
0 -> 2 ms); the new `music_dense` profile (`edm_dance` migrates to it).
Baselines `default`, `presets` and `long` were recaptured: the +0.24 dB of
composite-clipper GR on every row is the pre-encode default moving from
0.85 to 0.90 on the harness config, which lacks the key. One figure to
look at: the default-config `hard_panned_hf` side-to-mid ratio fell 4.2 dB
(46.9 to 42.7) for the same reason -- the hotter clipper folds more side
into mid on that synthetic hard-panned HF scenario; shipped profiles are
unaffected (`--verify-hf-transients` and `--verify-stereo-guard` are OK on
all five). The real-music A/B and listening are still owed.

## Station sound: what is public

| Station | Public record | Target | Start from |
| ------- | ------------- | ------ | ---------- |
| BBC Radio 1 / 2 | Processor not published; BBC distribution targets pop -14 LUFS LRA 3, speech -18, classical -27 LRA 15; BBC Local Radio chose Omnia in 1999; Arqiva bought the UK's first Optimod 8600 | dense but low-fatigue (R1), open (R2) | Loud with PEQ off / Clean |
| Sky Radio | five Omnias (2000) | smooth AC | Clean + PrimeBass |
| NRJ | Omnia on 150 stations; RFM Paris Omnia.11 (2012) | loud, bright | Dense |
| Z100 | Omnia.11; "loud and proud, but fidelity" | loud, clean | Loud |
| KIIS-FM | Omnia (2002) | -- | Loud |
| Hot 97 | Omnia "HOT" preset modelled on its chain: "very loud, rich and full" | bass-heavy, dense | Dense with the urban multiband preset |
| Capital / Heart | Omnia.11 at Croydon (forum photo, unverified) | -- | Loud / Clean |
| Radio 538, Qmusic, Absolute, Kiss, Radio X | unknown | -- | -- |

An Orban or Stereo Tool preset cannot be imported: the units differ (AGC
release in dB/s and Slow..Fast enums, 2- or 5-band plus 6-band limiters,
200 Hz B1/B2 crossover vs our 90 Hz; Stereo Tool's numeric-key .sts files
and two multiband stages). What carries over: per-band target tilt,
crossover regions, release ORDER (open / medium / dense), AGC ratio
philosophy, HF-limit-first-then-clip, bass clipping in every structure,
stereo enhancement off by default, pre-emphasis region, BS.412 per country.

## Verification

1. `--verify-presets --capture-baseline` on every platform after any table
   edit, then `--verify-presets --baseline-strict`; `--verify
   --baseline-strict` stays green unless `AppConfig()` is aligned.
2. `--verify-hf-transients` per profile: hat SINAD on Loud / Dense at least
   the 18 dB the HF limiter holds today; Clean ride SINAD at least 46.8 dB.
3. `--verify-stereo-guard` on Dense.
4. `--verify-program-ab "$MPXPRIME_MUSIC_DIR" --ab-profile <id>` per profile.
5. `FormatProfileTests`: `profilesOwnTheFullGainStructure` gains
   `advancedDynamicsEnabled == false`; widen `defaultProfileMatchesShippingDefaults`.
6. Listening (`docs/test-playlist.md`): Speech on SQAM speech, "Tom's
   Diner", a news bulletin; Classical on Mahler 2, Chopin Nocturnes, 1812;
   Clean on "Fast Car", "Aja", "Hotel California"; Loud / Dense on "Bad
   Romance", "Vertigo", "Killing Me Softly", "Centerfield", and section 2
   for the HF limiter.

## Sources

- Orban Optimod-FM 8600 operating manual (presets pp. 201-209, 217, 226,
  232, 240, 243): <https://www.manualslib.com/manual/1267434/Orban-Optimod-Fm-8600.html>
- Telos presets page: <https://docs.telosalliance.com/docs/presets-3>
- EBU Tech 3401 (BBC distribution loudness targets):
  <https://tech.ebu.ch/files/live/sites/tech/files/shared/tech/tech3401v2_0.pdf>
- Thimeo FAQ and forum: <https://www.thimeo.com/help/stereo-tool/>,
  <https://forums.stereotool.com/viewtopic.php?p=48907>
- Telos press: BBC Local Radio (1999), Europe chooses Omnia (2000), Z100
  (2013), top-100 stations (2002), Omnia.fm HOT; Preco on the first UK 8600.
