import AppKit

/// `MacControls --generate-icons <dir>` renders the static images referenced by manifest.json (used by the build script).
func generateIcons(into directory: URL) throws {
	let icons = directory.appendingPathComponent("icons")
	let keys = directory.appendingPathComponent("keys")
	try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
	try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)

	let listIcons: [String: String] = [
		"plugin": "command", "category": "command",
		"volume": "speaker.wave.2.fill", "brightness": "sun.max.fill", "media": "playpause.fill",
		"missioncontrol": "rectangle.3.group.fill", "apps": "square.grid.3x3.fill", "spotlight": "magnifyingglass",
		"emoji": "face.smiling", "dictation": "mic.fill", "siri": "waveform",
		"shortcut": "square.2.layers.3d.fill", "openapp": "arrow.up.forward.app.fill", "monitor": "gauge.with.dots.needle.67percent",
		"controlcenter": "switch.2", "keyboardbrightness": "light.max", "audiooutput": "hifispeaker.fill", "inputsource": "globe",
	]
	for (name, symbol) in listIcons {
		let base = name == "plugin" ? 28.0 : 20.0
		try Render.listIcon(symbol: symbol, size: base).write(to: icons.appendingPathComponent("\(name).png"))
		try Render.listIcon(symbol: symbol, size: base * 2).write(to: icons.appendingPathComponent("\(name)@2x.png"))
	}

	for (name, spec) in Render.defaultKeys {
		let uri = Render.iconKey(symbol: spec.symbol, label: spec.label, color: spec.color)
		let data = Data(base64Encoded: String(uri.dropFirst("data:image/png;base64,".count)))!
		try data.write(to: keys.appendingPathComponent("\(name)@2x.png"))
		// 72×72 variant for 1x consumers.
		let small = Render.png(size: 72) { rect in
			NSImage(data: data)?.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
		}
		try small.write(to: keys.appendingPathComponent("\(name).png"))
	}
}

let arguments = CommandLine.arguments

// Helper mode used by the Bluetooth switch (see ControlCenter.swift).
if let index = arguments.firstIndex(of: "--bluetooth"), index + 1 < arguments.count {
	exit(ControlCenter.bluetoothHelperMain(arguments[index + 1]))
}

if let index = arguments.firstIndex(of: "--generate-icons"), index + 1 < arguments.count {
	do {
		try generateIcons(into: URL(fileURLWithPath: arguments[index + 1]))
		exit(0)
	} catch {
		FileHandle.standardError.write("Icon generation failed: \(error)\n".data(using: .utf8)!)
		exit(1)
	}
}

func argument(_ name: String) -> String? {
	guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
	return arguments[index + 1]
}

guard let port = argument("-port").flatMap(Int.init), let uuid = argument("-pluginUUID"), let registerEvent = argument("-registerEvent") else {
	print("MacControls is an OpenDeck plugin; it is started by OpenDeck.")
	exit(1)
}

Log.info("Starting (pid \(ProcessInfo.processInfo.processIdentifier))")
Plugin.shared = Plugin(port: port, uuid: uuid, registerEvent: registerEvent, handlers: [
	VolumeAction(),
	BrightnessAction(),
	MediaAction(),
	LauncherAction(),
	ShortcutAction(),
	AppAction(),
	ControlCenterAction(),
	KeyboardBrightnessAction(),
	AudioOutputAction(),
	InputSourceAction(),
	MonitorAction(),
])
Plugin.shared.start()
RunLoop.main.run()
