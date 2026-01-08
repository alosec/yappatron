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
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.0"),
        .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Yappatron",
            dependencies: [
                "Starscream",
                "HotKey"
            ],
            path: "Sources"
        )
    ]
)
