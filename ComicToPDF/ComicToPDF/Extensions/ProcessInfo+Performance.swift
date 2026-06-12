import Foundation

extension ProcessInfo {
    enum PerformanceClass {
        case low
        case medium
        case high
    }
    
    var performanceClass: PerformanceClass {
        let memory = physicalMemory
        let ramGB = Double(memory) / 1024.0 / 1024.0 / 1024.0
        if ramGB < 2.5 {
            return .low
        } else if ramGB < 6.5 {
            return .medium
        } else {
            return .high
        }
    }
}
