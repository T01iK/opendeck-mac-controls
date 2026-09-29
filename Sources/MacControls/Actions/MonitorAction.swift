import AppKit

/// Live hardware stats on a key with a history graph.
///
/// Settings: `metric` (see `Metric`), `graph` (bool, default true), `press` ("activity" | "none").
/// "activity" opens Activity Monitor, or Battery / Bluetooth settings for the battery metric.
/// `batterySource` ("mac" or a Bluetooth device address, default "mac") picks which battery the battery metric shows.
final class MonitorAction: ActionHandler {
	let actionIDs = ["monitor"]

	enum Metric: String, CaseIterable {
		case cpu, memory, gpu, cpuTemp, ssdTemp, batteryTemp, network, networkIn, networkOut, disk, diskRead, diskWrite, battery
	}

	private let stats = SystemStats()
	private let capacity = 30
	private var history: [String: [Double]] = [:]
	private var timer: Timer?

	func willAppear(_ instance: Instance) {
		render(instance)
		if timer == nil {
			// Prime the delta-based samplers so the first tick already has rates.
			sample()
			timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
			timer?.tolerance = 0.1
		}
	}

	func willDisappear(_ instance: Instance) {
		DispatchQueue.main.async { [weak self] in
			guard let self, Plugin.shared.instances(of: self).isEmpty else { return }
			self.timer?.invalidate()
			self.timer = nil
			self.history.removeAll()
		}
	}

	func keyDown(_ instance: Instance) {
		guard instance.string("press", "activity") == "activity" else { return }
		if metric(instance) == .battery {
			let pane = instance.string("batterySource", "mac") == "mac" ? "com.apple.Battery-Settings.extension" : "com.apple.BluetoothSettings"
			NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:" + pane)!)
			return
		}
		NSWorkspace.shared.openApplication(
			at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
			configuration: NSWorkspace.OpenConfiguration()
		)
	}

	func messageFromInspector(_ instance: Instance, payload: [String: Any]) {
		guard payload["request"] as? String == "listBatteries" else { return }
		BluetoothBatteries.shared.refresh(maxAge: 0) {
			// Accessories first; computers, phones and speakers report no battery this way.
			let devices = BluetoothBatteries.shared.devices.sorted { ($0.kind == "other" ? 1 : 0, $0.name) < ($1.kind == "other" ? 1 : 0, $1.name) }
			Plugin.shared.sendToInspector(instance, ["batteries": devices.map { ["address": $0.address, "name": $0.name] }])
		}
	}

	// MARK: Sampling

	private func metric(_ instance: Instance) -> Metric {
		Metric(rawValue: instance.string("metric", "cpu")) ?? .cpu
	}

	private func tick() {
		sample()
		Plugin.shared.instances(of: self).forEach(render)
	}

	private func sample() {
		let metrics = Set(Plugin.shared.instances(of: self).map(metric))
		let has = { (list: [Metric]) in !metrics.isDisjoint(with: list) }
		let snapshot = stats.sample(
			cpu: has([.cpu]), memory: has([.memory]), gpu: has([.gpu]),
			temperatures: has([.cpuTemp, .ssdTemp, .batteryTemp]),
			network: has([.network, .networkIn, .networkOut]), disk: has([.disk, .diskRead, .diskWrite]),
			battery: has([.battery])
		)
		battery = snapshot.battery
		if Plugin.shared.instances(of: self).contains(where: { metric($0) == .battery && $0.string("batterySource", "mac") != "mac" }) {
			BluetoothBatteries.shared.refresh { [weak self] in
				guard let self else { return }
				Plugin.shared.instances(of: self).forEach(self.render)
			}
		}
		record("cpu", snapshot.cpu)
		record("memory", snapshot.memoryUsed.map { $0 / snapshot.memoryTotal * 100 })
		record("gpu", snapshot.gpu)
		record("cpuTemp", snapshot.cpuTemperature)
		record("ssdTemp", snapshot.ssdTemperature)
		record("batteryTemp", snapshot.batteryTemperature)
		record("networkIn", snapshot.networkIn)
		record("networkOut", snapshot.networkOut)
		record("diskRead", snapshot.diskRead)
		record("diskWrite", snapshot.diskWrite)
		if let used = snapshot.memoryUsed { memoryUsedBytes = used }
	}

	private var memoryUsedBytes: Double?
	private var battery: SystemStats.Battery?

	private func record(_ key: String, _ value: Double?) {
		guard let value else { return }
		var values = history[key] ?? []
		values.append(value)
		if values.count > capacity { values.removeFirst(values.count - capacity) }
		history[key] = values
	}

