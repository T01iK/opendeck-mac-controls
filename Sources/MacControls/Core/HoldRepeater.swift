import Foundation

/// Runs an action once on key down and keeps repeating it while the key is held.
final class HoldRepeater {
	private var timers: [String: Timer] = [:]

	func start(_ instance: Instance, delay: TimeInterval = 0.4, interval: TimeInterval = 0.12, action: @escaping () -> Void) {
		stop(instance)
		action()
		let context = instance.context
		let initial = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
			guard let self else { return }
			let repeating = Timer(timeInterval: interval, repeats: true) { _ in action() }
			self.timers[context] = repeating
			RunLoop.main.add(repeating, forMode: .common)
		}
		timers[context] = initial
		RunLoop.main.add(initial, forMode: .common)
	}

	func stop(_ instance: Instance) {
		timers.removeValue(forKey: instance.context)?.invalidate()
	}
}
