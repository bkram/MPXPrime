import SwiftUI

// Canvas waveform oscilloscope (shared). Takes a primary sample buffer and an
// optional secondary (e.g. the right channel), both plain [Float] clamped to
// +/-1.0 for display. Signal-agnostic: the transmit monitor and the Meter
// both feed it.
public struct ScopeView: View {
    let samples: [Float]
    var secondarySamples: [Float]?

    public init(samples: [Float], secondarySamples: [Float]? = nil) {
        self.samples = samples
        self.secondarySamples = secondarySamples
    }

    public var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(roundedRect: rect, cornerRadius: BroadcastStyle.panelInsetCornerRadius), with: .color(.black.opacity(0.22)))

            var grid = Path()
            let midY = size.height * 0.5
            grid.move(to: CGPoint(x: 0, y: midY))
            grid.addLine(to: CGPoint(x: size.width, y: midY))
            for i in 1..<4 {
                let x = size.width * (CGFloat(i) / 4.0)
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)

            func makeWavePath(samples: [Float]) -> Path {
                guard samples.count > 1 else { return Path() }
                let stepX = size.width / CGFloat(samples.count - 1)
                var wave = Path()
                for (idx, sample) in samples.enumerated() {
                    let clamped = max(-1.0, min(1.0, sample))
                    let x = CGFloat(idx) * stepX
                    let y = midY - (CGFloat(clamped) * amplitude)
                    if idx == 0 {
                        wave.move(to: CGPoint(x: x, y: y))
                    } else {
                        wave.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                return wave
            }

            guard samples.count > 1 else { return }
            let amplitude = max(10.0, size.height * 0.46)
            if let secondarySamples {
                context.stroke(
                    makeWavePath(samples: secondarySamples),
                    with: .color(.cyan.opacity(0.85)),
                    lineWidth: 1.1
                )
            }
            context.stroke(
                makeWavePath(samples: samples),
                with: .color(.green.opacity(0.90)),
                lineWidth: 1.2
            )
        }
        .frame(minHeight: 130, idealHeight: 150)
        .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
        // A Canvas exposes no children; without this it is silent noise to
        // VoiceOver. Give the region a name + image role.
        .accessibilityElement()
        .accessibilityLabel("Waveform scope")
        .accessibilityAddTraits(.isImage)
    }
}
