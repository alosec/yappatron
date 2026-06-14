// swift-tools-version: 5.9
import PackageDescription

let enableFluidAudio = Context.environment["YAPPATRON_ENABLE_FLUIDAUDIO"] == "1"

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.0"),
]

var targetDependencies: [Target.Dependency] = [
    "HotKey",
]

var swiftSettings: [SwiftSetting] = []

if enableFluidAudio {
    dependencies.append(.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.14.7"))
    targetDependencies.append("FluidAudio")
    swiftSettings.append(.define("YAPPATRON_ENABLE_FLUIDAUDIO"))
}

let package = Package(
    name: "Yappatron",
    platforms: [
        enableFluidAudio ? .macOS(.v14) : .macOS(.v12)
    ],
    products: [
        .executable(name: "Yappatron", targets: ["Yappatron"])
    ],
    dependencies: dependencies,
    targets: [
        .executableTarget(
            name: "Yappatron",
            dependencies: targetDependencies,
            path: "Sources",
            swiftSettings: swiftSettings
        )
    ]
)
