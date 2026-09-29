import Darwin
import Foundation
import IOKit
import SystemConfiguration

/// Samplers for CPU, memory, GPU, temperatures, network and disk throughput.
/// Rates are computed from the difference between two consecutive `sample()` calls.
final class SystemStats {
	struct Snapshot {
		var cpu: Double? // %
		var memoryUsed: Double? // bytes
		var memoryTotal: Double
		var gpu: Double? // %
		var cpuTemperature: Double? // °C
		var ssdTemperature: Double? // °C
		var batteryTemperature: Double? // °C
		var networkIn: Double? // bytes/s
		var networkOut: Double? // bytes/s
		var diskRead: Double? // bytes/s
		var diskWrite: Double? // bytes/s
	}

	private var previousTicks: [UInt64]?
	private var previousNetwork: (bytesIn: UInt64, bytesOut: UInt64, time: TimeInterval)?
	private var previousDisk: (read: UInt64, write: UInt64, time: TimeInterval)?
	private let temperatures = TemperatureSensors()
	let memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)

	/// Only computes what is requested to keep idle cost low.
	func sample(cpu: Bool, memory: Bool, gpu: Bool, temperatures wantTemps: Bool, network: Bool, disk: Bool) -> Snapshot {
		var snapshot = Snapshot(memoryTotal: memoryTotal)
		if cpu { snapshot.cpu = cpuUsage() }
		if memory { snapshot.memoryUsed = memoryUsed() }
		if gpu { snapshot.gpu = gpuUsage() }
		if wantTemps {
			let readings = temperatures.read()
			let dies = readings.filter { $0.key.contains("tdie") }.map(\.value)
			let pmu = readings.filter { $0.key.hasPrefix("PMU") }.map(\.value)
			if !dies.isEmpty {
				snapshot.cpuTemperature = dies.reduce(0, +) / Double(dies.count)
			} else if !pmu.isEmpty {
				snapshot.cpuTemperature = pmu.max()
			}
			snapshot.ssdTemperature = readings.first { $0.key.hasPrefix("NAND") }?.value
			snapshot.batteryTemperature = readings.first { $0.key.lowercased().contains("battery") }?.value
		}
		if network { (snapshot.networkIn, snapshot.networkOut) = networkRates() }
		if disk { (snapshot.diskRead, snapshot.diskWrite) = diskRates() }
		return snapshot
	}

	// MARK: CPU

	private func cpuUsage() -> Double? {
		var cpuCount = natural_t(0)
		var info: processor_info_array_t?
		var infoCount = mach_msg_type_number_t(0)
		guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS, let info else {
			return nil
		}
		defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
		// [user, system, idle, nice] summed across cores.
		var ticks = [UInt64](repeating: 0, count: 4)
		for cpu in 0..<Int(cpuCount) {
			for state in 0..<Int(CPU_STATE_MAX) {
				ticks[state] += UInt64(UInt32(bitPattern: info[cpu * Int(CPU_STATE_MAX) + state]))
			}
		}
		defer { previousTicks = ticks }
		guard let previous = previousTicks else { return nil }
		let delta = zip(ticks, previous).map { $0 &- $1 }
		let total = delta.reduce(0, +)
		guard total > 0 else { return nil }
		let busy = delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_SYSTEM)] + delta[Int(CPU_STATE_NICE)]
		return Double(busy) / Double(total) * 100
	}

	// MARK: Memory

	/// Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
	private func memoryUsed() -> Double? {
		var stats = vm_statistics64()
		var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
		let result = withUnsafeMutablePointer(to: &stats) {
			$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
		}
		guard result == KERN_SUCCESS else { return nil }
		let pageSize = Double(vm_kernel_page_size)
		let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
		return (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * pageSize
	}

	// MARK: GPU

	private func gpuUsage() -> Double? {
		var iterator = io_iterator_t(0)
		guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
		defer { IOObjectRelease(iterator) }
		var best: Double?
		while case let service = IOIteratorNext(iterator), service != 0 {
			defer { IOObjectRelease(service) }
			guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
				.takeRetainedValue() as? [String: Any],
				let utilisation = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
			else { continue }
			best = max(best ?? 0, utilisation)
		}
		return best
	}

	// MARK: Network

	/// Uses the primary interface so VPN tunnels are not double counted.
	private func networkRates() -> (Double?, Double?) {
		let now = ProcessInfo.processInfo.systemUptime
		guard let counters = interfaceCounters(primaryInterface()) else { return (nil, nil) }
		defer { previousNetwork = (counters.0, counters.1, now) }
		guard let previous = previousNetwork, now > previous.time, counters.0 >= previous.bytesIn, counters.1 >= previous.bytesOut else {
			return (nil, nil)
		}
		let elapsed = now - previous.time
		return (Double(counters.0 - previous.bytesIn) / elapsed, Double(counters.1 - previous.bytesOut) / elapsed)
	}

	private func primaryInterface() -> String? {
		guard let store = SCDynamicStoreCreate(nil, "MacControls" as CFString, nil, nil),
		      let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
		else { return nil }
		return value["PrimaryInterface"] as? String
	}

	/// 64-bit byte counters from the routing socket (getifaddrs only has 32-bit counters).
	private func interfaceCounters(_ name: String?) -> (UInt64, UInt64)? {
		var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
		var length = 0
		guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else { return nil }
		var buffer = [UInt8](repeating: 0, count: length)
		guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

		var bytesIn: UInt64 = 0
		var bytesOut: UInt64 = 0
		var found = false
		buffer.withUnsafeBytes { raw in
			var offset = 0
			while offset + MemoryLayout<if_msghdr>.size <= length {
				let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
				if Int32(header.ifm_type) == RTM_IFINFO2 {
					let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
					var ifName = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
					if_indextoname(UInt32(message.ifm_index), &ifName)
					let interface = String(cString: ifName)
					let matches = name.map { $0 == interface } ?? (interface != "lo0" && !interface.hasPrefix("utun"))
					if matches {
						bytesIn += message.ifm_data.ifi_ibytes
						bytesOut += message.ifm_data.ifi_obytes
						found = true
					}
				}
				offset += Int(header.ifm_msglen)
				if header.ifm_msglen == 0 { break }
			}
		}
		return found ? (bytesIn, bytesOut) : nil
	}

	// MARK: Disk

	private func diskRates() -> (Double?, Double?) {
		let now = ProcessInfo.processInfo.systemUptime
		var read: UInt64 = 0
		var written: UInt64 = 0
		var iterator = io_iterator_t(0)
		guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
			return (nil, nil)
		}
		defer { IOObjectRelease(iterator) }
		while case let service = IOIteratorNext(iterator), service != 0 {
			defer { IOObjectRelease(service) }
			guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
				.takeRetainedValue() as? [String: Any]
			else { continue }
			read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
			written += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
		}
		defer { previousDisk = (read, written, now) }
		guard let previous = previousDisk, now > previous.time, read >= previous.read, written >= previous.write else { return (nil, nil) }
		let elapsed = now - previous.time
		return (Double(read - previous.read) / elapsed, Double(written - previous.write) / elapsed)
	}
}

