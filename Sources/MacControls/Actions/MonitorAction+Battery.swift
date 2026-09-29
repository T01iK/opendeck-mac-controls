import AppKit

/// Battery metric: the Mac's own battery or a Bluetooth accessory (see System/BluetoothBatteries.swift).
extension MonitorAction {
	/// Percentage, a battery drawing filled to the charge level and the charging state / time remaining.
	/// Colours follow macOS: green while charging, yellow in Low Power Mode, red at 20% or below.
	func batteryKey() -> String {
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
	func bluetoothBatteryKey(address: String, fallbackName: String) -> String {
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
}
