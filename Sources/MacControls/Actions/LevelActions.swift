import AppKit

/// Shared behaviour for "level" controls (volume, brightness): up / down / set keys and dials.
///
/// Settings: `mode` ("up" | "down" | "set" | "mute"), `step` (percent), `value` (percent, for "set" and dial press).
class LevelAction: ActionHandler {
	var actionIDs: [String] { [] }
	var title: String { "" }
	var color: NSColor { Render.Palette.text }

	/// Current level 0...1, nil when unavailable.
	var level: Float? { nil }
	func setLevel(_ value: Float) -> Bool { false }
	func symbol(for level: Float?) -> String { "questionmark" }
	func dialPressed(_ instance: Instance) { setPreset(instance) }

	private let repeater = HoldRepeater()

	func willAppear(_ instance: Instance) { render(instance) }

	func willDisappear(_ instance: Instance) { repeater.stop(instance) }

	func keyDown(_ instance: Instance) {
		switch instance.string("mode", "up") {
		case "up": repeater.start(instance) { [weak self] in self?.adjust(instance, by: 1) }
		case "down": repeater.start(instance) { [weak self] in self?.adjust(instance, by: -1) }
		case "set": setPreset(instance)
		default: break
		}
	}

	func keyUp(_ instance: Instance) { repeater.stop(instance) }

	func dialRotate(_ instance: Instance, ticks: Int) { adjust(instance, by: ticks) }

	func dialDown(_ instance: Instance) { dialPressed(instance) }

	func dialUp(_ instance: Instance) {}

	func adjust(_ instance: Instance, by steps: Int) {
		guard let current = level else { return fail(instance) }
		let step = Float(instance.number("step", 5)) / 100
		// Snap to the step grid so repeated presses land on round numbers.
		let target = (((current + step * Float(steps)) / step).rounded()) * step
		if !setLevel(target) { fail(instance) }
		refreshAll()
	}

	func setPreset(_ instance: Instance) {
		if !setLevel(Float(instance.number("value", 50)) / 100) { fail(instance) }
		refreshAll()
	}

	func fail(_ instance: Instance) {
		repeater.stop(instance)
		Plugin.shared.showAlert(instance)
	}

	func refreshAll() {
		Plugin.shared.instances(of: self).forEach(render)
	}

	func badge(for instance: Instance) -> String? {
		switch instance.string("mode", "up") {
		case "up": return "plus.circle.fill"
		case "down": return "minus.circle.fill"
		default: return nil
		}
	}

	func valueText(_ level: Float?) -> String {
		level.map { "\(Int(($0 * 100).rounded()))%" } ?? "N/A"
	}

	func render(_ instance: Instance) {
		let level = level
		if instance.isEncoder {
			Plugin.shared.setFeedback(instance, [
				"title": title,
				"value": valueText(level),
				"indicator": Int(((level ?? 0) * 100).rounded()),
			])
		}
		// Dials usually have no room for the level (and devices may show it themselves), so they default to icon only.
		guard instance.bool("showLevel", !instance.isEncoder) else {
			let tint = level == nil ? Render.Palette.secondary : color
			Plugin.shared.setImage(instance, Render.iconKey(
				symbol: symbol(for: level), color: tint, badge: instance.isEncoder ? nil : badge(for: instance)
			))
			return
		}
		Plugin.shared.setImage(instance, Render.levelKey(
			symbol: symbol(for: level),
			value: valueText(level),
			fraction: level.map(Double.init),
			color: level == nil ? Render.Palette.secondary : color,
			badge: instance.isEncoder ? nil : badge(for: instance)
		))
	}
}

final class VolumeAction: LevelAction {
	override var actionIDs: [String] { ["volume"] }
	override var title: String { "Volume" }

	private let audio = SystemAudio.shared
	private var muted: Bool { audio.isMuted ?? false }

	override init() {
		super.init()
		audio.addObserver { [weak self] in self?.refreshAll() }
	}

	override var level: Float? { audio.volume }

	override var color: NSColor { muted ? Render.Palette.red : Render.Palette.text }

	override func setLevel(_ value: Float) -> Bool {
		// Changing the volume unmutes, like the keyboard volume keys do.
		if muted { audio.setMuted(false) }
		return audio.setVolume(value)
	}

	override func keyDown(_ instance: Instance) {
		if instance.string("mode", "up") == "mute" { return toggleMute(instance) }
		super.keyDown(instance)
	}

	override func dialPressed(_ instance: Instance) { toggleMute(instance) }

	private func toggleMute(_ instance: Instance) {
		if !audio.setMuted(!muted) { fail(instance) }
		refreshAll()
	}

	override func symbol(for level: Float?) -> String {
		guard let level else { return "speaker.slash" }
		if muted { return "speaker.slash.fill" }
		switch level {
		case 0: return "speaker.fill"
		case ..<0.34: return "speaker.wave.1.fill"
		case ..<0.67: return "speaker.wave.2.fill"
		default: return "speaker.wave.3.fill"
		}
	}

	override func valueText(_ level: Float?) -> String {
		level != nil && muted ? "Muted" : super.valueText(level)
	}
}

final class BrightnessAction: LevelAction {
	override var actionIDs: [String] { ["brightness"] }
	override var title: String { "Brightness" }
	override var color: NSColor { Render.Palette.yellow }

	private let display = DisplayBrightness.shared
	private var poll: Timer?

	override var level: Float? { display.brightness }

	override func setLevel(_ value: Float) -> Bool { display.setBrightness(value) }

	override func symbol(for level: Float?) -> String {
		guard let level else { return "sun.max.trianglebadge.exclamationmark" }
		return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
	}

	override func willAppear(_ instance: Instance) {
		super.willAppear(instance)
		// Brightness can also change via the keyboard, auto-brightness or lid state; poll lightly while visible.
		if poll == nil {
			poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshAll() }
		}
	}

	override func willDisappear(_ instance: Instance) {
		super.willDisappear(instance)
		DispatchQueue.main.async { [weak self] in
			guard let self, Plugin.shared.instances(of: self).isEmpty else { return }
			self.poll?.invalidate()
			self.poll = nil
		}
	}
}

final class KeyboardBrightnessAction: LevelAction {
	override var actionIDs: [String] { ["keyboardbrightness"] }
	override var title: String { "Keyboard" }
	override var color: NSColor { Render.Palette.teal }

	private let backlight = KeyboardBacklight.shared
	private var poll: Timer?

	override var level: Float? { backlight.brightness }

	override func setLevel(_ value: Float) -> Bool { backlight.setBrightness(value) }

	override func symbol(for level: Float?) -> String {
		guard let level else { return "keyboard" }
		return level < 0.5 ? "light.min" : "light.max"
	}

	override func willAppear(_ instance: Instance) {
		super.willAppear(instance)
		// Auto-brightness and the F-keys change it too.
		if poll == nil {
			poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshAll() }
		}
	}

	override func willDisappear(_ instance: Instance) {
		super.willDisappear(instance)
		DispatchQueue.main.async { [weak self] in
			guard let self, Plugin.shared.instances(of: self).isEmpty else { return }
			self.poll?.invalidate()
			self.poll = nil
		}
	}
}
