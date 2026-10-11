import Foundation
import UIKit
import Darwin

struct DeviceStats {
    var battery = "—"
    var charging = false
    var thermal = "Nominal"
    var memoryMB = 0
    var availableMB = 0
    var totalGB = 0
    var freeGB = 0.0
    var addresses: [String] = []

    static func read() -> DeviceStats {
        var result = DeviceStats()
        let device = UIDevice.current
        result.battery = device.batteryLevel < 0 ? "—" : "\(Int(device.batteryLevel * 100))%"
        result.charging = device.batteryState == .charging || device.batteryState == .full
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: result.thermal = "Nominal"
        case .fair: result.thermal = "Warm"
        case .serious: result.thermal = "Cooling"
        case .critical: result.thermal = "Critical"
        @unknown default: result.thermal = "Unknown"
        }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if status == KERN_SUCCESS { result.memoryMB = Int(info.phys_footprint / 1_048_576) }
        result.availableMB = Int(os_proc_available_memory() / 1_048_576)
        result.totalGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]), let bytes = values.volumeAvailableCapacityForImportantUsage {
            result.freeGB = Double(bytes) / 1_000_000_000
        }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&interfaces) == 0 {
            defer { freeifaddrs(interfaces) }
            var pointer = interfaces
            while let entry = pointer {
                let value = entry.pointee
                defer { pointer = value.ifa_next }
                guard let addr = value.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                      String(cString: value.ifa_name).hasPrefix("en"), value.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    result.addresses.append(String(cString: buffer))
                }
            }
        }
        return result
    }
}