	// MARK: Rendering

	private func render(_ instance: Instance) {
		let metric = metric(instance)
		let graph = instance.bool("graph", true)
		let image: String
		switch metric {
		case .cpu: image = percentKey("CPU", "cpu", graph: graph)
		case .gpu: image = percentKey("GPU", "gpu", graph: graph)
		case .memory: image = memoryKey(graph: graph)
		case .cpuTemp: image = temperatureKey("CPU °C", "cpuTemp", graph: graph)
		case .ssdTemp: image = temperatureKey("SSD °C", "ssdTemp", graph: graph)
		case .batteryTemp: image = temperatureKey("BATT °C", "batteryTemp", graph: graph)
		case .networkIn: image = rateKey("NET ↓", "networkIn", color: Render.Palette.teal, graph: graph)
		case .networkOut: image = rateKey("NET ↑", "networkOut", color: Render.Palette.orange, graph: graph)
		case .diskRead: image = rateKey("DISK R", "diskRead", color: Render.Palette.teal, graph: graph)
		case .diskWrite: image = rateKey("DISK W", "diskWrite", color: Render.Palette.orange, graph: graph)
		case .network: image = dualRateKey("NETWORK", ("↓", "networkIn"), ("↑", "networkOut"), graph: graph)
		case .disk: image = dualRateKey("DISK", ("R", "diskRead"), ("W", "diskWrite"), graph: graph)
		case .battery:
			let source = instance.string("batterySource", "mac")
			image = source == "mac" ? batteryKey() : bluetoothBatteryKey(address: source, fallbackName: instance.string("batteryName", "Device"))
		}
		Plugin.shared.setImage(instance, image)
	}

	private func levelColor(_ value: Double, warn: Double, critical: Double) -> NSColor {
		value >= critical ? Render.Palette.red : value >= warn ? Render.Palette.orange : Render.Palette.green
	}

	private func percentKey(_ label: String, _ key: String, graph: Bool) -> String {
		let values = history[key] ?? []
		let current = values.last
		let color = levelColor(current ?? 0, warn: 60, critical: 85)
		return statKey(label: label, value: current.map { "\(Int($0.rounded()))%" } ?? "–", color: color, graph: graph) { rect in
			Render.drawSparkline(values, maximum: 100, in: rect, color: color, capacity: capacity)
		}
	}

	private func memoryKey(graph: Bool) -> String {
		let values = history["memory"] ?? []
		let color = levelColor(values.last ?? 0, warn: 75, critical: 90)
		let value = memoryUsedBytes.map { String(format: "%.1f GB", $0 / 1_073_741_824) } ?? "–"
		let label = values.last.map { "RAM \(Int($0.rounded()))%" } ?? "RAM"
		return statKey(label: label, value: value, color: color, graph: graph) { rect in
			Render.drawSparkline(values, maximum: 100, in: rect, color: color, capacity: capacity)
		}
	}

	private func temperatureKey(_ label: String, _ key: String, graph: Bool) -> String {
		let values = history[key] ?? []
		let current = values.last
		let color = levelColor(current ?? 0, warn: 70, critical: 90)
		// Graph the 20–110 °C range so normal fluctuations are visible.
		return statKey(label: label, value: current.map { "\(Int($0.rounded()))°" } ?? "–", color: color, graph: graph) { rect in
			Render.drawSparkline(values.map { $0 - 20 }, maximum: 90, in: rect, color: color, capacity: capacity)
		}
	}

	private func rateKey(_ label: String, _ key: String, color: NSColor, graph: Bool) -> String {
		let values = history[key] ?? []
		let (number, unit) = values.last.map(Self.splitRate) ?? ("–", "")
		return statKey(label: label, value: number, unit: unit, color: color, graph: graph) { rect in
			Render.drawSparkline(values, maximum: Self.scale(values), in: rect, color: color, capacity: capacity)
		}
	}

