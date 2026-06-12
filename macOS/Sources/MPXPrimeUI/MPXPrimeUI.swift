// MPXPrimeUI — shared SwiftUI components for the MPX Prime transmit GUI and
// the MPX Prime Meter window. All views here are Canvas-based and
// signal-agnostic (they take plain [Float]/Double + display scalars, never
// app-specific view models), so both apps can render the same scopes,
// spectrum, meters and style without duplication.
//
// Components are added in the 0.37 GUI work: BroadcastStyle, VerticalMeterStrip,
// LiveTelemetryView, ScopeView, MPXSpectrumView.

import SwiftUI
