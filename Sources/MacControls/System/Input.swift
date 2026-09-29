import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Synthetic keyboard input and Accessibility helpers. Requires OpenDeck to have Accessibility permission.
enum Input {
	enum MediaKey: Int32 {
		case playPause = 16 // NX_KEYTYPE_PLAY
		case next = 17 // NX_KEYTYPE_NEXT
		case previous = 18 // NX_KEYTYPE_PREVIOUS
	}

	/// Whether OpenDeck (our "responsible" app) has been granted Accessibility. Optionally shows the system prompt.
	@discardableResult
	static func ensureAccessibility(prompt: Bool) -> Bool {
		let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
		return AXIsProcessTrustedWithOptions(options)
	}

	/// Posts the same system-defined event a keyboard's media key produces.
	static func post(_ key: MediaKey) {
		for down in [true, false] {
			let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
			let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
			let event = NSEvent.otherEvent(
				with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
				context: nil, subtype: 8, data1: data1, data2: -1
			)
			event?.cgEvent?.post(tap: .cghidEventTap)
		}
	}

	/// Posts a key combination, e.g. Control+Command+Space.
	static func post(keyCode: Int, flags: CGEventFlags) {
		let source = CGEventSource(stateID: .hidSystemState)
		for down in [true, false] {
			let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)
			event?.flags = flags
			event?.post(tap: .cghidEventTap)
		}
	}

	/// Clicks a menu item of the frontmost app whose title matches one of `titles` (any top-level menu).
	/// Used for "Emoji & Symbols" and "Start Dictation", which AppKit adds to the Edit menu of every app.
	static func pressMenuItem(titles: [String]) -> Bool {
		guard let app = NSWorkspace.shared.frontmostApplication else { return false }
		let element = AXUIElementCreateApplication(app.processIdentifier)
		guard let menuBar: AXUIElement = attribute(element, kAXMenuBarAttribute) else { return false }
		let wanted = Set(titles.map(normalize))
		for topItem in children(menuBar) {
			for menu in children(topItem) {
				for item in children(menu) {
					guard let title: String = attribute(item, kAXTitleAttribute), wanted.contains(normalize(title)) else { continue }
					if let enabled: Bool = attribute(item, kAXEnabledAttribute), !enabled { continue }
					return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
				}
			}
		}
		return false
	}

	private static func normalize(_ title: String) -> String {
		title.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
			.trimmingCharacters(in: .whitespaces).lowercased()
	}

	private static func children(_ element: AXUIElement) -> [AXUIElement] {
		attribute(element, kAXChildrenAttribute) ?? []
	}

	private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
		return value as? T
	}
}
