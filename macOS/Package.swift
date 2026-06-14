// swift-tools-version: 6.0
import PackageDescription

// Absolute path to this manifest's directory (the package root), so the
// embedded-Info.plist linker flag below resolves regardless of the shell
// CWD that `swift build` was invoked from.
let packageDir = #filePath.hasSuffix("/Package.swift")
    ? String(#filePath.dropLast("/Package.swift".count))
    : "."

let package = Package(
    name: "MPXPrime",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "MPXPrime", targets: ["MPXPrime"]),
        .executable(name: "MPXPrimeMeter", targets: ["MPXPrimeMeter"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    ],
    targets: [
        // Small C target that exposes the FTZ/DAZ helper. Swift cannot
        // write the MXCSR / FPCR control registers directly, so this
        // shim lives in C and is called from the audio thread once per
        // render callback entry. See MPXPrimeNative.h for rationale.
        .target(
            name: "MPXPrimeNative",
            path: "Sources/MPXPrimeNative",
            publicHeadersPath: "include"
        ),
        // Shared DSP library: foundational filter primitives (Biquad,
        // BiquadCascade6, DeemphasisFilter) + the reusable MPXDecoder.
        // Depended on by the transmit app (MPXPrime) and, in future, the
        // MPXPrimeMeter companion analyzer. Hot per-sample process()
        // methods are @inlinable so they still inline across this module
        // boundary in release builds. See DSPPrimitives.swift for the
        // cross-module-inlining rationale.
        .target(
            name: "MPXPrimeCore",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
                "MPXPrimeNative"
            ],
            path: "Sources/MPXPrimeCore"
        ),
        // Shared SwiftUI: Canvas-based, signal-agnostic UI components
        // (scope, spectrum, vertical meter, style tokens, the LiveTelemetry
        // isolation wrapper) used by both the transmit GUI (MPXPrime) and the
        // MPX Prime Meter window. Depends only on MPXPrimeCore.
        .target(
            name: "MPXPrimeUI",
            dependencies: ["MPXPrimeCore"],
            path: "Sources/MPXPrimeUI"
        ),
        .executableTarget(
            name: "MPXPrime",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
                "MPXPrimeNative",
                "MPXPrimeCore",
                "MPXPrimeUI"
            ],
            path: "Sources/MPXPrime",
            linkerSettings: [
                // Embed an Info.plist into the Mach-O so LaunchServices shows
                // "MPX Prime Studio" (CFBundleName) in the Apple menu / Dock even for
                // the unbundled binary (swift run / .build/release/MPXPrime).
                // The shipped .app bundle's own Info.plist takes precedence
                // when bundled.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(packageDir)/Resources/MPXPrime-Info.plist",
                ])
            ]
        ),
        // MPX Prime Meter: companion MPX composite analyzer. Headless CLI for
        // now (live capture + offline self-test); the SwiftUI window is a later
        // increment. Depends only on the shared MPXPrimeCore library (which
        // transitively pulls in Atomics + MPXPrimeNative), reusing the same
        // input capture, decode, and analysis code as the transmit app.
        .executableTarget(
            name: "MPXPrimeMeter",
            dependencies: [
                "MPXPrimeCore",
                "MPXPrimeUI",
                .product(name: "Atomics", package: "swift-atomics")
            ],
            path: "Sources/MPXPrimeMeter",
            linkerSettings: [
                // Embed an Info.plist so the unbundled binary shows
                // "MPX Prime Meter" in the menu/Dock (see MPXPrime above).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(packageDir)/Resources/MPXPrimeMeter-Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "MPXPrimeTests",
            dependencies: ["MPXPrime", "MPXPrimeNative", "MPXPrimeCore", "MPXPrimeUI"],
            path: "Tests/MPXPrimeTests"
        )
    ]
)
