// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "rvpn-ios-app",
    platforms: [.iOS(.v17)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "rvpn-ios-app",
            path: "Sources/rvpn-ios-app",
            linkerSettings: [
                .unsafeFlags(["-L", "Sources/rvpn-ios-app/Libs"]),
                .linkedLibrary("rvpn_mobile"),
                .linkedLibrary("c++"),
                .linkedFramework("NetworkExtension"),
                .linkedFramework("Network")
            ]
        )
    ]
)
