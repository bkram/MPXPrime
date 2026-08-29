# MPX Prime -- listening test playlist

Reference program for evaluating the MPX Prime Studio chain by ear, mapped to
the stage each track stresses. Measurement comes first (`--verify*`, and since
0.45 `--verify-hf-transients` for hi-hats / cymbals); this playlist is the
listening confirmation step the verifier cannot replace.

Survey date 2026-08-29. Every entry carries its source; **[BROAD]** = named by
two or more unrelated sources, **[SINGLE]** = one source, **[OWN]** = our own
suggestion with no engineer citation. Honest state of the record: FM
processing engineers publish very little about their test material -- the
genuinely broadcast-processor-specific picks (section 1, plus the first two
sibilance entries and the Fugees / Stardust / Fogerty / Collins rows) all
trace to a handful of RadioDiscussions and Gearspace threads. The Stereo Tool
forum threads that were reachable are settings discussions and name no
tracks; Hans van Zutphen names none in his interviews. The EBU SQAM items
and "Fast Car" are the only entries backed by a standards body or published
listening-test research.

How to use: run the track through the release build against a real 192 kHz
device (debug builds are not real-time capable), listen on the target
receivers, and note the artifact class in the table's "listen for" column.
Compare A/B by toggling the stage named in the first column -- a toggle that
changes nothing audible means the stage is not where the problem is.

## 1. Peak control, asymmetry, clipper density (composite clipper, final limiter)

| Track | Listen for | Source |
| ----- | ---------- | ------ |
| Three Dog Night -- "Black and White" (*Seven Separate Fools*, 1972) **[BROAD]** | The canonical FM torture test: strongly asymmetrical bass in the first notes overmodulates chains without good phase rotation / peak control (posters report ~120-130% while the mod monitor looks fine). | RadioDiscussions "Using Breakaway as FM processor" p.2; "Breakaway Broadcast Processor" thread |
| Steely Dan -- "Josie" (*Aja*, 1977) **[BROAD]** | "Processing killer": very high peak-to-average ratio; the demo track for Orban 8100 Digimod A/Bs. | RadioDiscussions "Digimod cards for Orban 8100" |
| Steely Dan -- "Aja" (*Aja*, 1977) **[BROAD]** | Long quiet-to-dense arc: AGC / multiband gain riding. | RadioDiscussions "Omnia Processing Question"; Gearspace |
| U2 -- "Vertigo" (2004) **[SINGLE]** | Arrives already flat-topped: clipper-on-clipper IM in the composite clipper. | RadioDiscussions "Omnia Processing Question" |
| Metallica -- *Death Magnetic* (2008) **[BROAD]** | The reference hyper-compressed master (peaks beyond digital clipping): how much MORE density a clipper adds when the input is already at the wall. | Wikipedia "Loudness war"; Gearspace |
| Red Hot Chili Peppers -- *Californication* (1999) / "Dani California" (2006) **[BROAD]** | Prominent source clipping throughout; Stereo Tool users run it through the declipper. | Wikipedia; Gearspace; diyAudio |
| Lady Gaga -- "Bad Romance" / "Just Dance" **[BROAD]** | Frank Foti's low-dynamic-range pole (vs "Hotel California"): ~-6 dB RMS masters. | Gearspace "Mastering for the Optimod"; Radio ILOVEIT Foti interview part 2 |
| Eagles -- "Hotel California" **[SINGLE]** | Foti's high-dynamic-range pole for AGC behaviour. | Radio ILOVEIT Foti interview part 2 |

## 2. Pre-emphasis stress: sibilance, cymbals, hi-hats (HF Limiter, Audio Limiter look-ahead, composite clipper)

This is the section for the 2026-08-29 field finding. Pair it with
`--verify-hf-transients`, whose `hat_multitone` / `ride_multitone` /
`cymbal_wash` scenarios are the deterministic stand-ins for these tracks.

