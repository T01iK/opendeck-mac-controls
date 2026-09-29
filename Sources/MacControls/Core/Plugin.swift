import AppKit
import Foundation

/// One placed action (a key or a dial) on a device.
final class Instance {
	let context: String
	let action: String
	let controller: String
	var settings: [String: Any]
	var isEncoder: Bool { controller == "Encoder" }

	fileprivate var lastImage: String?
	fileprivate var lastFeedback: String?
	/// Per-instance scratch space for handlers.
	var state: [String: Any] = [:]

	init(context: String, action: String, controller: String, settings: [String: Any]) {
		self.context = context
		self.action = action
		self.controller = controller
		self.settings = settings
	}

	func string(_ key: String, _ fallback: String) -> String {
		(settings[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
	}

	func number(_ key: String, _ fallback: Double) -> Double {
		if let n = settings[key] as? NSNumber { return n.doubleValue }
		if let s = settings[key] as? String, let d = Double(s) { return d }
		return fallback
	}

	func bool(_ key: String, _ fallback: Bool) -> Bool {
		if let b = settings[key] as? Bool { return b }
		if let n = settings[key] as? NSNumber { return n.boolValue }
		return fallback
	}
}

protocol ActionHandler: AnyObject {
	/// Action UUIDs (without the plugin prefix) served by this handler.
	var actionIDs: [String] { get }
	func willAppear(_ instance: Instance)
	func willDisappear(_ instance: Instance)
	func settingsChanged(_ instance: Instance)
	func keyDown(_ instance: Instance)
	func keyUp(_ instance: Instance)
	func dialRotate(_ instance: Instance, ticks: Int)
	func dialDown(_ instance: Instance)
	func dialUp(_ instance: Instance)
	func messageFromInspector(_ instance: Instance, payload: [String: Any])
	func systemDidWakeUp()
}

extension ActionHandler {
	func willAppear(_ instance: Instance) {}
	func willDisappear(_ instance: Instance) {}
	func settingsChanged(_ instance: Instance) { willAppear(instance) }
	func keyDown(_ instance: Instance) {}
	func keyUp(_ instance: Instance) {}
	func dialRotate(_ instance: Instance, ticks: Int) {}
	func dialDown(_ instance: Instance) { keyDown(instance) }
	func dialUp(_ instance: Instance) { keyUp(instance) }
	func messageFromInspector(_ instance: Instance, payload: [String: Any]) {}
	func systemDidWakeUp() { Plugin.shared.instances(of: self).forEach { willAppear($0) } }
}

/// OpenDeck / Stream Deck SDK websocket connection. Everything runs on the main queue.
final class Plugin {
	static let prefix = "com.t01ik.macoscontrols."
	static var shared: Plugin!

	private let port: Int
	private let uuid: String
	private let registerEvent: String
	private var socket: URLSessionWebSocketTask?
	private let handlerList: [ActionHandler]
	private var handlers: [String: ActionHandler] = [:]
	private var instances: [String: Instance] = [:]

	init(port: Int, uuid: String, registerEvent: String, handlers: [ActionHandler]) {
		self.port = port
		self.uuid = uuid
		self.registerEvent = registerEvent
		self.handlerList = handlers
		for handler in handlers {
			for id in handler.actionIDs { self.handlers[Plugin.prefix + id] = handler }
		}
	}

	func start() {
		let task = URLSession.shared.webSocketTask(with: URL(string: "ws://localhost:\(port)")!)
		socket = task
		task.resume()
		send(["event": registerEvent, "uuid": uuid])
		receive()
		Log.info("Connecting to OpenDeck on port \(port)")
	}

	private func receive() {
		socket?.receive { [weak self] result in
			DispatchQueue.main.async {
				guard let self else { return }
				switch result {
				case .success(.string(let text)):
					self.handle(text)
					self.receive()
				case .success(.data(let data)):
					self.handle(String(decoding: data, as: UTF8.self))
					self.receive()
				case .success:
					self.receive()
				case .failure(let error):
					Log.error("Socket closed: \(error.localizedDescription)")
					exit(0)
				}
			}
		}
	}

	// MARK: Inbound

	private func handle(_ text: String) {
		guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
		      let event = json["event"] as? String
		else { return }

		if event == "systemDidWakeUp" {
			handlerList.forEach { $0.systemDidWakeUp() }
			return
		}

		guard let context = json["context"] as? String else { return }
		let payload = json["payload"] as? [String: Any] ?? [:]

		if event == "willAppear" {
			guard let action = json["action"] as? String, let handler = handlers[action] else { return }
			let instance = Instance(
				context: context,
				action: String(action.dropFirst(Plugin.prefix.count)),
				controller: payload["controller"] as? String ?? "Keypad",
				settings: payload["settings"] as? [String: Any] ?? [:]
			)
			instances[context] = instance
			handler.willAppear(instance)
			return
		}

		guard let instance = instances[context], let handler = handlers[Plugin.prefix + instance.action] else { return }

		switch event {
		case "willDisappear":
			handler.willDisappear(instance)
			instances[context] = nil
		case "didReceiveSettings":
			instance.settings = payload["settings"] as? [String: Any] ?? [:]
			handler.settingsChanged(instance)
		case "keyDown":
			handler.keyDown(instance)
		case "keyUp":
			handler.keyUp(instance)
		case "dialRotate":
			handler.dialRotate(instance, ticks: (payload["ticks"] as? NSNumber)?.intValue ?? 0)
		case "dialDown":
			handler.dialDown(instance)
		case "dialUp":
			handler.dialUp(instance)
		case "sendToPlugin":
			handler.messageFromInspector(instance, payload: payload)
		default:
			break
		}
	}

	// MARK: Outbound

	func instances(of handler: ActionHandler) -> [Instance] {
		instances.values.filter { handlers[Plugin.prefix + $0.action] === handler }
	}

	func isAlive(_ instance: Instance) -> Bool {
		instances[instance.context] === instance
	}

	func setImage(_ instance: Instance, _ dataURI: String) {
		guard instance.lastImage != dataURI else { return }
		instance.lastImage = dataURI
		send(["event": "setImage", "context": instance.context, "payload": ["image": dataURI, "target": 0]])
	}

	func setTitle(_ instance: Instance, _ title: String) {
		send(["event": "setTitle", "context": instance.context, "payload": ["title": title, "target": 0]])
	}

	/// Updates an encoder's feedback layout (e.g. the $B1 value + indicator bar).
	func setFeedback(_ instance: Instance, _ payload: [String: Any]) {
		guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys) else { return }
		let key = String(decoding: data, as: UTF8.self)
		guard instance.lastFeedback != key else { return }
		instance.lastFeedback = key
		send(["event": "setFeedback", "context": instance.context, "payload": payload])
	}

	/// Switches an encoder to another layout (a built-in "$…" id or a JSON file in the plugin folder).
	func setFeedbackLayout(_ instance: Instance, _ layout: String) {
		instance.lastFeedback = nil
		send(["event": "setFeedbackLayout", "context": instance.context, "payload": ["layout": layout]])
	}

	func setSettings(_ instance: Instance) {
		send(["event": "setSettings", "context": instance.context, "payload": instance.settings])
	}

	func showOk(_ instance: Instance) {
		send(["event": "showOk", "context": instance.context])
	}

	func showAlert(_ instance: Instance) {
		send(["event": "showAlert", "context": instance.context])
	}

	func sendToInspector(_ instance: Instance, _ payload: [String: Any]) {
		send(["event": "sendToPropertyInspector", "context": instance.context, "payload": payload])
	}

	func openURL(_ url: String) {
		send(["event": "openUrl", "payload": ["url": url]])
	}

	private func send(_ object: [String: Any]) {
		guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
		socket?.send(.string(String(decoding: data, as: UTF8.self))) { error in
			if let error { Log.error("Send failed: \(error.localizedDescription)") }
		}
	}
}
