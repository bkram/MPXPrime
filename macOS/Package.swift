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
        .executableTarget(
            name: "MPXPrime",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics")
            ],
            path: "Sources/MPXPrime"
        ),
        .testTarget(
            name: "MPXPrimeTests",
            dependencies: ["MPXPrime"],
            path: "Tests/MPXPrimeTests"
        )
    ]
)
