import AppKit

// The same binary runs in three modes:
//   MacControls -port … -pluginUUID … -registerEvent … -info …   the plugin, started by OpenDeck
//   MacControls --bluetooth get|on|off|devices                    Bluetooth helper (see System/ControlCenter.swift)
//   MacControls --generate-icons <bundle>                         renders static icons (used by scripts/build.sh)
//   MacControls --plugin-icon <file.png> <size>                   renders the plugin icon (used by scripts/package.sh)

let arguments = CommandLine.arguments

func argument(_ name: String) -> String? {
	guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
	return arguments[index + 1]
}

if let command = argument("--bluetooth") {
	exit(ControlCenter.bluetoothHelperMain(command))
}

if let directory = argument("--generate-icons") {
	do {
		try KeyCatalog.generate(into: URL(fileURLWithPath: directory))
		exit(0)
	} catch {
		FileHandle.standardError.write("Icon generation failed: \(error)\n".data(using: .utf8)!)
		exit(1)
	}
}

if let file = argument("--plugin-icon") {
	let size = arguments.last.flatMap(Double.init) ?? 512
	do {
		try KeyCatalog.pluginIcon(size: size).write(to: URL(fileURLWithPath: file))
		exit(0)
	} catch {
		FileHandle.standardError.write("Plugin icon failed: \(error)\n".data(using: .utf8)!)
		exit(1)
	}
}

guard let port = argument("-port").flatMap(Int.init), let uuid = argument("-pluginUUID"), let registerEvent = argument("-registerEvent") else {
	print("MacControls is an OpenDeck plugin; it is started by OpenDeck.")
	exit(1)
}

Log.info("Starting (pid \(ProcessInfo.processInfo.processIdentifier))")
Plugin.shared = Plugin(port: port, uuid: uuid, registerEvent: registerEvent, handlers: [
	VolumeAction(),
	BrightnessAction(),
	KeyboardBrightnessAction(),
	MediaAction(),
	AudioOutputAction(),
	InputSourceAction(),
	LauncherAction(),
	ShortcutAction(),
	AppAction(),
	ControlCenterAction(),
	MonitorAction(),
])
Plugin.shared.start()
RunLoop.main.run()
