// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CouchSync",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CouchSync", path: "Sources/CouchSync")
    ]
)
