// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Luma",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Luma", targets: ["StreamApp"])],
    targets: [
        .target(name: "StreamCore"),
        .binaryTarget(name: "VLCKit", path: "Vendor/VLCKit - binary package/VLCKit.xcframework"),
        .executableTarget(name: "StreamApp", dependencies: ["StreamCore", "VLCKit"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "StreamCoreChecks", dependencies: ["StreamCore"], path: "Tests/StreamCoreTests")
    ]
)