| Track | Listen for | Source |
| ----- | ---------- | ------ |
| Cowboy Junkies -- "Sweet Jane" (*The Trinity Session*, 1988) **[SINGLE, broadcast source]** | Single-point Ambisonic church recording with extreme vocal sibilance; the diffuse pickup also loads L-R (stereo subcarrier / multipath). | RadioDiscussions "Digimod cards for Orban 8100" |
| Expose -- "Seasons Change" (1987) / "I'll Never Get Over You" (1993) **[SINGLE]** | "Sibilance city": late-80s pop vocal with hyped 6-10 kHz. | RadioDiscussions "Digimod cards for Orban 8100" |
| Natalie Imbruglia -- "Torn" (1997) **[SINGLE]** | Mike Senior's "endstop" for acceptable vocal air / sibilance -- a ceiling reference for the Audio Limiter's HF-only look-ahead detector. | Sound On Sound, "Creating Your Own Reference CD" |
| Massive Attack -- "Paradise Circus" (*Heligoland*, 2010) **[BROAD]** | Breathy vocal where sibilance ruins intimacy; sharp snare and strings for HF. | What Hi-Fi (x2); Sonarworks community list |
| Diana Krall -- e.g. "Let's Face the Music and Dance" (1999) **[BROAD]** | Close-miked vocal with harsh consonants, crisp cymbal work and reverb decay. | Audiogon; LEA Professional system-test playlist; Gearspace |
| Jennifer Warnes -- "Bird on a Wire" (*Famous Blue Raincoat*, 1987) **[BROAD]** | Crisp hi-hats, driving toms, saxophone; a long-standing sibilance check. | LEA Professional; Audiogon |
| Suzanne Vega -- "Tom's Diner" (a cappella, 1987) **[BROAD]** | The MP3 tuning track: a naked voice masks nothing, so clipper IM and HF limiting are fully exposed. | NPR; Wikipedia |
| EBU SQAM CD -- castanets, glockenspiel, triangle, harpsichord (EBU Tech 3253) **[BROAD]** | Standards-body transient items: isolated HF transients are the pre-emphasis worst case; castanets for pre-echo / attack shape. Free download from the EBU. | EBU Tech 3253 |
| Melody Gardot -- "Who Will Comfort Me" (2009) **[SINGLE]** | Vocal realism and sibilance handling in jazz swing. | Headphonesty (Peter Comeau, IAG) |

## 3. Dense / deep bass (Bass Clipper IM, low-band gain reduction, PrimeBass)

| Track | Listen for | Source |
| ----- | ---------- | ------ |
| Fugees -- "Killing Me Softly" (*The Score*, 1996) **[SINGLE, broadcast source]** | Sustained sub-heavy bass under a sparse vocal: low-band GR and bass-clipper IM audible against the voice. | RadioDiscussions "Omnia Processing Question" (Goran Tomas) |
| Massive Attack -- "Angel" (*Mezzanine*, 1998) **[BROAD]** | Slow-building repeated bass figure ("basically a test tone for low end"); cymbal crashes for HF. | Mix "Music to Tune a PA By"; What Hi-Fi; Gearspace |
| Fear Factory -- "What Will Become?" (2001) **[SINGLE]** | Single very loud bass drop: bass-clipper / limiter recovery. | Mix "Music to Tune a PA By" |
| Daft Punk -- *Random Access Memories* (2013) **[BROAD]** | Clean, controlled deep bass (Bob Ludwig, DR8): what the bass clipper should leave alone. | Production Advice (Ian Shepherd); Gearspace; LEA |
| Kendrick Lamar -- "DNA." (2017) **[SINGLE]** | Compressed sub-heavy production with hard stop/start: bass clipper plus AGC hold together. | Headphonesty (HEDD Audio) |
| Yello -- "The Race" (1988) **[BROAD]** | Uncluttered repetitive synth bass exposes sluggish transient behaviour immediately. | Gearspace; Headphonesty |
| Sheryl Crow -- "All I Wanna Do" (1993) **[SINGLE]** | 90s master with real sub content and unsquashed drum transients. | Gearspace "favorite reference tracks" |

## 4. AGC / Advanced Dynamics: pumping, attack-release, gating, sparse fades

