import Foundation
import IOBluetooth
import IOKit

/// Battery levels of paired Bluetooth devices.
///
/// Two sources:
/// - Apple HID devices (Magic Keyboard / Mouse / Trackpad) publish `BatteryPercent` in the IORegistry — read directly,
///   live and without any permission.
/// - Everything else (AirPods, Beats, …) comes from IOBluetooth's private `batteryPercent*` properties. Bluetooth is
///   privacy-protected, so that runs in the disclaimed helper (`MacControls --bluetooth devices`, see ControlCenter.swift)
///   and is refreshed at most every 30 s.
final class BluetoothBatteries {
	static let shared = BluetoothBatteries()

	struct Device: Codable {
		let address: String
		let name: String
		let kind: String // keyboard, mouse, trackpad, headphones, gamepad, other
		var connected: Bool
		var single: Int?
		var left: Int?
		var right: Int?
		var batteryCase: Int?

		var isMultiBattery: Bool { left != nil || right != nil || batteryCase != nil }

		var symbol: String {
			let lower = name.lowercased()
			switch kind {
			case "keyboard": return "keyboard"
			case "mouse": return "magicmouse"
			case "trackpad": return "rectangle.and.hand.point.up.left"
			case "gamepad": return "gamecontroller"
			case "headphones":
				if lower.contains("airpods pro") { return "airpods.pro" }
				if lower.contains("airpods max") { return "airpods.max" }
				if lower.contains("airpods") { return "airpods" }
				if lower.contains("powerbeats") { return "beats.powerbeatspro" }
				return "headphones"
			default: return "dot.radiowaves.left.and.right"
			}
		}
	}

	private(set) var devices: [Device] = []

	/// Name for the small key title: drops an owner suffix shared by several paired devices
	/// ("Magic Keyboard T01iK", "AirPods Pro 3 T01iK" → "Magic Keyboard", "AirPods Pro 3").
	func displayName(_ device: Device) -> String {
		let words = device.name.split(whereSeparator: \.isWhitespace)
		guard words.count > 1, let last = words.last else { return device.name }
		let sharing = devices.filter { $0.name.split(whereSeparator: \.isWhitespace).last == last }.count
		return sharing >= 2 ? words.dropLast().joined(separator: " ") : device.name
	}
	private var lastFetch = Date.distantPast
	private var fetching = false

	/// Device by address with live IORegistry levels merged in.
	func device(address: String) -> Device? {
		guard var device = devices.first(where: { $0.address == address }) else { return nil }
		if let level = Self.registryLevels()[address.lowercased()] {
			device.single = level
			device.connected = true
		}
		return device
	}

	/// Re-reads the paired devices through the helper when the cached list is older than `maxAge`.
	func refresh(maxAge: TimeInterval = 30, completion: @escaping () -> Void) {
		guard !fetching, Date().timeIntervalSince(lastFetch) >= maxAge else { return }
		fetching = true
		let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
		DispatchQueue.global().async {
			let result = Subprocess.run(executable, ["--bluetooth", "devices"], disclaim: true)
			let devices = try? JSONDecoder().decode([Device].self, from: Data(result.output.utf8))
			DispatchQueue.main.async {
				self.fetching = false
				self.lastFetch = Date()
				if let devices {
					self.devices = devices
				} else {
					Log.error("Bluetooth battery helper failed (\(result.status)): \(result.error)")
				}
				completion()
			}
		}
	}

	/// `BatteryPercent` of connected Apple HID devices, keyed by lower-case address ("80-4a-14-7e-77-c0").
	static func registryLevels() -> [String: Int] {
		var iterator = io_iterator_t(0)
		guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else {
			return [:]
		}
		defer { IOObjectRelease(iterator) }
		var levels: [String: Int] = [:]
		while case let service = IOIteratorNext(iterator), service != 0 {
			defer { IOObjectRelease(service) }
			func property(_ key: String) -> Any? {
				IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
			}
			guard let address = property("DeviceAddress") as? String, let percent = property("BatteryPercent") as? Int else { continue }
			levels[address.lowercased()] = percent
		}
		return levels
	}

	/// Entry point for `MacControls --bluetooth devices`: prints the paired devices as JSON.
	static func helperMain() -> Int32 {
		let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
		let devices: [Device] = paired.compactMap { device in
			// Skip computers and phones; they do not report a battery this way.
			let major = device.deviceClassMajor
			guard major != 0x01, major != 0x02, let address = device.addressString else { return nil }
			func percent(_ name: String) -> Int? {
				let selector = NSSelectorFromString(name)
				guard device.responds(to: selector), let imp = class_getMethodImplementation(type(of: device), selector) else { return nil }
				let value = unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector) -> UInt8).self)(device, selector)
				return value > 0 && value <= 100 ? Int(value) : nil
			}
			let name = device.name ?? address
			return Device(
				address: address.lowercased(), name: name, kind: kind(of: device, name: name), connected: device.isConnected(),
				single: percent("batteryPercentSingle") ?? percent("batteryPercentCombined"),
				left: percent("batteryPercentLeft"), right: percent("batteryPercentRight"), batteryCase: percent("batteryPercentCase")
			)
		}
		guard let data = try? JSONEncoder().encode(devices) else { return 1 }
		FileHandle.standardOutput.write(data)
		return 0
	}

	private static func kind(of device: IOBluetoothDevice, name: String) -> String {
		let lower = name.lowercased()
		if lower.contains("trackpad") { return "trackpad" }
		if lower.contains("mouse") { return "mouse" }
		if lower.contains("keyboard") { return "keyboard" }
		if ["controller", "dualsense", "dualshock", "gamepad"].contains(where: lower.contains) { return "gamepad" }
		if ["airpods", "beats", "buds", "headphone", "headset"].contains(where: lower.contains) { return "headphones" }
		switch (device.deviceClassMajor, device.deviceClassMinor & 0x30) {
		case (0x04, _): return "headphones" // audio / video
		case (0x05, 0x10): return "keyboard" // peripheral: keyboard
		case (0x05, 0x20): return "mouse" // peripheral: pointing device
		default: return "other"
		}
	}
}
