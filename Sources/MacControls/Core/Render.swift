import AppKit

/// Draws key images with AppKit + SF Symbols and returns them as PNG data URIs.
/// All layout coordinates are top-down (flipped) on a 144×144 canvas.
enum Render {
	static let size: CGFloat = 144

	enum Palette {
		static let background = NSColor(calibratedWhite: 0.07, alpha: 1)
		static let track = NSColor(calibratedWhite: 1, alpha: 0.16)
		static let text = NSColor.white
		static let secondary = NSColor(calibratedWhite: 1, alpha: 0.6)
		static let red = NSColor(calibratedRed: 1, green: 0.27, blue: 0.23, alpha: 1)
		static let orange = NSColor(calibratedRed: 1, green: 0.62, blue: 0.04, alpha: 1)
		static let yellow = NSColor(calibratedRed: 1, green: 0.84, blue: 0.04, alpha: 1)
		static let green = NSColor(calibratedRed: 0.2, green: 0.84, blue: 0.29, alpha: 1)
		static let blue = NSColor(calibratedRed: 0.04, green: 0.52, blue: 1, alpha: 1)
		static let teal = NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.98, alpha: 1)
		static let purple = NSColor(calibratedRed: 0.75, green: 0.35, blue: 0.95, alpha: 1)
	}

	// MARK: Canvas

	static func png(size: CGFloat = size, _ draw: (CGRect) -> Void) -> Data {
		let pixels = Int(size)
		let rep = NSBitmapImageRep(
			bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
			hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
		)!
		rep.size = NSSize(width: size, height: size)
		let context = NSGraphicsContext(bitmapImageRep: rep)!
		// Flip so that y grows downwards, which makes layouts easier to read.
		context.cgContext.translateBy(x: 0, y: size)
		context.cgContext.scaleBy(x: 1, y: -1)
		let flipped = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = flipped
		draw(CGRect(x: 0, y: 0, width: size, height: size))
		NSGraphicsContext.restoreGraphicsState()
		return rep.representation(using: .png, properties: [:])!
	}

	static func dataURI(_ draw: (CGRect) -> Void) -> String {
		"data:image/png;base64," + png(draw).base64EncodedString()
	}

	// MARK: Primitives

	static func fillBackground(_ rect: CGRect, _ color: NSColor = Palette.background) {
		color.setFill()
		rect.fill()
	}

	static func symbolImage(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .semibold, colors: [NSColor]) -> NSImage? {
		let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
			?? NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil)
		let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
			.applying(NSImage.SymbolConfiguration(paletteColors: colors))
		return image?.withSymbolConfiguration(config)
	}

	/// Draws an SF Symbol aspect-fit and centred inside `rect`.
	static func drawSymbol(_ name: String, in rect: CGRect, color: NSColor, secondary: NSColor? = nil, weight: NSFont.Weight = .semibold) {
		let colors = secondary.map { [color, $0] } ?? [color]
		guard let image = symbolImage(name, pointSize: rect.height, weight: weight, colors: colors) else { return }
		let scale = min(rect.width / image.size.width, rect.height / image.size.height)
		let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
		let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
		image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
	}

	/// Draws text centred in `rect`, shrinking the font until it fits within `maxLines` (then truncating).
	static func drawText(
		_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor = Palette.text,
		alignment: NSTextAlignment = .center, maxLines: Int = 1, minSize: CGFloat = 11, monospacedDigits: Bool = false
	) {
		func attributed(_ fontSize: CGFloat) -> NSAttributedString {
			let font = monospacedDigits
				? NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
				: NSFont.systemFont(ofSize: fontSize, weight: weight)
			let paragraph = NSMutableParagraphStyle()
			paragraph.alignment = alignment
			paragraph.lineBreakMode = maxLines == 1 ? .byTruncatingTail : .byWordWrapping
			paragraph.maximumLineHeight = fontSize * 1.15
			paragraph.minimumLineHeight = fontSize * 1.15
			return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
		}

		guard !text.isEmpty else { return }
		func fits(_ string: NSAttributedString, _ fontSize: CGFloat) -> Bool {
			if maxLines == 1 { return string.size().width <= rect.width }
			let attributes = string.attributes(at: 0, effectiveRange: nil)
			// Wrapping must happen between words; a word wider than the box would be split mid-word.
			let widestWord = text.split(whereSeparator: \.isWhitespace)
				.map { NSAttributedString(string: String($0), attributes: attributes).size().width }.max() ?? 0
			let height = string.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height
			return widestWord <= rect.width && height <= fontSize * 1.15 * CGFloat(maxLines) + 0.5
		}

		var fontSize = size
		var string = attributed(fontSize)
		while fontSize > minSize, !fits(string, fontSize) {
			fontSize -= 1
			string = attributed(fontSize)
		}

		let lineHeight = fontSize * 1.15
		let fullHeight = string.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height
		let height = min(fullHeight, lineHeight * CGFloat(maxLines), max(rect.height, lineHeight))
		let target = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
		string.draw(with: target, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
	}

	static func drawBar(_ rect: CGRect, fraction: Double, color: NSColor) {
		let radius = rect.height / 2
		Palette.track.setFill()
		NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
		let clamped = max(0, min(1, fraction))
		guard clamped > 0 else { return }
		var filled = rect
		filled.size.width = max(rect.height, rect.width * clamped)
		color.setFill()
		NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
	}

	/// Draws a line + area chart. Values are normalised against `maximum`.
	static func drawSparkline(_ values: [Double], maximum: Double, in rect: CGRect, color: NSColor, capacity: Int, fill: Bool = true) {
		guard values.count > 1, maximum > 0 else { return }
		let step = rect.width / CGFloat(max(capacity - 1, 1))
		let startX = rect.maxX - step * CGFloat(values.count - 1)
		let points = values.enumerated().map { index, value in
			CGPoint(x: startX + step * CGFloat(index), y: rect.maxY - rect.height * CGFloat(max(0, min(1, value / maximum))))
		}
		let line = NSBezierPath()
		line.move(to: points[0])
		points.dropFirst().forEach { line.line(to: $0) }
		if fill {
			let area = line.copy() as! NSBezierPath
			area.line(to: CGPoint(x: points.last!.x, y: rect.maxY))
			area.line(to: CGPoint(x: points[0].x, y: rect.maxY))
			area.close()
			color.withAlphaComponent(0.28).setFill()
			area.fill()
		}
		color.setStroke()
		line.lineWidth = 3
		line.lineJoinStyle = .round
		line.stroke()
	}

	// MARK: Layouts

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
	static func iconKey(symbol: String, label: String? = nil, color: NSColor = Palette.text, background: NSColor = Palette.background, labelLines: Int = 1) -> String {
		dataURI { rect in
			fillBackground(rect, background)
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

	/// Icon used in OpenDeck's action list (monochrome, transparent background).
	static func listIcon(symbol: String, size: CGFloat) -> Data {
		png(size: size) { rect in
			drawSymbol(symbol, in: rect.insetBy(dx: size * 0.06, dy: size * 0.06), color: NSColor(calibratedWhite: 0.9, alpha: 1), weight: .medium)
		}
	}
}
