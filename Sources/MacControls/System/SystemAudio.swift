import CoreAudio
import Foundation

/// Default output device (volume, mute, switching) and default input device (mute) via CoreAudio.
final class SystemAudio {
	static let shared = SystemAudio()

	struct Device {
		let id: AudioDeviceID
		let uid: String
		let name: String
		let transport: UInt32
	}

	/// Called on the main queue whenever devices, the output volume/mute or the input mute change.
	func addObserver(_ observer: @escaping () -> Void) {
		observers.append(observer)
		startObserving()
	}

	private var observers: [() -> Void] = []
	private func notify() { observers.forEach { $0() } }

	// 'vmvc' — kAudioHardwareServiceDeviceProperty_VirtualMainVolume (AudioToolbox). Handles balance and multi-channel devices.
	private let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663
	private var deviceListeners: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
	/// Input volume saved when muting a microphone that has no mute control, keyed by device UID.
	private var savedInputVolume: [String: Float] = [:]
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

	// MARK: Devices

	/// All devices with output channels, in system order.
	var outputDevices: [Device] {
		var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
		var size = UInt32(0)
		guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
		var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
		guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
		return ids.filter { channelCount($0, scope: kAudioDevicePropertyScopeOutput) > 0 }.compactMap { id in
			guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID), let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
			var transport = UInt32(0)
			var transportSize = UInt32(MemoryLayout<UInt32>.size)
			var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
			AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
			return Device(id: id, uid: uid, name: name, transport: transport)
		}
	}

	var outputDeviceUID: String? { stringProperty(device, kAudioDevicePropertyDeviceUID) }

	/// Makes the device the default output (and the output for system sounds, like the Sound menu does).
	@discardableResult
	func setOutputDevice(uid: String) -> Bool {
		guard let target = outputDevices.first(where: { $0.uid == uid }) else { return false }
		var id = target.id
		let size = UInt32(MemoryLayout<AudioDeviceID>.size)
		var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
		let ok = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id) == noErr
		address.mSelector = kAudioHardwarePropertyDefaultSystemOutputDevice
		AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id)
		return ok
	}

	// MARK: Microphone

	var inputDevice: AudioDeviceID {
		var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
		var id = AudioDeviceID(0)
		var size = UInt32(MemoryLayout<AudioDeviceID>.size)
		AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
		return id
	}

	/// nil when there is no input device or it can be neither muted nor turned down.
	var isInputMuted: Bool? {
		let device = inputDevice
		guard device != 0 else { return nil }
		var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
		if AudioObjectHasProperty(device, &address) {
			var value = UInt32(0)
			var size = UInt32(MemoryLayout<UInt32>.size)
			if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { return value != 0 }
		}
		return inputVolume(device).map { $0 == 0 }
	}

	/// Uses the device's mute control, or sets the input volume to 0 (and restores it) when there is none.
	@discardableResult
	func setInputMuted(_ muted: Bool) -> Bool {
		let device = inputDevice
		guard device != 0 else { return false }
		var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
		var settable: DarwinBoolean = false
		if AudioObjectHasProperty(device, &address), AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue {
			var value = UInt32(muted ? 1 : 0)
			return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
		}
		let uid = stringProperty(device, kAudioDevicePropertyDeviceUID) ?? ""
		if muted, let current = inputVolume(device), current > 0 { savedInputVolume[uid] = current }
		let target = muted ? 0 : (savedInputVolume[uid] ?? 0.75)
		return inputVolumeAddresses.map { setFloat(device, $0, target) }.contains(true)
	}

	private var inputVolumeAddresses: [AudioObjectPropertyAddress] {
		[kAudioObjectPropertyElementMain, 1, 2].map {
			AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput, mElement: $0)
		}
	}

	private func inputVolume(_ device: AudioDeviceID) -> Float? {
		inputVolumeAddresses.lazy.compactMap { self.getFloat(device, $0) }.first
	}

	private func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
		var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
		var size = UInt32(0)
		guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
		let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
		defer { buffer.deallocate() }
		guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else { return 0 }
		let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
		return list.reduce(0) { $0 + Int($1.mNumberChannels) }
	}

	private func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
		var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
		var value: Unmanaged<CFString>?
		var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
		guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
		return value?.takeRetainedValue() as String?
	}

	// MARK: Change notifications

	private func startObserving() {
		guard !started else { return }
		started = true
		for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
			var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
			AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
				self?.attachDeviceListeners()
				self?.notify()
			}
		}
		attachDeviceListeners()
	}

	private func attachDeviceListeners() {
		for (device, address, block) in deviceListeners {
			var address = address
			AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
		}
		deviceListeners.removeAll()
		let output = device
		let outputAddresses = [
			AudioObjectPropertyAddress(mSelector: virtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain),
			muteAddress,
		] + [0, 1, 2].map { scalarAddress(element: $0) }
		let input = inputDevice
		let inputAddresses = [0, 1].flatMap { element in
			[kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar].map {
				AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioDevicePropertyScopeInput, mElement: element)
			}
		}
		for (device, addresses) in [(output, outputAddresses), (input, inputAddresses)] {
			for var address in addresses where AudioObjectHasProperty(device, &address) {
				let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.notify() }
				if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
					deviceListeners.append((device, address, block))
				}
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
