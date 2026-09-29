import AppKit
import CoreWLAN
import IOKit.pwr_mgt

/// Control Center style switches and one-shot system commands. None of them need root.
enum ControlCenterFeature: String, CaseIterable {
	// Switches
	case wifi, bluetooth, stageManager, darkMode, nightShift, trueTone, micMute, keepAwake, dockAutohide
	// One-shot commands
	case lockScreen, displaySleep, screensaver, sleep, showDesktop

	var isToggle: Bool {
		switch self {
		case .lockScreen, .displaySleep, .screensaver, .sleep, .showDesktop: return false
		default: return true
		}
	}

	var title: String {
		switch self {
		case .wifi: return "Wi-Fi"
		case .bluetooth: return "Bluetooth"
		case .stageManager: return "Stage Mgr"
		case .darkMode: return "Dark Mode"
		case .nightShift: return "Night Shift"
		case .trueTone: return "True Tone"
		case .micMute: return "Mic"
		case .keepAwake: return "Awake"
		case .dockAutohide: return "Dock Hide"
		case .lockScreen: return "Lock"
		case .displaySleep: return "Displays Off"
		case .screensaver: return "Screensaver"
		case .sleep: return "Sleep"
		case .showDesktop: return "Desktop"
		}
	}

	func symbol(on: Bool) -> String {
		switch self {
		case .wifi: return on ? "wifi" : "wifi.slash"
		case .bluetooth: return "bluetooth" // drawn by hand; SF Symbols has no Bluetooth glyph
		case .stageManager: return "squares.leading.rectangle"
		case .darkMode: return "circle.lefthalf.filled"
		case .nightShift: return "sunset.fill"
		case .trueTone: return "sun.max.circle.fill"
		case .micMute: return on ? "mic.slash.fill" : "mic.fill"
		case .keepAwake: return on ? "cup.and.saucer.fill" : "cup.and.saucer"
		case .dockAutohide: return "dock.rectangle"
		case .lockScreen: return "lock.fill"
		case .displaySleep: return "display"
		case .screensaver: return "sparkles"
		case .sleep: return "moon.zzz.fill"
		case .showDesktop: return "rectangle.dashed"
		}
	}
}

final class ControlCenter {
	static let shared = ControlCenter()

	private var keepAwakeAssertion = IOPMAssertionID(0)
	private(set) var bluetooth: Bool?

	// MARK: State

	/// Current state of a switch; nil when unavailable on this Mac right now.
	func state(_ feature: ControlCenterFeature) -> Bool? {
		switch feature {
		case .wifi: return CWWiFiClient.shared().interface()?.powerOn()
		case .bluetooth: return bluetooth
		case .stageManager:
			CFPreferencesAppSynchronize(Self.windowManager)
			return CFPreferencesCopyAppValue("GloballyEnabled" as CFString, Self.windowManager) as? Bool ?? false
		case .darkMode: return Private.getDarkMode?()
		case .nightShift: return Private.nightShiftEnabled()
		case .trueTone: return Private.trueToneEnabled()
		case .micMute: return SystemAudio.shared.isInputMuted
		case .keepAwake: return keepAwakeAssertion != 0
		case .dockAutohide: return Private.getDockAutohide?()
		default: return nil
		}
	}

	/// Changes a switch. Bluetooth completes asynchronously; `completion` runs on the main queue.
	func set(_ feature: ControlCenterFeature, _ on: Bool, completion: @escaping (Bool) -> Void) {
		switch feature {
		case .bluetooth:
			runBluetoothHelper(on ? "on" : "off", completion: completion)
			return
		case .stageManager:
			// WindowManager only reads the setting at launch, so restart it (a brief flicker).
			CFPreferencesSetAppValue("GloballyEnabled" as CFString, on as CFBoolean, Self.windowManager)
			CFPreferencesAppSynchronize(Self.windowManager)
			DispatchQueue.global().async {
				let result = Subprocess.run("/usr/bin/killall", ["WindowManager"])
				DispatchQueue.main.async { completion(result.status == 0) }
			}
			return
		default:
			completion(setSync(feature, on))
		}
	}

	private func setSync(_ feature: ControlCenterFeature, _ on: Bool) -> Bool {
		switch feature {
		case .wifi:
			do {
				try CWWiFiClient.shared().interface()?.setPower(on)
				return true
			} catch {
				Log.error("Wi-Fi: \(error.localizedDescription)")
				return false
			}
		case .darkMode:
			guard let set = Private.setDarkMode else { return false }
			set(on)
			return true
		case .nightShift: return Private.setNightShift(on)
		case .trueTone: return Private.setTrueTone(on)
		case .micMute: return SystemAudio.shared.setInputMuted(on)
		case .keepAwake:
			if on, keepAwakeAssertion == 0 {
				return IOPMAssertionCreateWithName(
					kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
					"Keep Awake (OpenDeck)" as CFString, &keepAwakeAssertion
				) == kIOReturnSuccess
			} else if !on, keepAwakeAssertion != 0 {
				IOPMAssertionRelease(keepAwakeAssertion)
				keepAwakeAssertion = 0
			}
			return true
		case .dockAutohide:
			guard let set = Private.setDockAutohide else { return false }
			set(on)
			return true
		default:
			return false
		}
	}

	// MARK: Commands

