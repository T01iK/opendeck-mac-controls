import AppKit

/// Opens (or focuses) an application. The key shows the app's icon and, optionally, its name and a running dot.
///
/// Settings: `path` (the .app), `bundleId` (used to find the app if it moves), `showName` (bool, default false),
/// `showRunning` (bool, default true), `whenFrontmost` ("nothing" | "hide", default "hide").
final class AppAction: ActionHandler {
	let actionIDs = ["openapp"]

	private var observers: [NSObjectProtocol] = []
	private var iconCache: [String: NSImage] = [:]

	init() {
		let center = NSWorkspace.shared.notificationCenter
		for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
			observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshAll() })
		}
	}

	func willAppear(_ instance: Instance) { render(instance) }

	func keyDown(_ instance: Instance) {
		guard let url = appURL(instance) else { return Plugin.shared.showAlert(instance) }
		if let running = runningApp(url, instance), running.isActive, instance.string("whenFrontmost", "hide") == "hide" {
			running.hide()
			return
		}
		let configuration = NSWorkspace.OpenConfiguration()
		configuration.activates = true
		NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
			guard let error else { return }
			Log.error("Failed to open \(url.path): \(error.localizedDescription)")
			DispatchQueue.main.async { Plugin.shared.showAlert(instance) }
		}
	}

	func messageFromInspector(_ instance: Instance, payload: [String: Any]) {
		guard payload["request"] as? String == "listApps" else { return }
		DispatchQueue.global(qos: .userInitiated).async {
			let apps = Self.installedApps().map { ["name": $0.name, "path": $0.path, "bundleId": $0.bundleId] }
			DispatchQueue.main.async { Plugin.shared.sendToInspector(instance, ["apps": apps]) }
		}
	}

	// MARK: Helpers

	private func refreshAll() {
		Plugin.shared.instances(of: self).forEach(render)
	}

	/// The configured app, falling back to its bundle identifier if it was moved or renamed.
	private func appURL(_ instance: Instance) -> URL? {
		let path = instance.string("path", "")
		// Resolve links such as /Applications/Safari.app → the Cryptex copy, otherwise the icon gets an alias badge.
		if !path.isEmpty, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path).resolvingSymlinksInPath() }
		let bundleId = instance.string("bundleId", "")
		return bundleId.isEmpty ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.resolvingSymlinksInPath()
	}

	private func runningApp(_ url: URL, _ instance: Instance) -> NSRunningApplication? {
		let bundleId = Bundle(url: url)?.bundleIdentifier ?? instance.string("bundleId", "")
		if bundleId.isEmpty {
			return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
		}
		let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
		return candidates.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL } ?? candidates.first
	}

	private func icon(for url: URL) -> NSImage {
		if let cached = iconCache[url.path] { return cached }
		let icon = NSWorkspace.shared.icon(forFile: url.path)
		iconCache[url.path] = icon
		return icon
	}

	private func render(_ instance: Instance) {
		guard let url = appURL(instance) else {
			Plugin.shared.setImage(instance, Render.iconKey(symbol: "questionmark.app.dashed", label: "Choose app", color: Render.Palette.secondary))
			return
		}
		let icon = icon(for: url)
		let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
		let showName = instance.bool("showName", false)
		let running = instance.bool("showRunning", true) && runningApp(url, instance) != nil

		Plugin.shared.setImage(instance, Render.dataURI { rect in
			Render.fillBackground(rect)
			let iconRect = showName ? CGRect(x: 26, y: 8, width: 92, height: 92) : CGRect(x: 14, y: 10, width: 116, height: 116)
			icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
			if showName {
				Render.drawText(name, in: CGRect(x: 6, y: 102, width: 132, height: 30), size: 20)
			}
			if running {
				NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
				NSBezierPath(ovalIn: CGRect(x: 67, y: showName ? 133 : 130, width: 10, height: 10)).fill()
			}
		})
	}

	/// Apps in the standard locations (one folder level deep, e.g. /Applications/Utilities), deduplicated by bundle id.
	static func installedApps() -> [(name: String, path: String, bundleId: String)] {
		let fm = FileManager.default
		let roots = ["/Applications", "/System/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
		var seen = Set<String>()
		var apps: [(name: String, path: String, bundleId: String)] = []

		func add(_ path: String) {
			let bundleId = Bundle(path: path)?.bundleIdentifier ?? path
			guard seen.insert(bundleId).inserted else { return }
			apps.append((fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""), path, bundleId))
		}

		for root in roots {
			for entry in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !entry.hasPrefix(".") {
				let path = (root as NSString).appendingPathComponent(entry)
				if entry.hasSuffix(".app") {
					add(path)
				} else {
					for child in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where child.hasSuffix(".app") {
						add((path as NSString).appendingPathComponent(child))
					}
				}
			}
		}
		return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
	}
}
