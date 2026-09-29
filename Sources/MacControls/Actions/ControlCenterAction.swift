import AppKit

/// Control Center switches (with live state) and one-shot system commands.
///
/// Settings: `feature` (a `ControlCenterFeature` raw value, default "wifi"), `showLabel` (bool, default true).
/// Dials: press toggles / runs the command.
final class ControlCenterAction: ActionHandler {
	let actionIDs = ["controlcenter"]

	private let center = ControlCenter.shared
	private var poll: Timer?
	private var ticks = 0

	init() {
		// Keep the microphone tile in sync with changes made elsewhere.
		SystemAudio.shared.addObserver { [weak self] in self?.refreshAll() }
	}

	func willAppear(_ instance: Instance) {
		if feature(instance) == .bluetooth { center.refreshBluetooth { [weak self] in self?.refreshAll() } }
		render(instance)
		startPolling()
	}

	func willDisappear(_ instance: Instance) {
		DispatchQueue.main.async { [weak self] in
			guard let self, Plugin.shared.instances(of: self).isEmpty else { return }
			self.poll?.invalidate()
			self.poll = nil
		}
	}

	func keyDown(_ instance: Instance) {
		let feature = feature(instance)
		guard feature.isToggle else {
			if !center.perform(feature) { Plugin.shared.showAlert(instance) }
			return
		}
		guard let current = center.state(feature) else { return Plugin.shared.showAlert(instance) }
		center.set(feature, !current) { [weak self] ok in
			if !ok { Plugin.shared.showAlert(instance) }
			self?.refreshAll()
		}
		refreshAll()
	}

	func dialDown(_ instance: Instance) { keyDown(instance) }

	func dialUp(_ instance: Instance) {}

	// MARK: Helpers

	private func feature(_ instance: Instance) -> ControlCenterFeature {
		ControlCenterFeature(rawValue: instance.string("feature", "wifi")) ?? .wifi
	}

	/// States can also change from Control Center or the keyboard, so refresh every 2 s (Bluetooth, which needs a helper
	/// process, every 6 s).
	private func startPolling() {
		guard poll == nil else { return }
		poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
			guard let self else { return }
			self.ticks += 1
			let instances = Plugin.shared.instances(of: self)
			if self.ticks % 3 == 0, instances.contains(where: { self.feature($0) == .bluetooth }) {
				self.center.refreshBluetooth { [weak self] in self?.refreshAll() }
			}
			instances.forEach(self.render)
		}
	}

	private func refreshAll() {
		Plugin.shared.instances(of: self).forEach(render)
	}

	private func render(_ instance: Instance) {
		let feature = feature(instance)
		let label = instance.bool("showLabel", true) ? feature.title : nil
		guard feature.isToggle else {
			Plugin.shared.setImage(instance, Render.iconKey(symbol: feature.symbol(on: true), label: label))
			return
		}
		let on = center.state(feature)
		let color: NSColor
		switch feature {
		case .micMute: color = Render.Palette.red
		case .nightShift, .keepAwake: color = Render.Palette.orange
		default: color = Render.Palette.blue
		}
		Plugin.shared.setImage(instance, Render.toggleKey(symbol: feature.symbol(on: on ?? false), label: label, on: on, color: color))
		if instance.isEncoder {
			Plugin.shared.setFeedback(instance, ["title": feature.title, "value": on.map { $0 ? "On" : "Off" } ?? "N/A"])
		}
	}
}
