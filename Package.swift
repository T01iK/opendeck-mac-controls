// swift-tools-version:5.9
import Foundation
import PackageDescription

// Embedded into the binary's __TEXT,__info_plist section: gives it a bundle identity and the Bluetooth usage
// description needed by the Bluetooth helper (see System/ControlCenter.swift).
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
	.appendingPathComponent("Sources/MacControls/App/Info.plist").path

let package = Package(
	name: "MacControls",
	platforms: [.macOS(.v13)],
	targets: [
		.executableTarget(
			name: "MacControls",
			path: "Sources/MacControls",
			exclude: ["App/Info.plist"],
			linkerSettings: [
				.linkedFramework("AppKit"),
				.linkedFramework("ApplicationServices"),
				.linkedFramework("Carbon"),
				.linkedFramework("CoreAudio"),
				.linkedFramework("CoreWLAN"),
				.linkedFramework("IOBluetooth"),
				.linkedFramework("IOKit"),
				.linkedFramework("SystemConfiguration"),
				.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
			]
		),
	]
)
