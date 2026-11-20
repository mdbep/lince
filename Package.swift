// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lince",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Lince", path: "Sources/Lince")
    ]
)
