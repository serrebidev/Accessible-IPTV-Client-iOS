// swift-tools-version: 5.9
// Platform-neutral rules of the app: playlists, guide, catch-up, providers, recording loop.
// No UIKit or SwiftUI here, so `swift test` runs it on macOS and (minus SQLite/gzip) on Windows.
import PackageDescription

let package = Package(
	name: "IPTVCore",
	platforms: [.iOS(.v17), .tvOS(.v17), .visionOS(.v1), .macOS(.v14)],
	products: [.library(name: "IPTVCore", targets: ["IPTVCore"])],
	targets: [
		.target(name: "IPTVCore"),
		.testTarget(name: "IPTVCoreTests", dependencies: ["IPTVCore"]),
	]
)
