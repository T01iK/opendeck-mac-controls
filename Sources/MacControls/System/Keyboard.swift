import AppKit
import Carbon

/// Built-in keyboard backlight via the private CoreBrightness `KeyboardBrightnessClient` (no root needed).
final class KeyboardBacklight {
	static let shared = KeyboardBacklight()

	private let client: NSObject? = {
		dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
		return (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
	}()

	private var keyboard: UInt64? {
		guard let client, let ids = client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber] else {
			return nil
		}
		return ids.first?.uint64Value
	}

	/// 0...1, nil when the Mac has no backlit keyboard.
	var brightness: Float? {
		guard let client, let keyboard else { return nil }
		let selector = NSSelectorFromString("brightnessForKeyboard:")
		guard let imp = class_getMethodImplementation(type(of: client), selector) else { return nil }
		typealias Fn = @convention(c) (AnyObject, Selector, UInt64) -> Float
		return unsafeBitCast(imp, to: Fn.self)(client, selector, keyboard)
	}

	@discardableResult
	func setBrightness(_ value: Float) -> Bool {
		guard let client, let keyboard else { return false }
		let selector = NSSelectorFromString("setBrightness:fadeSpeed:commit:forKeyboard:")
		guard let imp = class_getMethodImplementation(type(of: client), selector) else { return false }
		typealias Fn = @convention(c) (AnyObject, Selector, Float, Int32, Bool, UInt64) -> Bool
		return unsafeBitCast(imp, to: Fn.self)(client, selector, max(0, min(1, value)), 0, true, keyboard)
	}
}

/// Keyboard layouts / input methods via the public Text Input Sources API.
enum InputSources {
	struct Source {
		let id: String
		let name: String
		/// Short label such as "EN" or "RU".
		let code: String
		fileprivate let ref: TISInputSource
	}

	/// Enabled, selectable keyboard input sources in the order shown in the menu bar.
	static var all: [Source] {
		let filter = [
			kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
			kTISPropertyInputSourceIsSelectCapable as String: true,
		] as CFDictionary
		let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
		return list.compactMap(source)
	}

	static var current: Source? {
		TISCopyCurrentKeyboardInputSource().map { source($0.takeRetainedValue()) } ?? nil
	}

	@discardableResult
	static func select(id: String) -> Bool {
		guard let target = all.first(where: { $0.id == id }) else { return false }
		return TISSelectInputSource(target.ref) == noErr
	}

	/// Switches to the next source (wrapping around), like ⌃Space.
	@discardableResult
	static func selectNext() -> Bool {
		let sources = all
		guard sources.count > 1 else { return false }
		let index = sources.firstIndex { $0.id == current?.id } ?? -1
		return TISSelectInputSource(sources[(index + 1) % sources.count].ref) == noErr
	}

	private static func source(_ ref: TISInputSource) -> Source? {
		func property<T>(_ key: CFString) -> T? {
			TISGetInputSourceProperty(ref, key).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as? T } ?? nil
		}
		guard let id: String = property(kTISPropertyInputSourceID) else { return nil }
		let name: String = property(kTISPropertyLocalizedName) ?? id
		let language = (property(kTISPropertyInputSourceLanguages) as [String]?)?.first ?? String(name.prefix(2))
		return Source(id: id, name: name, code: String(language.prefix(2)).uppercased(), ref: ref)
	}
}
