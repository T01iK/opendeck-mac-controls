import AppKit

/// Runs a Shortcuts.app shortcut through the `shortcuts` command-line tool.
///
/// Settings: `name`, `shortcutId` (identifier, preferred when present), `input` (optional text passed as input),
/// `showName` (bool, default true), `useIcon` (bool, default true — show the shortcut's own icon).
final class ShortcutAction: ActionHandler {
	let actionIDs = ["shortcut"]

	private var running: Set<String> = []

	func willAppear(_ instance: Instance) { render(instance) }

	func keyDown(_ instance: Instance) {
		let name = instance.string("name", "")
		let target = instance.string("shortcutId", name)
		guard !target.isEmpty else { return Plugin.shared.showAlert(instance) }
		guard !running.contains(instance.context) else { return }
		running.insert(instance.context)
		render(instance)

		var arguments = ["run", target]
		var inputFile: URL?
		let input = instance.string("input", "")
		if !input.isEmpty {
			let file = FileManager.default.temporaryDirectory.appendingPathComponent("macdeck-shortcut-\(UUID().uuidString).txt")
			try? input.write(to: file, atomically: true, encoding: .utf8)
			arguments += ["--input-path", file.path]
			inputFile = file
		}

		Self.run(arguments) { [weak self] status, _, error in
			inputFile.map { try? FileManager.default.removeItem(at: $0) }
			guard let self else { return }
			self.running.remove(instance.context)
			guard Plugin.shared.isAlive(instance) else { return }
			if status == 0 {
				Log.info("Shortcut '\(name)' finished")
				Plugin.shared.showOk(instance)
			} else {
				Log.error("Shortcut '\(name)' failed (\(status)): \(error)")
				Plugin.shared.showAlert(instance)
			}
			self.render(instance)
		}
	}

	func messageFromInspector(_ instance: Instance, payload: [String: Any]) {
		guard payload["request"] as? String == "listShortcuts" else { return }
		Self.run(["list", "--show-identifiers"]) { _, output, _ in
			let shortcuts = output.split(separator: "\n").compactMap { Self.parseListLine(String($0)) }
				.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
				.map { ["name": $0.name, "id": $0.id] }
			Plugin.shared.sendToInspector(instance, ["shortcuts": shortcuts])
		}
	}

	/// `shortcuts list --show-identifiers` prints "Name (UUID)"; names may contain parentheses themselves.
	static func parseListLine(_ line: String) -> (name: String, id: String)? {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return nil }
		guard trimmed.hasSuffix(")"), let open = trimmed.range(of: " (", options: .backwards) else { return (trimmed, "") }
		let id = String(trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)])
		guard UUID(uuidString: id) != nil else { return (trimmed, "") }
		return (String(trimmed[..<open.lowerBound]), id)
	}

	private func render(_ instance: Instance) {
		let busy = running.contains(instance.context)
		var name = instance.string("name", "")
		let entry = ShortcutIcons.shared.entry(identifier: instance.string("shortcutId", ""), name: name)
		// Follow renames when the shortcut is referenced by identifier.
		if let entry { name = entry.name }
		let label = instance.bool("showName", true) && !name.isEmpty ? name : nil

		if instance.bool("useIcon", true), let entry, let icon = ShortcutIcons.shared.image(for: entry) {
			Plugin.shared.setImage(instance, Render.imageKey(icon, label: label, busy: busy))
			return
		}
		let symbol = busy ? "hourglass" : "square.2.layers.3d.fill"
		Plugin.shared.setImage(instance, Render.iconKey(symbol: symbol, label: label, color: Render.Palette.purple, labelLines: 2))
	}

	/// Runs /usr/bin/shortcuts off the main thread and reports back on the main queue.
	private static func run(_ arguments: [String], completion: @escaping (Int32, String, String) -> Void) {
		DispatchQueue.global(qos: .userInitiated).async {
			let result = Subprocess.run("/usr/bin/shortcuts", arguments)
			DispatchQueue.main.async { completion(result.status, result.output, result.error) }
		}
	}
}
