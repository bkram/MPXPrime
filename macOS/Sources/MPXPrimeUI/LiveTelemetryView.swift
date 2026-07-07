import SwiftUI

// Observes ONLY the supplied telemetry object, so wrapping a live widget in
// this view confines a metering tick's re-evaluation + layout to the wrapped
// subtree. The enclosing card / Form holds the view model and passes its
// telemetry object in WITHOUT observing it -- handing an object to a child
// initializer does not subscribe the parent -- so the card body does not
// re-evaluate on a tick. Keep the wrapped content a fixed-size Canvas leaf
// (meter / scope / spectrum) or a fixed-width readout so the repaint never
// propagates a layout change back out to the card.
//
// Generic over the telemetry type so both apps reuse the isolation pattern:
// MPXPrime's LiveTelemetry (ObservableObject) uses LiveTelemetryView; the
// Meter's MeterTelemetry (@Observable macro) uses LiveObservationView below.
public struct LiveTelemetryView<Telemetry: ObservableObject, Content: View>: View {
    @ObservedObject var telemetry: Telemetry
    @ViewBuilder let content: (Telemetry) -> Content

    public init(
        telemetry: Telemetry,
        @ViewBuilder content: @escaping (Telemetry) -> Content
    ) {
        self.telemetry = telemetry
        self.content = content
    }

    public var body: some View {
        content(telemetry)
    }
}

// The same isolation pattern for an @Observable-macro telemetry object.
// No @ObservedObject / objectWillChange: SwiftUI's Observation tracking
// registers exactly the properties `content` READS during body evaluation,
// so a telemetry tick re-evaluates only the leaves whose read values
// actually changed -- and, unlike the ObservableObject bridge, the per-tick
// dependency-tracking cost stays flat over long sessions (the bridge's
// registrar accumulated key-path tracking until the GUI lagged and the
// audio thread starved; profiled on the Meter, ~36% -> ~87% CPU in 14 min).
public struct LiveObservationView<Telemetry: AnyObject, Content: View>: View {
    let telemetry: Telemetry
    @ViewBuilder let content: (Telemetry) -> Content

    public init(
        telemetry: Telemetry,
        @ViewBuilder content: @escaping (Telemetry) -> Content
    ) {
        self.telemetry = telemetry
        self.content = content
    }

    public var body: some View {
        content(telemetry)
    }
}
