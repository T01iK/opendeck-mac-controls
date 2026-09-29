import AppKit

/// Complete key images built from the primitives in Render.swift. All return PNG data URIs for a 144×144 key.
extension Render {
	/// Symbol on top, big value, progress bar at the bottom (volume, brightness).
	static func levelKey(symbol: String, value: String, fraction: Double?, color: NSColor, badge: String? = nil) -> String {
		dataURI { rect in
			fillBackground(rect)
			drawSymbol(symbol, in: CGRect(x: 30, y: 14, width: 84, height: 52), color: color)
			if let badge {
				drawSymbol(badge, in: CGRect(x: 108, y: 8, width: 28, height: 28), color: Palette.secondary)
			}
			drawText(value, in: CGRect(x: 6, y: 70, width: 132, height: 40), size: 34, weight: .bold, monospacedDigits: true)
			if let fraction {
				drawBar(CGRect(x: 18, y: 118, width: 108, height: 10), fraction: fraction, color: color)
			}
		}
	}

	/// Large symbol with an optional caption underneath (launchers, shortcuts, media controls).
	static func iconKey(
		symbol: String, label: String? = nil, color: NSColor = Palette.text, background: NSColor = Palette.background,
		labelLines: Int = 1, badge: String? = nil
	) -> String {
		dataURI { rect in
			fillBackground(rect, background)
			if let badge {
				drawSymbol(badge, in: CGRect(x: 108, y: 8, width: 28, height: 28), color: Palette.secondary)
			}
			if let label, !label.isEmpty {
				let symbolHeight: CGFloat = labelLines > 1 ? 50 : 62
				drawSymbol(symbol, in: CGRect(x: 22, y: 14, width: 100, height: symbolHeight), color: color)
				let top = 14 + symbolHeight + 8
				drawText(label, in: CGRect(x: 8, y: top, width: 128, height: 136 - top), size: 22, maxLines: labelLines)
			} else {
				drawSymbol(symbol, in: CGRect(x: 26, y: 26, width: 92, height: 92), color: color)
			}
		}
	}

	/// A full-colour icon (app, shortcut) with an optional caption, running dot and busy overlay.
	static func imageKey(_ image: NSImage, label: String? = nil, runningDot: Bool = false, busy: Bool = false) -> String {
		dataURI { rect in
			fillBackground(rect)
			let hasLabel = !(label ?? "").isEmpty
			let iconRect = hasLabel ? CGRect(x: 26, y: 8, width: 92, height: 92) : CGRect(x: 14, y: 10, width: 116, height: 116)
			image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: busy ? 0.4 : 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
			if busy {
				drawSymbol("hourglass", in: iconRect.insetBy(dx: iconRect.width * 0.3, dy: iconRect.height * 0.3), color: .white)
			}
			if let label, hasLabel {
				drawText(label, in: CGRect(x: 6, y: 102, width: 132, height: 30), size: 20)
			}
			if runningDot {
				NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
				NSBezierPath(ovalIn: CGRect(x: 67, y: hasLabel ? 133 : 130, width: 10, height: 10)).fill()
			}
		}
	}

	/// Control Center style tile: a circle filled with `color` when on, grey when off, dimmed when unavailable (nil).
	/// Without a label the circle grows to fill the key.
	static func toggleKey(symbol: String, label: String?, on: Bool?, color: NSColor = Palette.blue) -> String {
		dataURI { rect in
			fillBackground(rect)
			let circle = label == nil ? CGRect(x: 16, y: 16, width: 112, height: 112) : CGRect(x: 30, y: 10, width: 84, height: 84)
			let fill: NSColor = on == true ? color : NSColor(calibratedWhite: 1, alpha: on == nil ? 0.08 : 0.2)
			fill.setFill()
			NSBezierPath(ovalIn: circle).fill()
			let glyphColor: NSColor = on == nil ? Palette.secondary.withAlphaComponent(0.4) : .white
			let glyphRect = circle.insetBy(dx: circle.width * 0.24, dy: circle.width * 0.24)
			if symbol == "bluetooth" {
				drawBluetoothRune(in: glyphRect, color: glyphColor)
			} else {
				drawSymbol(symbol, in: glyphRect, color: glyphColor)
			}
			if let label {
				drawText(on == nil ? "\(label) N/A" : label, in: CGRect(x: 4, y: 104, width: 136, height: 30), size: 21,
				         color: on == nil ? Palette.secondary : Palette.text, minSize: 16)
			}
		}
	}

	/// The Bluetooth logo (SF Symbols has none).
	static func drawBluetoothRune(in rect: CGRect, color: NSColor) {
		let w = rect.height * 0.5
		let x = rect.midX
		func point(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: x + dx * w / 2, y: rect.midY + dy * rect.height / 2) }
		let path = NSBezierPath()
		path.move(to: point(-1, -0.5))
		path.line(to: point(1, 0.5))
		path.line(to: point(0, 1))
		path.line(to: point(0, -1))
		path.line(to: point(1, -0.5))
		path.line(to: point(-1, 0.5))
		path.lineWidth = rect.height * 0.1
		path.lineJoinStyle = .round
		path.lineCapStyle = .round
		color.setStroke()
		path.stroke()
	}

	/// Icon used in OpenDeck's action list (monochrome, transparent background).
	static func listIcon(symbol: String, size: CGFloat) -> Data {
		png(size: size) { rect in
			drawSymbol(symbol, in: rect.insetBy(dx: size * 0.06, dy: size * 0.06), color: NSColor(calibratedWhite: 0.9, alpha: 1), weight: .medium)
		}
	}
}