	private func dualRateKey(_ label: String, _ first: (String, String), _ second: (String, String), graph: Bool) -> String {
		let a = history[first.1] ?? []
		let b = history[second.1] ?? []
		let maximum = Self.scale(a + b)
		return Render.dataURI { rect in
			Render.fillBackground(rect)
			let lines = [(first.0, a.last, Render.Palette.teal), (second.0, b.last, Render.Palette.orange)]
			if graph {
				Render.drawText(label, in: CGRect(x: 10, y: 6, width: 124, height: 24), size: 18, weight: .bold, color: Render.Palette.secondary, alignment: .left)
			} else {
				Render.drawText(label, in: CGRect(x: 8, y: 12, width: 128, height: 26), size: 20, weight: .bold, color: Render.Palette.secondary)
			}
			// Without a graph the two values get the whole lower part of the key.
			let top: CGFloat = graph ? 32 : 42
			let lineHeight: CGFloat = graph ? 30 : 46
			let valueSize: CGFloat = graph ? 26 : 38
			for (index, line) in lines.enumerated() {
				let y = top + CGFloat(index) * lineHeight
				Render.drawText(line.0, in: CGRect(x: 6, y: y, width: 26, height: lineHeight), size: graph ? 22 : 28, weight: .bold, color: line.2, alignment: .left)
				let (number, unit) = line.1.map(Self.splitRate) ?? ("–", "")
				Render.drawValue(number, unit: unit, in: CGRect(x: 30, y: y, width: 108, height: lineHeight), size: valueSize, alignment: .right)
			}
			if graph {
				let area = CGRect(x: 6, y: 96, width: 132, height: 42)
				Render.drawSparkline(a, maximum: maximum, in: area, color: Render.Palette.teal, capacity: capacity)
				Render.drawSparkline(b, maximum: maximum, in: area, color: Render.Palette.orange, capacity: capacity, fill: false)
			}
		}
	}

	/// Percentage, a battery drawing filled to the charge level and the charging state / time remaining.
	/// Colours follow macOS: green while charging, yellow in Low Power Mode, red at 20% or below.
	private func batteryKey() -> String {
		guard let battery else {
			return Render.iconKey(symbol: "battery.0percent", label: "No battery", color: Render.Palette.secondary)
		}
		let color: NSColor
		if battery.lowPowerMode {
			color = Render.Palette.yellow
		} else if battery.charging || battery.charged {
			color = Render.Palette.green
		} else if battery.percent <= 20 {
			color = Render.Palette.red
		} else {
			color = Render.Palette.text
		}

		let status: String
		if battery.charged {
			status = "Charged"
		} else if battery.charging {
			status = battery.minutesToFull.map { "Full in " + Self.formatMinutes($0) } ?? "Charging"
		} else if battery.onAC {
			status = "On AC"
		} else {
			status = battery.minutesToEmpty.map { Self.formatMinutes($0) + " left" } ?? "Estimating…"
		}

		return Render.dataURI { rect in
			Render.fillBackground(rect)
			Render.drawText("BATTERY", in: CGRect(x: 10, y: 6, width: 124, height: 24), size: 18, weight: .bold, color: Render.Palette.secondary, alignment: .left)
			Render.drawValue("\(Int(battery.percent.rounded()))", unit: "%", in: CGRect(x: 6, y: 30, width: 132, height: 48), size: 42)

			Self.drawBatteryGauge(
				CGRect(x: 26, y: 84, width: 84, height: 30), percent: battery.percent, color: color,
				badge: battery.charging ? "bolt.fill" : battery.onAC ? "powerplug.fill" : nil
			)

			Render.drawText(status, in: CGRect(x: 6, y: 118, width: 132, height: 22), size: 17, color: Render.Palette.secondary)
		}
	}

