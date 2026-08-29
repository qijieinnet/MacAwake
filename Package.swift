// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacAwake",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacAwake",
            path: "Sources/MacAwake",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
