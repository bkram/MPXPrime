import Testing
import Foundation
@testable import MPXPrime

// Thin @Test wrapper that delegates to `BenchmarkRunner` (in Sources/).
//
// Gated on the MPXPRIME_BENCH env var so it does not run on every
// `swift test`. Run with release optimizations on the dev machine:
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     MPXPRIME_BENCH=1 swift test -c release --package-path macOS --filter Benchmark
//
// The actual bench logic lives in Sources/MPXPrime/BenchmarkRunner.swift
// so the same report can be produced via `MPXPrime --bench` on a
// machine that only has Command Line Tools (no full Xcode required).

@Suite("Benchmark suite")
struct BenchmarkSuite {

    @Test func runBenchmarkIfRequested() {
        guard ProcessInfo.processInfo.environment["MPXPRIME_BENCH"] != nil else {
            return
        }
        let report = BenchmarkRunner().run()
        print(report)
    }
}
