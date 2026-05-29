// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MPXPrime",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "MPXPrime", targets: ["MPXPrime"])
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
            path: "Sources/MPXPrimeCore"
        ),
        .executableTarget(
            name: "MPXPrime",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
                "MPXPrimeNative",
                "MPXPrimeCore"
            ],
            path: "Sources/MPXPrime"
        ),
        .testTarget(
            name: "MPXPrimeTests",
            dependencies: ["MPXPrime", "MPXPrimeNative", "MPXPrimeCore"],
            path: "Tests/MPXPrimeTests"
        )
    ]
)
