// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RoomsCore", platforms: [.iOS(.v17), .macOS(.v14)], products: [.library(name: "RoomsCore", targets: ["RoomsCore"])], targets: [.target(name: "RoomsCore"), .testTarget(name: "RoomsCoreTests", dependencies: ["RoomsCore"])])
