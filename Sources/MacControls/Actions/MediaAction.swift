import AppKit

/// Play/pause, next and previous. The play/pause key can show the current track (artwork, title, progress).
///
/// Settings: `command` ("playpause" | "next" | "previous"), `showInfo` (bool, default true),
/// `dialMode` ("tracks" | "scrub", default "tracks"), `scrubStep` (seconds per tick, default 5),
/// `scrollText` (bool, default false), `scrollSpeed` ("slow" | "normal" | "fast", default "normal").
/// Dial: rotate = previous / next track or scrub through the current one, press = play/pause. The dial uses a custom
/// layout (layouts/media.json) with one full-size pixmap that this action draws, so long text can scroll smoothly.
final class MediaAction: ActionHandler {
	let actionIDs = ["media"]

	private let nowPlaying = NowPlaying.shared
	private var progressTimer: Timer?
	private var lastDialCommand = Date.distantPast
	/// Scrub target accumulated over fast ticks; sent once the dial pauses briefly.
	private var scrubTarget: Double?
	private var scrubSend: DispatchWorkItem?
	private var scrubbingUntil = Date.distantPast
	private var scrubPosition: Double = 0
	/// Marquee state: when each instance's current text first appeared, and which instances are scrolling right now.
	private var marqueeStart: [String: (text: String, date: Date)] = [:]
	private var scrolling: Set<String> = []
	private var animationTimer: Timer?

	init() {
		nowPlaying.onChange = { [weak self] in self?.refreshAll() }
	}

	func willAppear(_ instance: Instance) {
		nowPlaying.start()
		// Knobs placed before the custom layout existed still have "$B1" stored in the profile.
		if instance.isEncoder { Plugin.shared.setFeedbackLayout(instance, "layouts/media.json") }
		render(instance)
		updateTimer()
	}

	func willDisappear(_ instance: Instance) {
		DispatchQueue.main.async { [weak self] in self?.updateTimer() }
	}

	func keyDown(_ instance: Instance) {
		switch instance.string("command", "playpause") {
		case "next": nowPlaying.send("next")
		case "previous": nowPlaying.send("previous")
		default: nowPlaying.send("togglePlayPause")
		}
	}

	func dialDown(_ instance: Instance) {
		nowPlaying.send("togglePlayPause")
	}

	func dialUp(_ instance: Instance) {}

	func dialRotate(_ instance: Instance, ticks: Int) {
		if instance.string("dialMode", "tracks") == "scrub" { return scrub(instance, ticks: ticks) }
		// A fast spin produces several events; only skip one track at a time.
		guard ticks != 0, Date().timeIntervalSince(lastDialCommand) > 0.35 else { return }
		lastDialCommand = Date()
		nowPlaying.send(ticks > 0 ? "next" : "previous")
	}

