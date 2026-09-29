// swift-tools-version:5.9
import PackageDescription

let package = Package(
	name: "MacControls",
	platforms: [.macOS(.v13)],
	targets: [
		.executableTarget(
			name: "MacControls",
			path: "Sources/MacControls",
			linkerSettings: [
				.linkedFramework("AppKit"),
				.linkedFramework("CoreAudio"),
				.linkedFramework("IOKit"),
				.linkedFramework("SystemConfiguration"),
				.linkedFramework("ApplicationServices"),
			]
		),
	]
)
