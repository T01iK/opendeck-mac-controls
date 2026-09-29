import AppKit
import Foundation

/// Now-playing information and transport commands via the helper that runs inside /usr/bin/perl
/// (see Helpers/NowPlaying). Falls back to synthetic media keys when the helper is unavailable.
final class NowPlaying {
	static let shared = NowPlaying()

	struct Info {
		var title = ""
		var artist = ""
		var album = ""
		var appName = ""
		var playing = false
		var duration: Double = 0
		var elapsed: Double = 0
		var rate: Double = 0
		var timestamp = Date()
		var artwork: NSImage?

		var isEmpty: Bool { title.isEmpty && artist.isEmpty }

		/// Elapsed time extrapolated to now.
		var currentElapsed: Double {
			guard playing, rate > 0 else { return elapsed }
			return min(duration > 0 ? duration : .infinity, elapsed + Date().timeIntervalSince(timestamp) * rate)
		}

		var progress: Double? { duration > 0 ? currentElapsed / duration : nil }
	}

	private(set) var info = Info()
	private(set) var available = false
	var onChange: (() -> Void)?

	private var process: Process?
	private var input: FileHandle?
	private var buffer = Data()
	private var restarts = 0
	private var started = false

	private var helperDirectory: URL {
		URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
	}

	func start() {
		guard !started else { return }
		started = true
		launch()
	}

	/// Until this time, positions reported by MediaRemote are ignored: right after a seek it still reports the old one.
	private var seekHoldUntil = Date.distantPast

	/// Jumps to `position` seconds in the current item and shows it immediately.
	func seek(to position: Double) {
		guard available, let input, !info.isEmpty else { return }
		let clamped = max(0, info.duration > 0 ? min(position, info.duration - 1) : position)
		info.elapsed = clamped
		info.timestamp = Date()
		seekHoldUntil = Date().addingTimeInterval(1.5)
		input.write(Data("seek \(clamped)\n".utf8))
		onChange?()
	}

	func send(_ command: String) {
		if available, let input {
			input.write(Data((command + "\n").utf8))
			return
		}
		switch command {
		case "next": Input.post(.next)
		case "previous": Input.post(.previous)
		default: Input.post(.playPause)
		}
	}

	private func launch() {
		let script = helperDirectory.appendingPathComponent("nowplaying.pl")
		let library = helperDirectory.appendingPathComponent("libnowplaying.dylib")
		guard FileManager.default.fileExists(atPath: script.path), FileManager.default.fileExists(atPath: library.path) else {
			Log.error("Now playing helper missing next to the executable")
			return
		}
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
		process.arguments = [script.path, library.path]
		let stdout = Pipe()
		let stdin = Pipe()
		process.standardOutput = stdout
		process.standardInput = stdin
		process.standardError = FileHandle.nullDevice
		stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
			let data = handle.availableData
			DispatchQueue.main.async { self?.consume(data) }
		}
		process.terminationHandler = { [weak self] process in
			DispatchQueue.main.async { self?.helperExited(status: process.terminationStatus) }
		}
		do {
			try process.run()
			self.process = process
			self.input = stdin.fileHandleForWriting
			Log.info("Now playing helper started (pid \(process.processIdentifier))")
		} catch {
			Log.error("Failed to start now playing helper: \(error)")
		}
	}

	private var pendingEmpty: DispatchWorkItem?

	/// Applies new info. "Nothing playing" is delayed briefly because players report it transiently while switching.
	private func apply(_ next: Info) {
		pendingEmpty?.cancel()
		pendingEmpty = nil
		guard next.isEmpty, !info.isEmpty else {
			info = next
			onChange?()
			return
		}
		let work = DispatchWorkItem { [weak self] in
			self?.info = next
			self?.onChange?()
		}
		pendingEmpty = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
	}

	private func helperExited(status: Int32) {
		Log.error("Now playing helper exited with status \(status)")
		available = false
		process = nil
		input = nil
		buffer.removeAll()
		restarts += 1
		guard restarts <= 5 else { return }
		DispatchQueue.main.asyncAfter(deadline: .now() + Double(restarts) * 2) { [weak self] in self?.launch() }
	}

	private func consume(_ data: Data) {
		buffer.append(data)
		while let newline = buffer.firstIndex(of: 0x0A) {
			let line = buffer[buffer.startIndex..<newline]
			buffer.removeSubrange(buffer.startIndex...newline)
			guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
			handle(json)
		}
	}

	private func handle(_ json: [String: Any]) {
		switch json["type"] as? String {
		case "ready":
			available = true
			restarts = 0
		case "info":
			var next = Info()
			next.playing = json["playing"] as? Bool ?? false
			if json["empty"] as? Bool != true {
				next.title = json["title"] as? String ?? ""
				next.artist = json["artist"] as? String ?? ""
				next.album = json["album"] as? String ?? ""
				next.appName = json["appName"] as? String ?? ""
				next.duration = (json["duration"] as? NSNumber)?.doubleValue ?? 0
				next.elapsed = (json["elapsed"] as? NSNumber)?.doubleValue ?? 0
				next.rate = (json["rate"] as? NSNumber)?.doubleValue ?? (next.playing ? 1 : 0)
				if let ts = (json["timestamp"] as? NSNumber)?.doubleValue { next.timestamp = Date(timeIntervalSince1970: ts) }
				if Date() < seekHoldUntil, next.title == info.title {
					next.elapsed = info.elapsed
					next.timestamp = info.timestamp
				}
				let sameItem = next.title == info.title && next.artist == info.artist
				if let artwork = json["artwork"] as? String {
					next.artwork = Data(base64Encoded: artwork).flatMap(NSImage.init(data:))
				} else if json["hasArtwork"] as? Bool ?? true || sameItem {
					// Unchanged artwork, or the brief artwork-less update MediaRemote sends right after play/pause.
					next.artwork = info.artwork
				}
			}
			apply(next)
		case "error":
			Log.error("Now playing helper: \(json["message"] ?? "")")
		default:
			break
		}
	}
}
