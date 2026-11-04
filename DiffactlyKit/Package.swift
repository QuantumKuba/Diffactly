// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiffactlyKit",
    platforms: [.macOS(.v13)],
    products: [
        // The diff engine shared by the Diffactly app and the `diffactly` command-line tool.
        .library(name: "DiffactlyCore", targets: ["DiffactlyCore"]),
        // `diffactly left.txt right.txt` — terminal front end for the same engine.
        .executable(name: "diffactly", targets: ["diffactly"]),
    ],
    targets: [
        .target(name: "DiffactlyCore"),
        .executableTarget(name: "diffactly", dependencies: ["DiffactlyCore"]),
        .testTarget(name: "DiffactlyCoreTests", dependencies: ["DiffactlyCore"]),
    ]
)
