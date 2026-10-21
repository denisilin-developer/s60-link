// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "S60Link",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "S60LinkCore", path: "Sources/S60LinkCore"),
        .executableTarget(name: "S60Link", dependencies: ["S60LinkCore"], path: "Sources/S60Link"),
        .executableTarget(name: "s60link-check", dependencies: ["S60LinkCore"], path: "Sources/s60link-check"),
    ]
)
