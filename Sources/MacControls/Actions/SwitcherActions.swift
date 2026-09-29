import AppKit
import CoreAudio

/// Switches the sound output device.
///
/// Settings: `mode` ("select" | "cycle", default "select"), `device` (UID, for "select"), `deviceName` (last known name),
/// `showLabel` (bool, default true).
/// The key highlights when its device is the current output; in "cycle" mode it shows the current device.
final class AudioOutputAction: ActionHandler {
	let actionIDs = ["audiooutput"]

	private let audio = SystemAudio.shared

	init() {
		audio.addObserver { [weak self] in self?.refreshAll() }
	}

	func willAppear(_ instance: Instance) { render(instance) }

	func keyDown(_ instance: Instance) {
		let devices = audio.outputDevices
		let target: SystemAudio.Device?
		if instance.string("mode", "select") == "cycle" {
			let index = devices.firstIndex { $0.uid == audio.outputDeviceUID } ?? -1
			target = devices.isEmpty ? nil : devices[(index + 1) % devices.count]
		} else {
			target = devices.first { $0.uid == instance.string("device", "") }
		}
		guard let target, audio.setOutputDevice(uid: target.uid) else { return Plugin.shared.showAlert(instance) }
		refreshAll()
	}

	func messageFromInspector(_ instance: Instance, payload: [String: Any]) {
		guard payload["request"] as? String == "listDevices" else { return }
		Plugin.shared.sendToInspector(instance, ["devices": audio.outputDevices.map { ["uid": $0.uid, "name": $0.name] }])
	}

	private func refreshAll() {
		Plugin.shared.instances(of: self).forEach(render)
	}

	private func render(_ instance: Instance) {
		let devices = audio.outputDevices
		let currentUID = audio.outputDeviceUID
		let showLabel = instance.bool("showLabel", true)
		if instance.string("mode", "select") == "cycle" {
			let current = devices.first { $0.uid == currentUID }
			Plugin.shared.setImage(instance, Render.toggleKey(
				symbol: current.map(Self.symbol) ?? "speaker.slash.fill", label: showLabel ? current?.name ?? "No output" : nil, on: current != nil
			))
			return
		}
		let uid = instance.string("device", "")
		guard let device = devices.first(where: { $0.uid == uid }) else {
			let name = instance.string("deviceName", "Choose device")
			Plugin.shared.setImage(instance, Render.toggleKey(symbol: "speaker.slash.fill", label: showLabel ? name : nil, on: nil))
			return
		}
		Plugin.shared.setImage(instance, Render.toggleKey(
			symbol: Self.symbol(device), label: showLabel ? device.name : nil, on: device.uid == currentUID
		))
	}

	/// Picks an icon from the device name and transport, similar to the Sound menu.
	static func symbol(_ device: SystemAudio.Device) -> String {
		let name = device.name.lowercased()
		if name.contains("airpods") { return "airpods" }
		if ["headphone", "headset", "buds", "earphone"].contains(where: name.contains) { return "headphones" }
		switch device.transport {
		case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
		case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
		case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
		case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
		case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
		default: return "hifispeaker.fill"
		}
	}
}

/// Switches keyboard layout / input method.
///
/// Settings: `mode` ("next" | "select", default "next"), `source` (input source ID, for "select"),
/// `showLabel` (bool, default true).
final class InputSourceAction: ActionHandler {
	let actionIDs = ["inputsource"]

	init() {
		DistributedNotificationCenter.default().addObserver(
			forName: .init("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"), object: nil, queue: .main
		) { [weak self] _ in self?.refreshAll() }
	}

	func willAppear(_ instance: Instance) { render(instance) }

	func keyDown(_ instance: Instance) {
		let ok = instance.string("mode", "next") == "select"
			? InputSources.select(id: instance.string("source", ""))
			: InputSources.selectNext()
		if !ok { Plugin.shared.showAlert(instance) }
		// The change notification can lag; render right away too.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.refreshAll() }
	}

	func messageFromInspector(_ instance: Instance, payload: [String: Any]) {
		guard payload["request"] as? String == "listSources" else { return }
		Plugin.shared.sendToInspector(instance, ["sources": InputSources.all.map { ["id": $0.id, "name": $0.name] }])
	}

	private func refreshAll() {
		Plugin.shared.instances(of: self).forEach(render)
	}

	private func render(_ instance: Instance) {
		let current = InputSources.current
		let shown: InputSources.Source?
		let active: Bool?
		if instance.string("mode", "next") == "select" {
			shown = InputSources.all.first { $0.id == instance.string("source", "") }
			active = shown.map { $0.id == current?.id }
		} else {
			shown = current
			active = current != nil
		}
		let showLabel = instance.bool("showLabel", true)
		Plugin.shared.setImage(instance, Render.dataURI { rect in
			Render.fillBackground(rect)
			let circle = showLabel ? CGRect(x: 30, y: 10, width: 84, height: 84) : CGRect(x: 16, y: 16, width: 112, height: 112)
			(active == true ? Render.Palette.blue : NSColor(calibratedWhite: 1, alpha: 0.2)).setFill()
			NSBezierPath(ovalIn: circle).fill()
			Render.drawText(shown?.code ?? "?", in: circle.insetBy(dx: circle.width * 0.1, dy: circle.width * 0.2), size: circle.width * 0.43, weight: .bold)
			if showLabel {
				Render.drawText(shown?.name ?? "Choose layout", in: CGRect(x: 4, y: 104, width: 136, height: 30), size: 20, minSize: 16)
			}
		})
	}
}
