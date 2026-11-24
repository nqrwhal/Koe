import Darwin
import Foundation
import MLX

enum MemoryMonitor {
    struct Snapshot: Sendable {
        let footprintMB: Int
        let mlxActiveMB: Int
        let mlxCacheMB: Int
        let mlxPeakMB: Int
    }

    static func current() -> Snapshot {
        let footprintBytes = processFootprintBytes()
        let mlx = MLX.Memory.snapshot()
        return Snapshot(
            footprintMB: Int(footprintBytes / (1024 * 1024)),
            mlxActiveMB: mlx.activeMemory / (1024 * 1024),
            mlxCacheMB: mlx.cacheMemory / (1024 * 1024),
            mlxPeakMB: mlx.peakMemory / (1024 * 1024)
        )
    }

    static func processFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }
}
