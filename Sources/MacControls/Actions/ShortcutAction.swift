import AppKit

/// Runs a Shortcuts.app shortcut through the `shortcuts` command-line tool.
///
/// Settings: `name` (shortcut name), `input` (optional text passed as input), `showName` (bool, default true).
final class ShortcutAction: ActionHandler {
	let actionIDs = ["shortcut"]

	private var running: Set<String> = []

	func willAppear(_ instance: Instance) { render(instance) }

	func keyDown(_ instance: Instance) {
		let name = instance.string("name", "")
		guard !name.isEmpty else { return Plugin.shared.showAlert(instance) }
		guard !running.contains(instance.context) else { return }
		running.insert(instance.context)
		render(instance)

		var arguments = ["run", name]
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
		Self.run(["list"]) { status, output, _ in
			let names = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
			Plugin.shared.sendToInspector(instance, ["shortcuts": names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }])
		}
	}

	private func render(_ instance: Instance) {
		let name = instance.string("name", "")
		let symbol = running.contains(instance.context) ? "hourglass" : "square.2.layers.3d.fill"
		let label = instance.bool("showName", true) && !name.isEmpty ? name : nil
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
