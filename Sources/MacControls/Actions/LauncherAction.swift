import AppKit
import Carbon.HIToolbox

/// One-shot system functions: Mission Control, Apps (Launchpad), Spotlight, Emoji & Symbols, Dictation, Siri.
///
/// Settings: `systemIcon` (bool, default false — Mission Control, Apps, Spotlight, Siri), `showLabel` (bool, default true).
final class LauncherAction: ActionHandler {
	let actionIDs = ["missioncontrol", "apps", "spotlight", "emoji", "dictation", "siri"]

	private typealias CoreDockSendNotification = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void
	private lazy var dockNotify: CoreDockSendNotification? = {
		let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
		return dlsym(handle, "CoreDockSendNotification").map { unsafeBitCast($0, to: CoreDockSendNotification.self) }
	}()

	/// Apps whose icon can replace the SF Symbol (setting `systemIcon`).
	private let systemIconPaths = [
		"missioncontrol": "/System/Applications/Mission Control.app",
		"apps": "/System/Applications/Apps.app",
		"spotlight": "/System/Library/CoreServices/Spotlight.app",
		"siri": "/System/Applications/Siri.app",
	]

	/// The manifest's default image has a caption; it is only replaced when the system icon or no caption is wanted.
	func willAppear(_ instance: Instance) {
		if instance.bool("systemIcon", false), let path = systemIconPaths[instance.action], FileManager.default.fileExists(atPath: path) {
			Plugin.shared.setImage(instance, Render.imageKey(NSWorkspace.shared.icon(forFile: path)))
		} else if !instance.bool("showLabel", true), let spec = KeyCatalog.defaultKeys[instance.action] {
			Plugin.shared.setImage(instance, Render.iconKey(symbol: spec.symbol, color: spec.color))
		}
	}

	func settingsChanged(_ instance: Instance) {
		if instance.bool("systemIcon", false) || !instance.bool("showLabel", true) {
			willAppear(instance)
		} else {
			// Back to the defaults: an empty image restores the manifest image. Not done on appear so a custom image set
			// in OpenDeck is left alone.
			Plugin.shared.setImage(instance, "")
		}
	}

	func keyDown(_ instance: Instance) {
		let ok: Bool
		switch instance.action {
		case "missioncontrol": ok = dock("com.apple.expose.awake") || open("/System/Applications/Mission Control.app")
		case "apps": ok = dock("com.apple.launchpad.toggle") || open("/System/Applications/Apps.app")
		case "spotlight": ok = spotlight()
		case "emoji": ok = emoji()
		case "dictation": ok = dictation()
		case "siri": ok = open("/System/Applications/Siri.app")
		default: ok = false
		}
		if !ok { Plugin.shared.showAlert(instance) }
	}

	private func dock(_ name: String) -> Bool {
		guard let dockNotify else { return false }
		dockNotify(name as CFString, nil)
		return true
	}

	private func open(_ path: String) -> Bool {
		guard FileManager.default.fileExists(atPath: path) else { return false }
		NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, error in
			if let error { Log.error("Failed to open \(path): \(error.localizedDescription)") }
		}
		return true
	}

	/// Spotlight (macOS 26+) listens for this distributed notification; it works even when the ⌘Space shortcut is disabled.
	private func spotlight() -> Bool {
		DistributedNotificationCenter.default().postNotificationName(
			.init("com.apple.spotlight.toggle"), object: nil, userInfo: nil, deliverImmediately: true
		)
		return true
	}

	/// AppKit adds "Emoji & Symbols" to every app's Edit menu; pressing it through Accessibility is the most reliable way
	/// to open the picker for the focused text field. Falls back to the default ⌃⌘Space shortcut.
	private func emoji() -> Bool {
		guard Input.ensureAccessibility(prompt: true) else { return false }
		if Input.pressMenuItem(titles: ["Emoji & Symbols", "Emoji and Symbols", "Special Characters", "Эмодзи и символы"]) { return true }
		Input.post(keyCode: kVK_Space, flags: [.maskControl, .maskCommand])
		return true
	}

	/// "Start Dictation" is likewise added to the Edit menu of every app that accepts text.
	private func dictation() -> Bool {
		guard Input.ensureAccessibility(prompt: true) else { return false }
		return Input.pressMenuItem(titles: [
			"Start Dictation", "Stop Dictation", "Начать диктовку", "Остановить диктовку", "Диктовка",
		])
	}
}
