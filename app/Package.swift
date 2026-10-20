// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Margin",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "LibraryCore", targets: ["LibraryCore"]), .executable(name: "Margin", targets: ["ReaderApp"])],
    targets: [
        .target(name: "LibraryCore"),
        .executableTarget(name: "ReaderApp", dependencies: ["LibraryCore"]),
        .testTarget(name: "LibraryCoreTests", dependencies: ["LibraryCore"]),
        .testTarget(name: "ReaderAppTests", dependencies: ["ReaderApp"])
    ]
)
