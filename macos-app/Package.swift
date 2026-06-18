// swift-tools-version:5.9
import PackageDescription

// Fastest dev path:  cd macos-app && swift run
// (For a real, sandbox-configurable .app bundle, use project.yml with XcodeGen.)
let package = Package(
    name: "SemanticFileFinder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SemanticFileFinder",
            path: "SemanticFileFinder"
        )
    ]
)