	func perform(_ feature: ControlCenterFeature) -> Bool {
		switch feature {
		case .lockScreen:
			guard let lock = Private.lockScreen else { return false }
			_ = lock()
			return true
		case .displaySleep: return pmset("displaysleepnow")
		case .sleep: return pmset("sleepnow")
		case .screensaver:
			NSWorkspace.shared.openApplication(
				at: URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"), configuration: NSWorkspace.OpenConfiguration()
			)
			return true
		case .showDesktop:
			guard let notify = Private.dockNotify else { return false }
			notify("com.apple.showdesktop.awake" as CFString, nil)
			return true
		default:
			return false
		}
	}

	private func pmset(_ command: String) -> Bool {
		DispatchQueue.global().async { _ = Subprocess.run("/usr/bin/pmset", [command]) }
		return true
	}

	// MARK: Bluetooth

	/// Bluetooth access is privacy-protected and OpenDeck's Info.plist has no Bluetooth usage description, so a call from
	/// the plugin would be killed by TCC. Instead the plugin re-launches itself as its own "responsible process"; the
	/// binary embeds an Info.plist with the usage description (macOS asks once to allow "macOS Controls").
	func refreshBluetooth(completion: @escaping () -> Void) {
		runBluetoothHelper("get") { _ in completion() }
	}

	private func runBluetoothHelper(_ command: String, completion: @escaping (Bool) -> Void) {
		let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
		DispatchQueue.global().async {
			let result = Subprocess.run(executable, ["--bluetooth", command], disclaim: true)
			let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
			DispatchQueue.main.async {
				self.bluetooth = value == "1" ? true : value == "0" ? false : nil
				if result.status != 0 { Log.error("Bluetooth helper failed (\(result.status)): \(result.error)") }
				completion(result.status == 0)
			}
		}
	}

	/// Entry point for `MacControls --bluetooth get|on|off|devices`: prints the resulting state (1/0), or the paired
	/// devices with their battery levels as JSON.
	static func bluetoothHelperMain(_ command: String) -> Int32 {
		if command == "devices" { return BluetoothBatteries.helperMain() }
		typealias Get = @convention(c) () -> Int32
		typealias Set = @convention(c) (Int32) -> Void
		let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)
		guard let getSymbol = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState"),
		      let setSymbol = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState")
		else { return 2 }
		let get = unsafeBitCast(getSymbol, to: Get.self)
		if command == "on" || command == "off" {
			let target: Int32 = command == "on" ? 1 : 0
			unsafeBitCast(setSymbol, to: Set.self)(target)
			// The controller takes a moment to change state.
			for _ in 0..<30 where get() != target { usleep(100_000) }
		}
		print(get())
		return 0
	}

	private static let windowManager = "com.apple.WindowManager" as CFString
}

/// Private system functions, resolved at runtime so a missing symbol only disables that feature.
private enum Private {
	typealias GetBool = @convention(c) () -> Bool
	typealias SetBool = @convention(c) (Bool) -> Void

	static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
	static let appServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
	static let login = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW)
	static let coreBrightness = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)

	static let getDarkMode = dlsym(skyLight, "SLSGetAppearanceThemeLegacy").map { unsafeBitCast($0, to: GetBool.self) }
	static let setDarkMode = dlsym(skyLight, "SLSSetAppearanceThemeLegacy").map { unsafeBitCast($0, to: SetBool.self) }
	static let getDockAutohide = dlsym(appServices, "CoreDockGetAutoHideEnabled").map { unsafeBitCast($0, to: GetBool.self) }
	static let setDockAutohide = dlsym(appServices, "CoreDockSetAutoHideEnabled").map { unsafeBitCast($0, to: SetBool.self) }
	static let dockNotify = dlsym(appServices, "CoreDockSendNotification").map {
		unsafeBitCast($0, to: (@convention(c) (CFString, UnsafeMutableRawPointer?) -> Void).self)
	}
	static let lockScreen = dlsym(login, "SACLockScreenImmediate").map { unsafeBitCast($0, to: (@convention(c) () -> Int32).self) }

	// MARK: CoreBrightness (Night Shift, True Tone)

	static let blueLight: NSObject? = {
		_ = coreBrightness
		return (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
	}()

	static let trueTone: NSObject? = {
		_ = coreBrightness
		return (NSClassFromString("CBTrueToneClient") as? NSObject.Type)?.init()
	}()

	/// `-getBlueLightStatus:` fills a C struct; `enabled` is its second byte and `available` sits at offset 32.
	static func nightShiftEnabled() -> Bool? {
		guard let client = blueLight else { return nil }
		let selector = NSSelectorFromString("getBlueLightStatus:")
		guard let imp = class_getMethodImplementation(type(of: client), selector) else { return nil }
		typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
		var status = [UInt8](repeating: 0, count: 64)
		let ok = status.withUnsafeMutableBytes { unsafeBitCast(imp, to: Fn.self)(client, selector, $0.baseAddress!) }
		guard ok, status[32] != 0 else { return nil }
		return status[1] != 0
	}

	static func setNightShift(_ on: Bool) -> Bool {
		callBool(blueLight, "setEnabled:", on)
	}

	static func trueToneEnabled() -> Bool? {
		guard let client = trueTone,
		      (client.value(forKey: "supported") as? Bool) == true, (client.value(forKey: "available") as? Bool) == true
		else { return nil }
		return client.value(forKey: "enabled") as? Bool
	}

	static func setTrueTone(_ on: Bool) -> Bool {
		callBool(trueTone, "setEnabled:", on)
	}

	private static func callBool(_ object: NSObject?, _ name: String, _ value: Bool) -> Bool {
		guard let object else { return false }
		let selector = NSSelectorFromString(name)
		guard let imp = class_getMethodImplementation(type(of: object), selector) else { return false }
		typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Bool
		return unsafeBitCast(imp, to: Fn.self)(object, selector, value)
	}
}