/// Apple Silicon temperature sensors exposed through the (private) IOHIDEventSystem — no root required.
private final class TemperatureSensors {
	private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
	private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
	private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
	private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
	private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
	private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double

	private let kIOHIDEventTypeTemperature: Int64 = 15
	private var services: [(name: String, service: AnyObject)] = []
	private var copyEvent: CopyEvent?
	private var getFloat: GetFloat?
	private var client: AnyObject?

	init() {
		let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
		func load<T>(_ name: String, as: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
		guard let create = load("IOHIDEventSystemClientCreate", as: ClientCreate.self),
		      let setMatching = load("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
		      let copyServices = load("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
		      let copyProperty = load("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
		      let client = create(kCFAllocatorDefault)?.takeRetainedValue()
		else { return }
		copyEvent = load("IOHIDServiceClientCopyEvent", as: CopyEvent.self)
		getFloat = load("IOHIDEventGetFloatValue", as: GetFloat.self)
		self.client = client
		// Vendor usage page 0xff00, usage 5 = temperature sensors.
		_ = setMatching(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
		let list = copyServices(client)?.takeRetainedValue() as? [AnyObject] ?? []
		services = list.compactMap { service in
			guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String else { return nil }
			return (name, service)
		}
	}

	func read() -> [String: Double] {
		guard let copyEvent, let getFloat else { return [:] }
		var readings: [String: Double] = [:]
		for (name, service) in services {
			guard let event = copyEvent(service, kIOHIDEventTypeTemperature, 0, 0)?.takeRetainedValue() else { continue }
			let value = getFloat(event, Int32(kIOHIDEventTypeTemperature << 16))
			if value > 0, value < 150 { readings[name] = value }
		}
		return readings
	}
}
