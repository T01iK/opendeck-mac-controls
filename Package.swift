// swift-tools-version:5.9
import Foundation
import PackageDescription

// Embedded Info.plist: gives the binary a bundle identity and the Bluetooth usage description (see ControlCenter.swift).
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Support/Info.plist").path

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
				.linkedFramework("CoreWLAN"),
				.linkedFramework("IOBluetooth"),
				.linkedFramework("IOKit"),
				.linkedFramework("SystemConfiguration"),
				.linkedFramework("ApplicationServices"),
				.linkedFramework("Carbon"),
				.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
			]
		),
	]
)
