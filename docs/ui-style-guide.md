# MPX Prime Studio -- UI style guide

The rules every page, card and window in MPX Prime Studio follows. They came
out of the October 2026 layout review and are implemented in
`Sources/MPXPrime/UI/PageScaffold.swift`, the `Stage` name table in
`Sources/MPXPrime/UI/NavigationModel.swift` and
`Sources/MPXPrime/Control/WebUI/schema.json`. The web dashboard follows the
same tables.

## Page anatomy

Every page, including Monitoring, Audio I/O, Test Tone and Presets:

1. Title: the sidebar label, exactly.
2. Subtitle: one plain sentence saying what the page is for.
3. Content: `.padding(20)`, `.frame(maxWidth: 1120)`, 16 pt between
   cards.
4. Reset button, bottom right, "Reset" followed by the page title.
5. `TabHelpBox`, text from the page's enum `helpText`.

A card title names a part of the page. It never repeats the page title.
A page with one card uses no card title.

## One card style

| Use | Component | Values |
| --- | --- | --- |
| Settings group | `Card(.standard)` | radius 10, padding 12, row spacing 8, title `.headline` secondary |
| Live readouts | `Card(.meter)` | radius 10, padding 10, row spacing 6 |
| Tile inside a card | `InsetTile` | radius 8, padding 10, `meterSurface` 0.65 |
| Chips and pills | `Chip` | radius 4 |

No hand-built `RoundedRectangle` backgrounds outside these.

## Labels and casing

| Rule | Example |
| --- | --- |
| British English in every UI string | "Programme", "Colour", "Centre" |
| Title Case for page, card, window, menu, button, picker, slider and toggle labels | "Look-Ahead", "True-Peak Ceiling", "Programme-Dependent Release" |
| Hyphenated compounds: capitalise both parts | "Look-Ahead", not "Look-ahead" |
| Sentence case for captions, tooltips, help boxes, status text | "Re-applies the profile's stage settings." |
| No ALL CAPS in labels; the status bar may use small caps via `.textCase(.uppercase)` on Title Case source strings | "Restart Pending" rendered as RESTART PENDING |
| A stage has one name. The sidebar label is the master; card titles, Overview cards, flow-strip chips, reset buttons and web labels derive from it. Chips may abbreviate from one table. | Audio Clipper / "Audio Clip" |
| Enable toggles read "Enable" plus the stage name at the top of the card | "Enable Mono Bass" |
| Mode names are always `OperatingMode.title` | "FM Output" |
| ASCII only in UI strings | "--" not an em dash |

## Which control for which setting

| Kind of setting | Control |
| --- | --- |
| Continuous value with a unit | `DoubleSliderRow` (slider, readout, reset arrow) |
| On/off of a stage | `Toggle` with `.switch` style, first row of the card |
| On/off option within a stage | `Toggle` (checkbox) |
| 2-4 exclusive options | `Picker` `.segmented` |
| 5+ options or a named preset | `Picker` `.menu` |
| Exact number the operator types (frequency, port, PI, ECC) | `TextField` with a formatter, unit after the field |
| Small integer counts | `Stepper` with the value in the label |
| Time zone | `Picker` `.menu` in 0.25 h steps |

## Units and numbers

| Rule | Example |
| --- | --- |
| Every number shows its unit | "-3.0 dB", "2.0 kHz" |
| Levels and thresholds in dB or dBFS, never linear | Audio Limiter "Ceiling -0.4 dBFS" |
| Unitless 0-1 amounts shown as percent | "Amount 35%" |
| Deviation and injections in kHz; percent of deviation as a secondary readout | "RDS 2.0 kHz (2.7%)" |
| Space before a unit, none before % | "75.0 kHz", "9.0%" |
| Rates in kHz | "192 kHz" |
| One decimal for dB and kHz, none for Hz and ms above 10 | "16000 Hz", "150 ms" |

## Help text

| Where | What |
| --- | --- |
| `TabHelpBox` (bottom of page) | What the page is for. One per page, from the enum. |
| Tooltip (`.help`) | Mechanism, standards, patents, ranges. |
| Caption under a control | Only a distinct action or a safety point. At most one per card. |
| Never | Vendor model numbers, INI keys, country-specific defaults on labels or captions. |

## Restart-required

| Rule | How |
| --- | --- |
| The badge is derived from the binding's disposition, not hand-placed | `DoubleSliderRow`, `Toggle` and `Picker` wrappers read `runtimeDisposition == .restart` |
| One status chip-button | "Restart to Apply" |
| One generated restart list | from the key table, used by Help, tooltips and docs |
| No captions listing restart keys | the badge says it |

## Meters

Use `LadderMeterView` for every level in Studio: Monitoring, Audio I/O and
the Levels window. -60 to 0 dBFS, Prime Mixer ballistics, one colour rule.
The MPX Prime Meter still uses `VerticalMeterStrip`; migrating it is a
separate decision (see `docs/project-roadmap.md`).

## Windows

| Rule | How |
| --- | --- |
| One header and one size table | every monitoring window uses `MonitoringWindowHeader`, `.padding(20)`, sizes from one table in `UI/AppConstants.swift` |
| Header controls | right-aligned, same order: source (Pre/Post), then options |
| Titles | Levels, Audio Spectrum, MPX Spectrum, Scopes |