| Track | Listen for | Source |
| ----- | ---------- | ------ |
| Stardust -- "Music Sounds Better With You" (1998) **[SINGLE, contested]** | Named for "excessive pumping" -- but the record pumps by itself (sidechain-style production); know the source before blaming the processor. | RadioDiscussions "Omnia Processing Question" |
| John Fogerty -- "Centerfield" (1985) **[SINGLE, broadcast source]** | Isolated claps with silence between: AGC / multiband release curve and clipper ringing per clap. | RadioDiscussions "Omnia Processing Question" |
| Phil Collins -- "In the Air Tonight" (1981) **[BROAD]** | Long quiet gated-reverb intro (gain ride, noise pull-up) then the 3:41 fill (attack / overshoot). | RadioDiscussions; LEA |
| Peter Gabriel -- "Darkness" (*Up*, 2002) **[BROAD]** | Ambient-to-explosive transitions: the single best leveler-transition test found. | Sonarworks; Headphonesty |
| Supertramp -- "The Logical Song" (1979) **[BROAD]** | Wide crest factor late-70s master: a leveler should ride it without breathing. | Sonarworks; Gearspace |
| Pixies -- "Tame" (*Doolittle*, 1989) **[SINGLE]** | Whisper-to-scream within a bar: attack overshoot and release recovery of every stage at once. | What Hi-Fi dynamics list |
| Imogen Heap -- "Hide and Seek" (2005) **[SINGLE]** | A cappella vocoder with silence between words: gate / hold behaviour, leveler decay ringing (the Advanced Dynamics "solo bell" class of fault). | LEA |
| Arvo Part -- *Tabula Rasa* (ECM, 1984) **[BROAD]** | Very long near-silent tails: leveler ringing and noise-floor pull-up. | What Hi-Fi classical; Headphonesty classical |
| A Gershwin piece (e.g. *Rhapsody in Blue*) **[SINGLE]** | Quiet orchestral passages for AGC gate thresholds and noise pumping. | RadioDiscussions "Omnia Processing Question" |

## 5. Wide dynamics: classical, solo piano, orchestral peaks (Classical / Wide Dynamics profile)

| Track | Listen for | Source |
| ----- | ---------- | ------ |
| Tchaikovsky -- *1812 Overture*, Kunzel / Cincinnati Pops (Telarc, 1979) **[BROAD]** | Real cannons: sub-30 Hz energy into the HPF / bass clipper, single-shot overshoot in the final limiter. | Headphonesty classical |
| Mahler -- Symphony No. 2, Bernstein / NYPO (DG) **[BROAD]** | IM during dense orchestral climaxes with voices -- the composite-clipper IM case, plus ppp-fff range for the AGC. | What Hi-Fi classical; Headphonesty classical |
| Strauss -- *Also sprach Zarathustra*, Reiner / CSO (RCA, 1954) **[BROAD]** | Sustained organ pedal plus pre-emphasised brass: the bass-vs-HF-limiter fight. | Headphonesty classical |
| Chopin -- Nocturnes, Rubinstein (RCA) / Debussy -- "Clair de Lune" **[BROAD]** | Solo piano: the classic AGC-pumping and leveler-hold reveal. | Headphonesty classical; What Hi-Fi classical |
| Tool -- *Aenima* (1996) **[SINGLE]** | A loud-genre master with real dynamic range -- the control against *Death Magnetic*. | Bob Katz, Digido Honor Roll |
| Keith Jarrett -- *The Koln Concert* (1975) **[OWN]** | Long, sparse, live solo piano for a slow AGC test; widely praised, no engineer citation found. | -- |

## 6. Stereo image / L-R load (stereo widener, stereo-image protection, 38 kHz sidebands)

| Track | Listen for | Source |
| ----- | ---------- | ------ |
| Pink Floyd -- "Money" (1973) **[BROAD]** | Hard-panned cash-register loop over a centred core: large discrete L-R excursions against mono. | LEA; Digido Honor Roll |
| Michael Jackson -- "Billie Jean" (1982) **[BROAD]** | Precisely placed image that L-R limiting or widening must not smear. | Sonarworks; Gearspace |
| Thievery Corporation -- "Lebanese Blonde" (2000) **[SINGLE]** | Each instrument distinctly positioned. | LEA |
| OutKast -- "B.O.B." (2000) **[SINGLE]** | Stereo-panned vocals and spatial effects at breakneck density. | Headphonesty (Harman) |
| Cowboy Junkies -- "Sweet Jane" (see section 2) | Diffuse single-point pickup: stereo-subcarrier / multipath load. | RadioDiscussions |

