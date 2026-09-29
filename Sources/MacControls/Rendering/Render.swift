import AppKit

/// Drawing primitives for key and dial images (AppKit + SF Symbols), rendered to PNG data URIs.
/// Coordinates are top-down (flipped): keys are 144×144, dial segments 200×100. Complete key layouts are in
/// KeyLayouts.swift, the static icon catalog in KeyCatalog.swift.
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
		png(width: size, height: size, draw)
	}

	static func png(width: CGFloat, height: CGFloat, _ draw: (CGRect) -> Void) -> Data {
		let rep = NSBitmapImageRep(
			bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8, samplesPerPixel: 4,
			hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
		)!
		rep.size = NSSize(width: width, height: height)
		let context = NSGraphicsContext(bitmapImageRep: rep)!
		// Flip so that y grows downwards, which makes layouts easier to read.
		context.cgContext.translateBy(x: 0, y: height)
		context.cgContext.scaleBy(x: 1, y: -1)
		let flipped = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = flipped
		draw(CGRect(x: 0, y: 0, width: width, height: height))
		NSGraphicsContext.restoreGraphicsState()
		return rep.representation(using: .png, properties: [:])!
	}

	static func dataURI(_ draw: (CGRect) -> Void) -> String {
		"data:image/png;base64," + png(draw).base64EncodedString()
	}

	/// Dial strip segment (200×100, the Stream Deck + size OpenDeck renders encoder layouts at).
	static func stripDataURI(_ draw: (CGRect) -> Void) -> String {
		"data:image/png;base64," + png(width: 200, height: 100, draw).base64EncodedString()
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

	/// Draws one line of text; if it is wider than `rect` it scrolls like a marquee: it rests at the start, scrolls
	/// through, and loops with a gap. `elapsed` is the time since the text first appeared; `speed` is in points per
	/// second, nil disables scrolling (long text is truncated with "…"). Returns whether it scrolls (the caller then has
	/// to keep re-rendering to animate it).
	@discardableResult
	static func drawMarquee(
		_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor = Palette.text,
		alignment: NSTextAlignment = .left, elapsed: TimeInterval, speed: CGFloat? = 40
	) -> Bool {
		let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
		let string = NSAttributedString(string: text, attributes: attributes)
		let textSize = string.size()
		let y = rect.midY - textSize.height / 2
		guard textSize.width > rect.width else {
			let x: CGFloat
			switch alignment {
			case .center: x = rect.midX - textSize.width / 2
			case .right: x = rect.maxX - textSize.width
			default: x = rect.minX
			}
			string.draw(at: CGPoint(x: x, y: y))
			return false
		}
		guard let speed, speed > 0 else {
			let paragraph = NSMutableParagraphStyle()
			paragraph.lineBreakMode = .byTruncatingTail
			paragraph.alignment = alignment
			var truncated = attributes
			truncated[.paragraphStyle] = paragraph
			NSAttributedString(string: text, attributes: truncated)
				.draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: textSize.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
			return false
		}
		let rest: TimeInterval = 1.5
		let gap: CGFloat = size * 2.5
		let loop = textSize.width + gap
		let cycle = rest + Double(loop / speed)
		let phase = elapsed.truncatingRemainder(dividingBy: cycle)
		let offset = phase < rest ? 0 : CGFloat(phase - rest) * speed

		NSGraphicsContext.saveGraphicsState()
		NSBezierPath(rect: rect).addClip()
		string.draw(at: CGPoint(x: rect.minX - offset, y: y))
		string.draw(at: CGPoint(x: rect.minX - offset + loop, y: y))
		NSGraphicsContext.restoreGraphicsState()
		return true
	}

	/// Draws a number with a smaller unit after it ("346" + "KB/s"), shrinking both until they fit the width.
	static func drawValue(
		_ number: String, unit: String, in rect: CGRect, size: CGFloat, color: NSColor = Palette.text, alignment: NSTextAlignment = .center
	) {
		var fontSize = size
		var string = NSMutableAttributedString()
		while true {
			let paragraph = NSMutableParagraphStyle()
			paragraph.alignment = alignment
			string = NSMutableAttributedString(string: number, attributes: [
				.font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold), .foregroundColor: color, .paragraphStyle: paragraph,
			])
			if !unit.isEmpty {
				string.append(NSAttributedString(string: " " + unit, attributes: [
					.font: NSFont.systemFont(ofSize: fontSize * 0.5, weight: .semibold), .foregroundColor: Palette.secondary, .paragraphStyle: paragraph,
				]))
			}
			if string.size().width <= rect.width || fontSize <= 10 { break }
			fontSize -= 1
		}
		let height = string.size().height
		string.draw(with: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height), options: .usesLineFragmentOrigin)
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
}
