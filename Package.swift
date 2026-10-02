// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrendDemoLauncher",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Pinned below 1.12.0 — that release added a Metal renderer whose shaders
        // require the separate Xcode Metal Toolchain to compile. 1.11.x needs no extra
        // toolchain and has the full LocalProcessTerminalView API we use.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", "1.11.0" ..< "1.12.0")
    ],
    targets: [
        .executableTarget(
            name: "TrendDemoLauncher",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/TrendDemoLauncher"
        )
    ]
)
