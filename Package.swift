// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MOI",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "MOICore", targets: ["MOICore"]),
               .executable(name: "moi-host", targets: ["MOIHost"])],
    dependencies: [.package(url: "https://github.com/google-ai-edge/LiteRT-LM.git", exact: "0.18.0")],
    targets: [
        .target(name: "MOICore", dependencies: [.product(name: "LiteRTLM", package: "LiteRT-LM")]),
        .executableTarget(name: "MOIHost", dependencies: ["MOICore"]),
        .testTarget(name: "MOICoreTests", dependencies: ["MOICore"])
    ]
)
