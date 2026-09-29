import AppKit

/// Static images for every action: the monochrome icons in OpenDeck's action list and the default key images the
/// manifest points to. `MacControls --generate-icons <bundle>` renders them into the plugin bundle at build time.
enum KeyCatalog {
	/// SF Symbol for each action's action-list icon (plus the category icon).
	static let listIcons: [String: String] = [
		"category": "command",
		"volume": "speaker.wave.2.fill", "brightness": "sun.max.fill", "keyboardbrightness": "light.max",
		"media": "playpause.fill", "audiooutput": "hifispeaker.fill", "inputsource": "globe",
		"missioncontrol": "rectangle.3.group.fill", "apps": "square.grid.3x3.fill", "spotlight": "magnifyingglass",
		"emoji": "face.smiling", "dictation": "mic.fill", "siri": "waveform",
		"shortcut": "square.2.layers.3d.fill", "openapp": "arrow.up.forward.app.fill",
		"controlcenter": "switch.2", "monitor": "gauge.with.dots.needle.67percent",
	]

	/// Symbol, caption and colour of each action's default key image (also used at runtime when a launcher hides its
	/// caption).
	static let defaultKeys: [String: (symbol: String, label: String?, color: NSColor)] = [
		"volume": ("speaker.wave.2.fill", "Volume", Render.Palette.text),
		"brightness": ("sun.max.fill", "Brightness", Render.Palette.yellow),
		"keyboardbrightness": ("light.max", "Keyboard", Render.Palette.teal),
		"media": ("playpause.fill", nil, Render.Palette.text),
		"audiooutput": ("hifispeaker.fill", "Output", Render.Palette.text),
		"inputsource": ("globe", "Layout", Render.Palette.text),
		"missioncontrol": ("rectangle.3.group.fill", "Mission", Render.Palette.blue),
		"apps": ("square.grid.3x3.fill", "Apps", Render.Palette.teal),
		"spotlight": ("magnifyingglass", "Spotlight", Render.Palette.text),
		"emoji": ("face.smiling.inverse", "Emoji", Render.Palette.yellow),
		"dictation": ("mic.fill", "Dictation", Render.Palette.red),
		"siri": ("waveform", "Siri", Render.Palette.purple),
		"shortcut": ("square.2.layers.3d.fill", "Shortcut", Render.Palette.purple),
		"openapp": ("arrow.up.forward.app.fill", "Open App", Render.Palette.blue),
		"controlcenter": ("switch.2", "Control", Render.Palette.blue),
		"monitor": ("gauge.with.dots.needle.67percent", "Monitor", Render.Palette.green),
	]

	/// The plugin's icon (OpenDeck's plugin list, the marketplace): a macOS-style rounded square with the ⌘ glyph.
	static func pluginIcon(size: CGFloat) -> Data {
		Render.png(size: size) { rect in
			let tile = rect.insetBy(dx: size * 0.06, dy: size * 0.06)
			let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
			NSGradient(
				starting: NSColor(calibratedRed: 0.36, green: 0.2, blue: 0.85, alpha: 1),
				ending: NSColor(calibratedRed: 0.25, green: 0.55, blue: 1, alpha: 1)
			)?.draw(in: path, angle: -90)
			Render.drawSymbol("command", in: tile.insetBy(dx: tile.width * 0.24, dy: tile.width * 0.24), color: .white, weight: .semibold)
		}
	}

	/// Writes icons/<name>[@2x].png and keys/<name>[@2x].png into the plugin bundle.
	static func generate(into directory: URL) throws {
		let icons = directory.appendingPathComponent("icons")
		let keys = directory.appendingPathComponent("keys")
		try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)

		for (name, symbol) in listIcons {
			try Render.listIcon(symbol: symbol, size: 20).write(to: icons.appendingPathComponent("\(name).png"))
			try Render.listIcon(symbol: symbol, size: 40).write(to: icons.appendingPathComponent("\(name)@2x.png"))
		}
		try pluginIcon(size: 28).write(to: icons.appendingPathComponent("plugin.png"))
		try pluginIcon(size: 56).write(to: icons.appendingPathComponent("plugin@2x.png"))

		for (name, spec) in defaultKeys {
			let uri = Render.iconKey(symbol: spec.symbol, label: spec.label, color: spec.color)
			let data = Data(base64Encoded: String(uri.dropFirst("data:image/png;base64,".count)))!
			try data.write(to: keys.appendingPathComponent("\(name)@2x.png"))
			// 72×72 variant for 1x consumers.
			let small = Render.png(size: 72) { rect in
				NSImage(data: data)?.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
			}
			try small.write(to: keys.appendingPathComponent("\(name).png"))
		}
	}
}
