import CoreAudio
import Foundation

/// Volume and mute of the default output device via CoreAudio.
final class SystemAudio {
	static let shared = SystemAudio()

	/// Called on the main queue whenever the device, its volume or its mute state changes.
	var onChange: (() -> Void)?

	// 'vmvc' — kAudioHardwareServiceDeviceProperty_VirtualMainVolume (AudioToolbox). Handles balance and multi-channel devices.
	private let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663
	private var observedDevice = AudioDeviceID(0)
	private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
	private var started = false

	// MARK: Queries

	var device: AudioDeviceID {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
		)
		var id = AudioDeviceID(0)
		var size = UInt32(MemoryLayout<AudioDeviceID>.size)
		AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
		return id
	}

	var deviceName: String? {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
		)
		var name: Unmanaged<CFString>?
		var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
		guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
		return name?.takeRetainedValue() as String?
	}

	/// 0...1, or nil when the device has no software volume (e.g. HDMI / DisplayPort audio).
	var volume: Float? {
		let device = device
		for address in volumeAddresses(device) {
			if let value = getFloat(device, address) { return value }
		}
		// Fall back to averaging the stereo channels.
		let values = stereoChannels(device).compactMap { getFloat(device, scalarAddress(element: $0)) }
		return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
	}

	var isMuted: Bool? {
		var address = muteAddress
		guard AudioObjectHasProperty(device, &address) else { return nil }
		var value = UInt32(0)
		var size = UInt32(MemoryLayout<UInt32>.size)
		guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
		return value != 0
	}

	// MARK: Mutations

	@discardableResult
	func setVolume(_ value: Float) -> Bool {
		let device = device
		let clamped = max(0, min(1, value))
		for address in volumeAddresses(device) where setFloat(device, address, clamped) {
			return true
		}
		let results = stereoChannels(device).map { setFloat(device, scalarAddress(element: $0), clamped) }
		return results.contains(true)
	}

	@discardableResult
	func setMuted(_ muted: Bool) -> Bool {
		var address = muteAddress
		let device = device
		var settable: DarwinBoolean = false
		guard AudioObjectHasProperty(device, &address),
		      AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue
		else { return false }
		var value = UInt32(muted ? 1 : 0)
		return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
	}

	// MARK: Change notifications

	func startObserving() {
		guard !started else { return }
		started = true
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
		)
		AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
			self?.attachDeviceListeners()
			self?.onChange?()
		}
		attachDeviceListeners()
	}

	private func attachDeviceListeners() {
		for (address, block) in deviceListeners {
			var address = address
			AudioObjectRemovePropertyListenerBlock(observedDevice, &address, .main, block)
		}
		deviceListeners.removeAll()
		observedDevice = device
		let addresses = [
			AudioObjectPropertyAddress(mSelector: virtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain),
			muteAddress,
		] + [0, 1, 2].map { scalarAddress(element: $0) }
		for var address in addresses where AudioObjectHasProperty(observedDevice, &address) {
			let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
			if AudioObjectAddPropertyListenerBlock(observedDevice, &address, .main, block) == noErr {
				deviceListeners.append((address, block))
			}
		}
	}

	// MARK: Helpers

	private var muteAddress: AudioObjectPropertyAddress {
		AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
	}

	private func scalarAddress(element: UInt32) -> AudioObjectPropertyAddress {
		AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
	}

	private func volumeAddresses(_ device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
		[
			AudioObjectPropertyAddress(mSelector: virtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain),
			scalarAddress(element: kAudioObjectPropertyElementMain),
		]
	}

	private func stereoChannels(_ device: AudioDeviceID) -> [UInt32] {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyPreferredChannelsForStereo, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain
		)
		var channels: [UInt32] = [1, 2]
		var size = UInt32(MemoryLayout<UInt32>.size * 2)
		AudioObjectGetPropertyData(device, &address, 0, nil, &size, &channels)
		return channels
	}

	private func getFloat(_ device: AudioDeviceID, _ address: AudioObjectPropertyAddress) -> Float? {
		var address = address
		guard AudioObjectHasProperty(device, &address) else { return nil }
		var value = Float32(0)
		var size = UInt32(MemoryLayout<Float32>.size)
		guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
		return value
	}

	private func setFloat(_ device: AudioDeviceID, _ address: AudioObjectPropertyAddress, _ value: Float) -> Bool {
		var address = address
		var settable: DarwinBoolean = false
		guard AudioObjectHasProperty(device, &address),
		      AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue
		else { return false }
		var value = Float32(value)
		return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
	}
}
