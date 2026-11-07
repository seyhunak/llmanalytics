// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LLMAnalytics",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LLMAnalytics", targets: ["LLMAnalytics"])],
    targets: [
        .executableTarget(
            name: "LLMAnalytics",
            path: "Sources/LLMAnalytics",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "LLMAnalyticsTests",
            dependencies: ["LLMAnalytics"],
            path: "Tests/LLMAnalyticsTests",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