	private func scrub(_ instance: Instance, ticks: Int) {
		let info = nowPlaying.info
		guard nowPlaying.available, !info.isEmpty, ticks != 0 else { return Plugin.shared.showAlert(instance) }
		let step = instance.number("scrubStep", 5)
		var target = (scrubTarget ?? info.currentElapsed) + Double(ticks) * step
		target = max(0, info.duration > 0 ? min(target, info.duration - 1) : target)
		scrubTarget = target
		scrubPosition = target
		scrubbingUntil = Date().addingTimeInterval(1.5)
		render(instance)

		// Coalesce a fast spin into one seek.
		scrubSend?.cancel()
		let work = DispatchWorkItem { [weak self] in
			guard let self, let target = self.scrubTarget else { return }
			self.scrubTarget = nil
			self.nowPlaying.seek(to: target)
		}
		scrubSend = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
			guard let self, Date() >= self.scrubbingUntil, Plugin.shared.isAlive(instance) else { return }
			self.render(instance)
		}
	}

	static func formatTime(_ seconds: Double) -> String {
		let total = Int(max(0, seconds))
		let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
		return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
	}

	// MARK: Rendering

	private func refreshAll() {
		Plugin.shared.instances(of: self).forEach(render)
		updateTimer()
	}

	/// Ticks once per second while something is playing so the progress bar moves.
	private func updateTimer() {
		let needed = nowPlaying.info.playing && Plugin.shared.instances(of: self).contains { showsInfo($0) }
		if needed, progressTimer == nil {
			progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
				guard let self else { return }
				Plugin.shared.instances(of: self).filter(self.showsInfo).forEach(self.render)
			}
		} else if !needed {
			progressTimer?.invalidate()
			progressTimer = nil
		}
	}

	private func showsInfo(_ instance: Instance) -> Bool {
		(instance.isEncoder || instance.string("command", "playpause") == "playpause") && instance.bool("showInfo", true)
	}

	private func render(_ instance: Instance) {
		let info = nowPlaying.info
		if instance.isEncoder {
			let scrubbing = Date() < scrubbingUntil
			let text = info.isEmpty ? "" : info.artist + info.title
			var overflow = false
			let canvas = Render.stripDataURI { rect in
				overflow = self.drawKnob(rect, info: info, scrubbing: scrubbing, elapsed: self.marqueeElapsed(instance, text), speed: self.scrollSpeed(instance))
			}
			Plugin.shared.setFeedback(instance, ["canvas": canvas])
			setScrolling(instance, overflow)
			return
		}
		let command = instance.string("command", "playpause")
		if showsInfo(instance), !info.isEmpty {
			var overflow = false
			let image = Render.dataURI { rect in
				overflow = Self.drawNowPlayingKey(rect, info: info, elapsed: self.marqueeElapsed(instance, info.title), speed: self.scrollSpeed(instance))
			}
			Plugin.shared.setImage(instance, image)
			setScrolling(instance, overflow)
			return
		}
		setScrolling(instance, false)
		let symbol: String
		switch command {
		case "next": symbol = "forward.fill"
		case "previous": symbol = "backward.fill"
		default:
			if nowPlaying.available { symbol = info.playing ? "pause.fill" : "play.fill" } else { symbol = "playpause.fill" }
		}
		Plugin.shared.setImage(instance, Render.iconKey(symbol: symbol))
	}

	// MARK: Marquee

	/// Scroll speed in points per second, or nil when scrolling is off.
	private func scrollSpeed(_ instance: Instance) -> CGFloat? {
		guard instance.bool("scrollText", false) else { return nil }
		switch instance.string("scrollSpeed", "normal") {
		case "slow": return 25
		case "fast": return 60
		default: return 40
		}
	}

	/// Seconds since `text` first appeared on this instance (restarts the scroll when the track changes).
	private func marqueeElapsed(_ instance: Instance, _ text: String) -> TimeInterval {
		if let start = marqueeStart[instance.context], start.text == text { return Date().timeIntervalSince(start.date) }
		marqueeStart[instance.context] = (text, Date())
		return 0
	}

	/// Re-renders scrolling instances at 10 fps; stops when nothing overflows.
	private func setScrolling(_ instance: Instance, _ overflow: Bool) {
		if overflow { scrolling.insert(instance.context) } else { scrolling.remove(instance.context) }
		if !scrolling.isEmpty, animationTimer == nil {
			animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
				guard let self else { return }
				let instances = Plugin.shared.instances(of: self).filter { self.scrolling.contains($0.context) }
				if instances.isEmpty { self.scrolling.removeAll() }
				instances.forEach(self.render)
				if self.scrolling.isEmpty {
					self.animationTimer?.invalidate()
					self.animationTimer = nil
				}
			}
		}
	}

	// MARK: Drawing

	/// Dial segment: artwork (no caption, the title is right next to it), artist, title and progress.
	/// While scrubbing, the position replaces the title. Returns whether any text scrolls.
	private func drawKnob(_ rect: CGRect, info: NowPlaying.Info, scrubbing: Bool, elapsed: TimeInterval, speed: CGFloat?) -> Bool {
		Render.fillBackground(rect, .black)
		let art = CGRect(x: 10, y: 28, width: 62, height: 62)
		guard !info.isEmpty else {
			Render.drawSymbol("music.note", in: art.insetBy(dx: 12, dy: 12), color: Render.Palette.secondary)
			Render.drawText("Not playing", in: CGRect(x: 80, y: 42, width: 112, height: 30), size: 20, color: Render.Palette.secondary, alignment: .left)
			return false
		}
		if let artwork = info.artwork {
			Self.drawAspectFill(artwork, in: art, fraction: info.playing ? 1 : 0.55)
		} else {
			NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
			NSBezierPath(roundedRect: art, xRadius: 6, yRadius: 6).fill()
			Render.drawSymbol("music.note", in: art.insetBy(dx: 16, dy: 16), color: Render.Palette.secondary)
		}
		let badge = CGRect(x: art.maxX - 22, y: art.minY + 3, width: 19, height: 19)
		NSColor(calibratedWhite: 0, alpha: 0.65).setFill()
		NSBezierPath(ovalIn: badge).fill()
		Render.drawSymbol(info.playing ? "pause.fill" : "play.fill", in: badge.insetBy(dx: 5, dy: 5), color: .white)

		var overflow = Render.drawMarquee(info.artist, in: CGRect(x: 10, y: 4, width: 182, height: 22), size: 16, weight: .semibold,
		                                  color: Render.Palette.secondary, elapsed: elapsed, speed: speed)
		let main = CGRect(x: 82, y: 32, width: 110, height: 32)
		let position = scrubbing ? scrubPosition : info.currentElapsed
		if scrubbing {
			Render.drawValue(Self.formatTime(position), unit: info.duration > 0 ? "/ " + Self.formatTime(info.duration) : "", in: main, size: 24,
			                 alignment: .left)
		} else {
			overflow = Render.drawMarquee(info.title, in: main, size: 24, weight: .bold, elapsed: elapsed, speed: speed) || overflow
		}
		if info.duration > 0 {
			Render.drawBar(CGRect(x: 82, y: 74, width: 110, height: 10), fraction: position / info.duration, color: .white)
		}
		return overflow
	}

	/// Key: artwork with play state, title and progress. Titles that do not fit two lines scroll on one line.
	static func drawNowPlayingKey(_ rect: CGRect, info: NowPlaying.Info, elapsed: TimeInterval, speed: CGFloat?) -> Bool {
		Render.fillBackground(rect)
		if let artwork = info.artwork {
			drawAspectFill(artwork, in: rect, fraction: info.playing ? 1 : 0.55)
		} else {
			Render.drawSymbol("music.note", in: CGRect(x: 40, y: 18, width: 64, height: 56), color: Render.Palette.secondary)
		}

		// Darken the lower part so the title stays readable on any artwork.
		let gradient = NSGradient(colors: [NSColor(calibratedWhite: 0, alpha: 0), NSColor(calibratedWhite: 0, alpha: 0.85)])
		gradient?.draw(in: CGRect(x: 0, y: 64, width: rect.width, height: 80), angle: 90)

		let singleLine = NSAttributedString(string: info.title, attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .bold)]).size().width
		var overflow = false
		if singleLine <= 132 * 1.8 || speed == nil {
			Render.drawText(info.title, in: CGRect(x: 6, y: 86, width: 132, height: 44), size: 19, weight: .bold, maxLines: 2, minSize: 15)
		} else {
			overflow = Render.drawMarquee(info.title, in: CGRect(x: 6, y: 100, width: 132, height: 28), size: 19, weight: .bold, elapsed: elapsed, speed: speed)
		}

		// Play-state glyph in the top-right corner.
		let badge = CGRect(x: 104, y: 6, width: 34, height: 34)
		NSColor(calibratedWhite: 0, alpha: 0.6).setFill()
		NSBezierPath(ovalIn: badge).fill()
		Render.drawSymbol(info.playing ? "pause.fill" : "play.fill", in: badge.insetBy(dx: 9, dy: 9), color: .white)

		if let progress = info.progress {
			Render.drawBar(CGRect(x: 0, y: 138, width: rect.width, height: 6), fraction: progress, color: .white)
		}
		return overflow
	}

	private static func drawAspectFill(_ image: NSImage, in rect: CGRect, fraction: CGFloat) {
		NSGraphicsContext.saveGraphicsState()
		NSBezierPath(roundedRect: rect, xRadius: rect.width < 100 ? 6 : 0, yRadius: rect.width < 100 ? 6 : 0).addClip()
		let scale = max(rect.width / image.size.width, rect.height / image.size.height)
		let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
		let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
		image.draw(in: target, from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true, hints: nil)
		NSGraphicsContext.restoreGraphicsState()
	}
}
