// swift-tools-version: 5.9
import PackageDescription

let package = Package(
	name: "RelayProbe",
	platforms: [.macOS(.v13)],
	dependencies: [
		.package(url: "https://code.videolan.org/videolan/VLCKit.git", exact: "4.0.0-a22")
	],
	targets: [
		.executableTarget(name: "RelayProbe", dependencies: [.product(name: "VLCKit", package: "VLCKit")])
	],
	swiftLanguageVersions: [.v5]
)
