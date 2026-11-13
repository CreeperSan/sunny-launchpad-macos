// swift-tools-version: 6.2
// Sunny Launchpad 的编译级模块边界；所有平台实现由可执行入口统一组装。
import PackageDescription

let package = Package(
    name: "SunnyLaunchpad",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "SunnyLaunchpad", targets: ["SunnyLaunchpad"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "SunnyDomain"),
        .target(name: "SunnyInfrastructure", dependencies: ["SunnyDomain", "CSQLite"]),
        .target(name: "SunnyPresentation", dependencies: ["SunnyDomain"], resources: [.process("Resources")]),
        .executableTarget(name: "SunnyLaunchpad", dependencies: ["SunnyDomain", "SunnyInfrastructure", "SunnyPresentation"]),
        .testTarget(name: "SunnyDomainTests", dependencies: ["SunnyDomain"]),
        .testTarget(name: "SunnyInfrastructureTests", dependencies: ["SunnyInfrastructure", "CSQLite"]),
        .testTarget(name: "SunnyPresentationTests", dependencies: ["SunnyPresentation"])
    ]
)