No broadcast source names a track specifically for multipath or L-R limiting; that category is under-documented.

## 7. Speech and exposed voice (Speech / Talk profile)

| Track | Listen for | Source |
| ----- | ---------- | ------ |
| EBU SQAM CD -- female / male speech (English, French, German) **[BROAD]** | Standards-grade speech, freely downloadable. | EBU Tech 3253 |
| Suzanne Vega -- "Tom's Diner" (see section 2) | Naked voice. | NPR |
| Frank Zappa -- "Lucille Has Messed My Mind Up" (1979) **[SINGLE]** | "A great, very natural sounding vocal." | Mix (Mark Dowdle, Steely Dan FOH) |
| Pentatonix -- "Hallelujah" **[SINGLE]** | Fully a cappella: harmonic interaction and breaths. | LEA |
| A clean news read (e.g. any BBC World Service bulletin) **[OWN]** | The practical broadcast speech test; no published citation. | -- |

## 8. Full-spectrum sanity (overall balance, transients, image at once)

| Track | Listen for | Source |
| ----- | ---------- | ------ |
| Tracy Chapman -- "Fast Car" (1988) **[BROAD]** | Harman / NRC reference since 1988: long-term spectrum near pink noise, highest listener discrimination after pink noise itself. | Audio Science Review (Sean Olive); Headphonesty |
| Donald Fagen -- "I.G.Y." (*The Nightfly*, 1982) **[BROAD]** | Impeccable early-digital master with intact transients -- what a processor should not remove. | Mix; Digido Honor Roll; Gearspace |
| Steely Dan -- "Gaslighting Abbie" (2000) / "Black Cow" **[BROAD]** | Lows, mids, highs equally represented. | LEA; Sonarworks |
| Dire Straits -- "Money for Nothing" (1985) **[BROAD]** | Quiet intro into the riff: AGC plus transient impact and density in one track. | Mix (Jeff Pitt); Headphonesty |
| AC/DC -- "Back in Black" (1980) **[BROAD]** | Punchy but unsquashed rock, the control against section 1's loud masters. | Sweetwater; Gearspace |

## Minimal regression set per stage

| Stage under test | Tracks |
| ---------------- | ------ |
| Phase rotator / asymmetry / peak control | "Black and White"; "Josie" |
| HF Limiter, Audio Limiter HF look-ahead (pre-emphasis) | "Sweet Jane"; "Torn"; SQAM castanets + glockenspiel |
| Bass clipper IM | "Killing Me Softly"; "Angel"; Fear Factory drop; Telarc *1812* |
| AGC / Advanced Dynamics pumping and hold | "Darkness"; "In the Air Tonight"; "Centerfield"; solo piano |
| Composite clipper on pre-clipped masters | *Death Magnetic*; "Vertigo"; "Bad Romance" |
| Stereo subcarrier / L-R | "Money"; "Billie Jean"; "Sweet Jane" |
| Speech | SQAM speech; "Tom's Diner" |
| Overall balance | "Fast Car"; "I.G.Y." |

## Sources

RadioDiscussions threads: "Using Breakaway as a FM processor / stereo encoder" (p.2), "Breakaway Broadcast Processor", "Digimod cards for Orban 8100", "Omnia Processing Question". Gearspace: "Excellent recordings to test studio monitors", "Reference tracks for mixing vs mastering", "Mastering for the Optimod (FM radio)", "What's your favorite reference tracks". Mix magazine: "Music to Tune a PA By", Steely Dan PA blog. LEA Professional "System Testing Playlist". Sound On Sound, Mike Senior, "Creating Your Own Reference CD". Bob Katz, Digido "Honor Roll". Sonarworks "Community reference track run-down". Headphonesty engineer-sourced lists (2026). What Hi-Fi test-track features. Audio Science Review, "Dr. Sean Olive on 35 years of Fast Car". Radio ILOVEIT interviews with Frank Foti (parts 1-2) and Bob Orban (part 2). Radio World, Gary Kline, "11 Processing Things to Think About". Production Advice (Ian Shepherd) on *Random Access Memories*. EBU Tech 3253 (SQAM CD). NPR / Wikipedia on "Tom's Diner". Wikipedia "Loudness war".
