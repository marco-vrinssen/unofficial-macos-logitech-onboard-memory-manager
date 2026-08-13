// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LogiOnboard",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LogiHIDPP"),
        .executableTarget(name: "lomm", dependencies: ["LogiHIDPP"]),
        .executableTarget(name: "LogiOnboardApp", dependencies: ["LogiHIDPP"]),
    ]
)
