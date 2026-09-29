import Darwin
import Foundation

/// Runs a command with plain posix_spawn, capturing output through temporary files.
///
/// `/usr/bin/shortcuts run` fails with "shortcut not found" when started through Foundation's `Process` from a
/// plugin running under OpenDeck, while an equivalent posix_spawn works — so tools that are sensitive to how they
/// are launched go through here.
enum Subprocess {
	struct Result {
		let status: Int32
		let output: String
		let error: String
	}

	/// Blocks until the command exits; call it off the main thread.
	static func run(_ executable: String, _ arguments: [String]) -> Result {
		let directory = FileManager.default.temporaryDirectory
		let outPath = directory.appendingPathComponent("macdeck-\(UUID().uuidString).out").path
		let errPath = directory.appendingPathComponent("macdeck-\(UUID().uuidString).err").path
		defer {
			unlink(outPath)
			unlink(errPath)
		}

		var actions: posix_spawn_file_actions_t?
		posix_spawn_file_actions_init(&actions)
		defer { posix_spawn_file_actions_destroy(&actions) }
		posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, outPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
		posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, errPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)

		let argv = ([executable] + arguments).map { strdup($0) } + [nil]
		defer { argv.forEach { free($0) } }

		var pid = pid_t(0)
		let spawned = posix_spawn(&pid, executable, &actions, nil, argv, environ)
		guard spawned == 0 else {
			return Result(status: -1, output: "", error: String(cString: strerror(spawned)))
		}
		var status: Int32 = 0
		while waitpid(pid, &status, 0) == -1, errno == EINTR {}

		let exitCode = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
		return Result(
			status: exitCode,
			output: (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? "",
			error: (try? String(contentsOfFile: errPath, encoding: .utf8)) ?? ""
		)
	}
}
