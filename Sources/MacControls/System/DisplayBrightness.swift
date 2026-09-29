import CoreGraphics
import Foundation

/// Brightness of Apple-controlled displays (built-in panel, Studio Display, Pro Display XDR)
/// via the private DisplayServices framework — the same mechanism the brightness keys use.
final class DisplayBrightness {
	static let shared = DisplayBrightness()

	private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool
	private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
	private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

	private let canChange: CanChange?
	private let get: Get?
	private let set: Set?

	private init() {
		let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
		canChange = dlsym(handle, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanChange.self) }
		get = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
		set = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }
	}

	/// Online displays whose brightness macOS can control, built-in first.
	var displays: [CGDirectDisplayID] {
		var count = UInt32(0)
		CGGetOnlineDisplayList(0, nil, &count)
		var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
		CGGetOnlineDisplayList(count, &ids, &count)
		return ids.prefix(Int(count))
			.filter { CGDisplayIsActive($0) != 0 && (canChange?($0) ?? false) }
			.sorted { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsBuiltin($1) == 0 }
	}

	/// 0...1 of the primary controllable display, or nil when none is available (e.g. lid closed).
	var brightness: Float? {
		guard let display = displays.first, let get else { return nil }
		var value = Float(0)
		return get(display, &value) == 0 ? value : nil
	}

	/// Applies to every controllable display. Returns false when there is none.
	@discardableResult
	func setBrightness(_ value: Float) -> Bool {
		guard let set else { return false }
		let targets = displays
		let clamped = max(0, min(1, value))
		return targets.map { set($0, clamped) == 0 }.contains(true)
	}
}
