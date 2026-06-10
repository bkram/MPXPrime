# GUI: HIG Compliance + Professional Polish + Usability Pass

## Context

Full UI audit (two parallel review agents over `SwiftUIControlApp.swift` ~9250 lines + the seven `UI*.swift` components) found a strong foundation — semantic `BroadcastStyle` tokens with light/dark adaptation, correct NavigationSplitView/toolbar/Canvas patterns, clean `LiveTelemetry` separation, complete menu/shortcut structure — but four gap clusters that keep the GUI below Logic-Pro-grade polish:

1. **State feedback**: operators can't see which controls are live-apply vs restart-required; RDS text fields silently truncate/clamp; disabled states are invisible on bordered buttons; pending-restart state scrolls out of view.
2. **Visual consistency**: mixed button styles and label layouts between tabs; ad-hoc `.quaternary`/`.tertiary`/opacity colors bypassing `BroadcastStyle`; hardcoded spectrum palettes with no dark/light handling.
3. **Pleasantness**: explanatory prose still inside cards (plan.md UX backlog #1); no field placeholders; reset buttons buried at scroll bottom; no feedback on test-tone preset buttons; format-profile drift not shown.
4. **Accessibility**: meters announce value but not peak/scale/color meaning; dropout pill is color-only state (WCAG 2.1 AA); decorative LED not hidden; no Dynamic Type.

User opted for the **full four-phase pass including live status** on the overview grid + flow strip (per-stage GR readouts, bypass indication) — the "professional broadcast console" touch.

**Load-bearing constraints (violating these caused real regressions before):**
- Moving values draw in `Canvas`, never as layout (`.frame`/`.offset` tracking a live value is forbidden). Live readouts read from `LiveTelemetry` via `LiveTelemetryView` wrappers, never `@Published` on `MPXPrimeViewModel` (CHANGELOG 0.34 multi-hour GUI freeze).
- One source of tab help: `TabHelpBox` fed by tab-enum `helpText`. In-card captions only for distinct actionable guidance.
- Outcome-language labels; jargon in `.help()` tooltips. DisclosureGroup for expert controls (0.35 pattern).
- ASCII only in source. `swiftlint` accessibility rules must stay at 0 violations.
- UI-only change: composite output must be untouched (`--verify --baseline-strict` stays green with zero drift).

## Key files

- `macOS/Sources/MPXPrime/SwiftUIControlApp.swift` — most edits (view structs cataloged below)
- `macOS/Sources/MPXPrime/UIBroadcastStyle.swift` — new tokens
- `macOS/Sources/MPXPrime/UISignalFlowStrip.swift`, `UIProcessingOverview.swift`, `UIBroadcastMeter.swift`, `UIBroadcastStatusBar.swift`, `UIInspector.swift`
- `macOS/Sources/MPXPrime/AppConfig.swift` — read-only reference: `runtimeDisposition:` is the source of truth for live vs restart classification

View-struct map (from audit, for navigation): RootView 4989-5086, StageSidebarRow 5121-5153, StageProcessingContent 5210-5287, Card 5344-5390, SnapshotSlotRow 5440-5533, TestToneView 5535-5750, MonitoringDashboardView 5769-6270, Processing tabs 7341-8138, RDS tabs 8139-8998, PendingApplyCard ~8999, spectrum views 6896-7278.

---

## Phase 1 — State feedback (highest usability win)

### 1.1 Restart-required vs live-apply signaling
- New reusable `RestartBadge` view (small `arrow.trianglehead.clockwise` icon + "Restart" caption, `.help("Takes effect after restarting the engine")`), attached to the small set of restart-required controls. Identify them from `AppConfig.runtimeDisposition == .restart` (rds_level, rds_gaussian_*, pre-encode look-ahead settings, `mpx_clipper_oversampling`, sample rate / device / output mode). Do NOT badge every control — only the restart-required minority; live-apply is the default expectation.
- Promote pending-restart visibility: the status bar already shows a conditional Pending Restart chip (`UIBroadcastStatusBar.swift` ~line 98) — make it a Button that triggers the same apply-restart action as the menu (Shift-Cmd-A), and add a small pending dot to `StageSidebarRow` (5121-5153) for stages with pending restart-required edits.

### 1.2 RDS text-field validation feedback
- Inline character counters on PS (8), RT A-D (64), PTYN (8), Long PS (32), PI (4 hex) in `RDSProgramTab` / `RDSRadiotextTab` / `RDSLongPSTab` (8139-8398): trailing `Text("\(count)/8")` in `scaleLabel` font, secondary color, turning `tightAmber` at limit.
- Out-of-range / non-encodable input: red-tinted field border + caption (e.g. PI non-hex). Reuse the existing model-layer clamping (`oddTapBinding()` pattern at 2385-2395) but surface what was adjusted instead of silently fixing — a one-line caption "adjusted to nearest valid value" that appears briefly.
- Gaussian taps field (RDSCarrierTab 8399-8422): replace bare TextField with TextField + Stepper (step 2, odd-only), keeping the existing odd-clamping binding.

### 1.3 Disabled-state visibility
- Sweep all `.disabled(...)` bordered/plain buttons (SnapshotSlotRow Load/Clear 5482-5499 is the worst case) — ensure visible dimming (`.opacity(0.4)` when disabled, or foreground secondary).
- Parent-enable gating sweep: every child control disables (and dims) when its stage/feature toggle is off. Audit flagged PrimeBass subharmonics (7467-7502); check each Processing tab systematically while in there.

### 1.4 Destructive-action dialogs with context
- Snapshot Clear and tab Reset confirmations name what's affected: snapshot name/slot + saved date; "Reset <tab name> (N settings)". Sites: SnapshotSlotRow 5508-5520, StageProcessingContent reset 5265-5270, StageRDSContent 8313-8318.

## Phase 2 — Visual consistency / professional look

### 2.1 BroadcastStyle token completion
- Add tokens in `UIBroadcastStyle.swift`: `stagePillBackground`, `terminalPillBackground`, `connectorLine`, `scaleTick` — replace the ad-hoc `.quaternary.opacity(0.4)` / `.tertiary.opacity(0.18)` / `.tertiary.opacity(0.5)` in `UISignalFlowStrip.swift` (107, 140, 150) and `Color.primary.opacity(0.32)` in `UIBroadcastMeter.swift` (93).
- Spectrum palettes (`AudioBarSpectrumView` 6982-6986, `MPXSpectrumView` 7165-7169): move hardcoded color arrays into `BroadcastStyle` with `Color.adaptive()` light/dark variants (existing helper at UIBroadcastStyle 158-167), tuned so dark mode keeps contrast.

### 2.2 Control standardization
- One button convention: snapshot Save/Load/Clear (5482-5499) get `.buttonStyle(.bordered)` like the rest of the app.
- One labeled-row convention: extend the existing `DoubleSliderRow` / `LabeledContent` patterns so TestToneView (5612-5680) and the Processing tabs use the same label-alignment layout; extract a shared row helper if the diff shows more than ~3 layout variants.
- Test-tone preset buttons (5670): highlight the active preset (`.borderedProminent` or tint) when `freq` matches the current config value.
- Section sub-headers inside dense cards (Multiband per-band groups, PEQ bands): lightweight `Text(...).font(.subheadline.weight(.semibold))` + divider, NOT new cards — improves scannability without changing structure.

### 2.3 Format-profile drift indicator
- When config drifts from the selected Format Profile (the "Custom" sentinel already exists in the model ~5497), show the picker label italic/secondary with an "edited" suffix so operators see they're off-preset. ProcessingFormatProfileTab 7341-7368.

## Phase 3 — Pleasant + informative (incl. live status)

### 3.1 Prose-to-tooltip sweep (plan.md UX backlog #1)
- Move in-card explanatory `Text` blocks to `.help()` on the owning control or into the tab's `helpText` (TabHelpBox). Flagged sites: input-level guidance 5996, "Dropouts (10 s)" 6082, inspector explanatory text per control (UIInspector), plus a systematic sweep of all Processing/RDS tabs. Keep only safety-critical one-liners and distinct actionable tips inline (per CLAUDE.md rule).
- RDS field placeholders: `TextField("8-char station name", ...)`-style prompts on PS/RT/PI/PTYN/Long PS.

### 3.2 Reset placement
- Move per-tab Reset out of scroll-bottom into the fixed tab header row (right-aligned, `.bordered`), so it has a stable location. StageProcessingContent 5223-5285 + StageRDSContent 8293-8330.

### 3.3 Overview grid live status (user-approved)
- `UIProcessingOverview.swift`: add a one-line live readout to cards whose stage has a GR/state metric (AGC gain, multiband state, limiter GR, composite clipper GR, safety GR — all already on `LiveTelemetry`: agcStateText, multibandStateText, limiterStateText, compositeClipperGainReductionDBValue, etc.). RULES: text-only readout inside a `LiveTelemetryView` leaf; no frame/offset tracking; reuse `valueReadout` font.
- Stronger enabled affordance: 6pt leading status dot on each card (accent when enabled, panelBorder when off) — matches StageSidebarRow vocabulary.

### 3.4 Signal-flow strip stage state (user-approved)
- `UISignalFlowStrip.swift`: disabled stages render dimmed (secondary text + reduced-opacity pill, optional strikethrough-free "off" affix in tooltip). Reads config enable flags (static state, not telemetry — no perf concern). Keep pills clickable as-is.

## Phase 4 — Accessibility

- **Dropout pill (5996-6122)**: add an SF Symbol matching the state (checkmark/exclamation) so state is not color-only.
- **Meters (`UIBroadcastMeter.swift` 59-64)**: extend `.accessibilityValue` to "current X dB, peak Y dB" and add `.accessibilityHint` explaining green/amber/red; include scale range in the label.
- **Status bar (`UIBroadcastStatusBar.swift`)**: `.accessibilityHidden(true)` on the decorative transport LED (113); explicit `.accessibilityLabel` on the RDS-warning and pending-restart chips describing the alert.
- **Meter/status group summaries** (plan.md UX backlog #3): one combined element per meter cluster summarizing input/output/GR for VoiceOver; high-frequency repaints stay hidden from the announcer.
- **Dynamic Type spot-check**: BroadcastStyle fonts are semantic (`caption2`, `callout` etc.) so they scale; verify no fixed-height container clips at larger text sizes (status bar 22pt divider, meter value rows) and fix clipping with `minimumScaleFactor` where needed.
- Inspector toggles get `.accessibilityHint` describing broadcast impact.

---

## Explicitly NOT doing (scope guards)

- No navigation restructure (NavigationSplitView + sidebar + inspector layout stays).
- No new windows, no onboarding flow, no Settings-scene rework.
- No violation of the Canvas/LiveTelemetry rules — every new live readout is a `LiveTelemetryView`-wrapped text leaf; nothing layout-tracks a live value. The 8 Hz "readout pulse" stays dead.
- No re-wording pass beyond moving prose — label language was done in 0.35.
- No `MPXGenerator`/DSP changes; zero impact on composite output.

## Order of work (each step lands buildable + lint-clean)

1. Phase 2.1 tokens first (mechanical, everything else builds on them).
2. Phase 1 state feedback (1.1 → 1.4).
3. Phase 2.2-2.3 control standardization.
4. Phase 3 (prose sweep, reset placement, then live status 3.3/3.4 last — the only perf-sensitive piece, soak-checked).
5. Phase 4 accessibility.

## Verification

- `swift build --package-path macOS -c release` clean after each phase.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint` — 0 violations (accessibility lint).
- `DEVELOPER_DIR=... swift test --package-path macOS` — full suite green (ProcessingTabStageMappingTests guards tab/stage wiring; RDS live-apply tests unaffected).
- `swift run ... --verify --baseline-strict` — zero drift (UI-only change must not touch DSP).
- Manual smoke (release build, real device): every Processing/RDS tab renders in light + dark mode; restart badges appear only on restart-required controls; RDS counters track input; pending-restart chip clickable; overview live readouts update while running; flow strip dims disabled stages.
- **Perf guard for 3.3/3.4**: with the Monitoring window + overview grid visible, leave running 30+ min and confirm flat memory / no toolbar-recreation symptoms (the 0.34 freeze signature); verify live readouts are inside `LiveTelemetryView` by code review.
- Manual VoiceOver pass over status bar, one meter cluster, one Processing tab, dropout pill (release-checklist item for UI changes).
