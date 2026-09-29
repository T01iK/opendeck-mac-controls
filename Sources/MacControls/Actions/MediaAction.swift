import AppKit

/// Play/pause, next and previous. The play/pause key can show the current track (artwork, title, progress).
///
/// Settings: `command` ("playpause" | "next" | "previous"), `showInfo` (bool, default true).
/// Dial: rotate = previous / next track, press = play/pause.
final class MediaAction: ActionHandler {
	let actionIDs = ["media"]

	private let nowPlaying = NowPlaying.shared
	private var progressTimer: Timer?
	private var lastDialCommand = Date.distantPast

	init() {
		nowPlaying.onChange = { [weak self] in self?.refreshAll() }
	}

	func willAppear(_ instance: Instance) {
		nowPlaying.start()
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
		// A fast spin produces several events; only skip one track at a time.
		guard ticks != 0, Date().timeIntervalSince(lastDialCommand) > 0.35 else { return }
		lastDialCommand = Date()
		nowPlaying.send(ticks > 0 ? "next" : "previous")
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
			Plugin.shared.setFeedback(instance, [
				"title": info.isEmpty ? "Media" : info.artist,
				"value": info.isEmpty ? "Not playing" : info.title,
				"indicator": Int((info.progress ?? 0) * 100),
			])
		}
		let command = instance.string("command", "playpause")
		if showsInfo(instance), !info.isEmpty {
			Plugin.shared.setImage(instance, Self.nowPlayingKey(info))
			return
		}
		let symbol: String
		switch command {
		case "next": symbol = "forward.fill"
		case "previous": symbol = "backward.fill"
		default:
			if nowPlaying.available { symbol = info.playing ? "pause.fill" : "play.fill" } else { symbol = "playpause.fill" }
		}
		Plugin.shared.setImage(instance, Render.iconKey(symbol: symbol))
	}

	static func nowPlayingKey(_ info: NowPlaying.Info) -> String {
		Render.dataURI { rect in
			Render.fillBackground(rect)
			if let artwork = info.artwork {
				// Aspect-fill the artwork.
				let scale = max(rect.width / artwork.size.width, rect.height / artwork.size.height)
				let size = CGSize(width: artwork.size.width * scale, height: artwork.size.height * scale)
				let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
				artwork.draw(in: target, from: .zero, operation: .sourceOver, fraction: info.playing ? 1 : 0.55, respectFlipped: true, hints: nil)
			} else {
				Render.drawSymbol("music.note", in: CGRect(x: 40, y: 18, width: 64, height: 56), color: Render.Palette.secondary)
			}

			// Darken the lower part so the title stays readable on any artwork.
			let gradient = NSGradient(colors: [NSColor(calibratedWhite: 0, alpha: 0), NSColor(calibratedWhite: 0, alpha: 0.85)])
			gradient?.draw(in: CGRect(x: 0, y: 64, width: rect.width, height: 80), angle: 90)

			Render.drawText(info.title, in: CGRect(x: 6, y: 86, width: 132, height: 44), size: 19, weight: .bold, maxLines: 2, minSize: 15)

			// Play-state glyph in the top-right corner.
			let badge = CGRect(x: 104, y: 6, width: 34, height: 34)
			NSColor(calibratedWhite: 0, alpha: 0.6).setFill()
			NSBezierPath(ovalIn: badge).fill()
			Render.drawSymbol(info.playing ? "pause.fill" : "play.fill", in: badge.insetBy(dx: 9, dy: 9), color: .white)

			if let progress = info.progress {
				Render.drawBar(CGRect(x: 0, y: 138, width: rect.width, height: 6), fraction: progress, color: .white)
			}
		}
	}
}
