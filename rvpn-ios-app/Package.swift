// swift-tools-version:5.9
import PackageDescription

let engineLinker: [LinkerSetting] = [
    .unsafeFlags(["-L", "Sources/rvpn-ios-app/Libs"]),
    .linkedLibrary("rvpn_mobile"),
    .linkedLibrary("c++"),
    .linkedFramework("NetworkExtension"),
    .linkedFramework("Network"),
]

let package = Package(
    name: "rvpn-ios-app",
    platforms: [.iOS(.v17)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "rvpn-ios-app",
            path: "Sources/rvpn-ios-app",
            linkerSettings: engineLinker
        ),
        .executableTarget(
            name: "rvpn-tunnel-provider",
            path: "Sources/rvpn-tunnel-provider",
            linkerSettings: engineLinker + [
                // Extension host runtime: provides main() for app extensions
                .linkedFramework("ExtensionFoundation"),
            ]
        ),
    ]
)
