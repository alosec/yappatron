// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Yappatron",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Yappatron", targets: ["Yappatron"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.1"),
        .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.0"),
        .package(url: "https://github.com/metasidd/Orb.git", from: "0.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Yappatron",
            dependencies: [
                "FluidAudio",
                "HotKey",
                "Orb"
            ],
            path: "Sources"
        )
    ]
)
