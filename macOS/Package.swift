// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Absolute path to this manifest's directory (the package root), so the
// embedded-Info.plist linker flag below resolves regardless of the shell
// CWD that `swift build` was invoked from.
let packageDir = #filePath.hasSuffix("/Package.swift")
    ? String(#filePath.dropLast("/Package.swift".count))
    : "."

// Repo root (one level above the SPM package at macOS/). The vendored RTL-SDR
// tuner C++ lives in repo-root tuner/; the CMPXTuner target compiles it.
let repoRoot = "\(packageDir)/.."

// Homebrew prefix for the arm64 RTL-SDR deps (librtlsdr / liquid-dsp). The
// CMPXTuner target (and therefore the MPX Prime Meter executable that links it)
// is Apple-Silicon-only; the encoder app stays universal. Overridable via
// HOMEBREW_PREFIX for non-default Homebrew installs.
let brewPrefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] ?? "/opt/homebrew"

// Optional SDRplay RSP support: build the SDRplay backend only when the
// proprietary SDK headers are installed (/Library/SDRplayAPI/<ver>/include).
// The runtime library is dlopen'd (never linked/bundled), so a build without
// the SDK simply omits SDRplay and the Meter falls back to RTL-SDR.
let sdrplayInclude: String? = {
    let base = "/Library/SDRplayAPI"
    guard let versions = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
    for v in versions.sorted(by: >) {   // newest first
        let inc = "\(base)/\(v)/include"
        if FileManager.default.fileExists(atPath: "\(inc)/sdrplay_api.h") { return inc }
    }
    return nil
}()
var cmpxTunerCxx: [CXXSetting] = [
    .headerSearchPath("include"),
    .unsafeFlags(["-I\(repoRoot)/tuner/include", "-I\(brewPrefix)/include"]),
    .define("FM_TUNER_HAS_RTLSDR")
]
if let sdrplayInclude {
    cmpxTunerCxx.append(.unsafeFlags(["-I\(sdrplayInclude)"]))
    cmpxTunerCxx.append(.define("FM_TUNER_HAS_SDRPLAY"))
}

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
        // Vendored RTL-SDR -> FM demod -> MPX composite tuner, compiled as a
        // C++ library with a pure-C public ABI (mpx_tuner_capi.h) so Swift
        // imports it as a Clang module. The .cpp shims here include the
        // canonical sources in repo-root tuner/ (SPM cannot list sources
        // outside the package root). Links the arm64-only Homebrew librtlsdr /
        // liquid-dsp, which makes MPX Prime Meter Apple-Silicon-only; build the
        // x86_64 release slice with `--product MPXPrime` so this target (and
        // the Meter) are skipped on Intel.
        .target(
            name: "CMPXTuner",
            path: "Sources/CMPXTuner",
            publicHeadersPath: "include",
            cxxSettings: cmpxTunerCxx,
            linkerSettings: [
                .unsafeFlags(["-L\(brewPrefix)/lib"]),
                .linkedLibrary("rtlsdr"),
                .linkedLibrary("liquid")
            ]
        ),
        // Canonical 24-bit WAV writer + the Meter's recorder, isolated in a
        // pure-Foundation library so the recording path is unit-testable (the
        // MPXPrimeMeter executable target itself can't be imported by tests).
        .target(
            name: "MPXPrimeRecording",
            path: "Sources/MPXPrimeRecording"
        ),
        // MPX Prime Meter: companion MPX composite analyzer.
        .executableTarget(
            name: "MPXPrimeMeter",
            dependencies: [
                "MPXPrimeCore",
                "MPXPrimeUI",
                "MPXPrimeRecording",
                "CMPXTuner",
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
            dependencies: ["MPXPrime", "MPXPrimeNative", "MPXPrimeCore", "MPXPrimeUI", "MPXPrimeRecording"],
            path: "Tests/MPXPrimeTests"
        )
    ],
    cxxLanguageStandard: .cxx17
)
