// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CouchSync",
    platforms: [.macOS(.v14)],
    targets: [
        // The iroh bridge, built from net/ by build.sh (cargo) before swift build.
        .systemLibrary(name: "CCouchNet", path: "Sources/CCouchNet"),
        .executableTarget(
            name: "CouchSync",
            dependencies: ["CCouchNet"],
            path: "Sources/CouchSync",
            linkerSettings: [
                .unsafeFlags(["-L\(Context.packageDirectory)/net/target/aarch64-apple-darwin/release"]),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
