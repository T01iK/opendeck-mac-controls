import Foundation

/// Minimal file logger: ~/Library/Logs/MacControls.log (truncated on each launch).
enum Log {
	private static let handle: FileHandle? = {
		let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacControls.log")
		FileManager.default.createFile(atPath: url.path, contents: nil)
		return try? FileHandle(forWritingTo: url)
	}()

	private static let formatter: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "HH:mm:ss.SSS"
		return f
	}()

	static func info(_ message: @autoclosure () -> String) {
		write("INFO", message())
	}

	static func error(_ message: @autoclosure () -> String) {
		write("ERROR", message())
	}

	private static func write(_ level: String, _ message: String) {
		let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
		handle?.write(line.data(using: .utf8)!)
	}
}
