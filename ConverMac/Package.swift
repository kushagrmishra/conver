// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Conver",
    platforms: [.macOS("15.0")],
    targets: [.executableTarget(name: "Conver", path: "Sources/Conver")]
)