	/// A Bluetooth accessory: single battery as a gauge, or Left / Right / Case rows for earbuds.
	private func bluetoothBatteryKey(address: String, fallbackName: String) -> String {
		let device = BluetoothBatteries.shared.device(address: address)
		let levelColor = { (percent: Int) -> NSColor in percent <= 20 ? Render.Palette.red : Render.Palette.text }
		return Render.dataURI { rect in
			Render.fillBackground(rect)
			Render.drawSymbol(device?.symbol ?? "dot.radiowaves.left.and.right", in: CGRect(x: 8, y: 7, width: 22, height: 20), color: Render.Palette.secondary)
			Render.drawText(device.map(BluetoothBatteries.shared.displayName) ?? fallbackName, in: CGRect(x: 34, y: 6, width: 104, height: 22),
			                size: 16, weight: .bold, color: Render.Palette.secondary, alignment: .left, minSize: 12)

			guard let device, device.connected, device.single != nil || device.isMultiBattery else {
				Render.drawSymbol(device?.symbol ?? "questionmark", in: CGRect(x: 36, y: 38, width: 72, height: 56), color: Render.Palette.secondary.withAlphaComponent(0.5))
				Render.drawText(device == nil ? "Not found" : "Not connected", in: CGRect(x: 6, y: 110, width: 132, height: 24), size: 17, color: Render.Palette.secondary)
				return
			}

			if device.isMultiBattery {
				let rows = [("L", device.left), ("R", device.right), ("Case", device.batteryCase)].compactMap { label, value in value.map { (label, $0) } }
				for (index, row) in rows.enumerated() {
					let y = 38 + CGFloat(index) * 34
					Render.drawText(row.0, in: CGRect(x: 8, y: y, width: 46, height: 26), size: 15, weight: .bold, color: Render.Palette.secondary, alignment: .left)
					Render.drawBar(CGRect(x: 56, y: y + 9, width: 36, height: 9), fraction: Double(row.1) / 100, color: levelColor(row.1))
					Render.drawValue("\(row.1)", unit: "%", in: CGRect(x: 94, y: y, width: 46, height: 26), size: 20, alignment: .right)
				}
				return
			}

			let percent = device.single ?? 0
			Render.drawValue("\(percent)", unit: "%", in: CGRect(x: 6, y: 30, width: 132, height: 48), size: 42)
			Self.drawBatteryGauge(CGRect(x: 26, y: 84, width: 84, height: 30), percent: Double(percent), color: levelColor(percent), badge: nil)
			Render.drawText("Connected", in: CGRect(x: 6, y: 118, width: 132, height: 22), size: 17, color: Render.Palette.secondary)
		}
	}

	/// Battery outline with terminal nub, filled to `percent`, with an optional badge (bolt / plug) on top.
	static func drawBatteryGauge(_ body: CGRect, percent: Double, color: NSColor, badge: String?) {
		let outline = NSBezierPath(roundedRect: body, xRadius: 7, yRadius: 7)
		outline.lineWidth = 3
		Render.Palette.secondary.setStroke()
		outline.stroke()
		Render.Palette.secondary.setFill()
		NSBezierPath(roundedRect: CGRect(x: body.maxX + 3, y: body.midY - 6, width: 5, height: 12), xRadius: 2, yRadius: 2).fill()
		var fill = body.insetBy(dx: 5, dy: 5)
		fill.size.width = max(3, fill.width * CGFloat(min(100, percent)) / 100)
		color.setFill()
		NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
		if let badge {
			Render.drawSymbol(badge, in: body.insetBy(dx: 30, dy: 4), color: .white, weight: .heavy)
		}
	}

	static func formatMinutes(_ minutes: Int) -> String {
		minutes >= 60 ? "\(minutes / 60):" + String(format: "%02d", minutes % 60) : "\(minutes) min"
	}

	/// Label, big value and an optional graph in the lower third.
	private func statKey(label: String, value: String, unit: String = "", color: NSColor, graph: Bool, drawGraph: (CGRect) -> Void) -> String {
		Render.dataURI { rect in
			Render.fillBackground(rect)
			if graph {
				Render.drawText(label, in: CGRect(x: 10, y: 6, width: 124, height: 24), size: 18, weight: .bold, color: Render.Palette.secondary, alignment: .left)
				Render.drawValue(value, unit: unit, in: CGRect(x: 6, y: 32, width: 132, height: 52), size: 44)
				drawGraph(CGRect(x: 6, y: 92, width: 132, height: 46))
			} else {
				Render.drawText(label, in: CGRect(x: 8, y: 22, width: 128, height: 30), size: 22, weight: .bold, color: Render.Palette.secondary)
				Render.drawValue(value, unit: unit, in: CGRect(x: 6, y: 58, width: 132, height: 60), size: 48, color: color)
			}
		}
	}

	/// Graph ceiling for byte rates: the recent peak with headroom, at least 100 KB/s so idle noise stays flat.
	private static func scale(_ values: [Double]) -> Double {
		max(100_000, (values.max() ?? 0) * 1.15)
	}

	static func splitRate(_ bytesPerSecond: Double) -> (String, String) {
		let parts = formatRate(bytesPerSecond).split(separator: " ", maxSplits: 1).map(String.init)
		return (parts[0], parts.count > 1 ? parts[1] : "")
	}

	static func formatRate(_ bytesPerSecond: Double) -> String {
		let units = ["B/s", "KB/s", "MB/s", "GB/s"]
		var value = bytesPerSecond
		var unit = 0
		while value >= 1000, unit < units.count - 1 {
			value /= 1000
			unit += 1
		}
		let number = unit == 0 || value >= 100 ? String(Int(value.rounded())) : String(format: value >= 10 ? "%.0f" : "%.1f", value)
		return "\(number) \(units[unit])"
	}
}
