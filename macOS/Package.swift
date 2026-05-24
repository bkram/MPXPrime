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
        .executableTarget(
            name: "MPXPrime",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
                "MPXPrimeNative"
            ],
            path: "Sources/MPXPrime"
        ),
        .testTarget(
            name: "MPXPrimeTests",
            dependencies: ["MPXPrime", "MPXPrimeNative"],
            path: "Tests/MPXPrimeTests"
        )
    ]
)
