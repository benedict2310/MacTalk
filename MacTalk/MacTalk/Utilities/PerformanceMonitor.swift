//
//  PerformanceMonitor.swift
//  MacTalk
//
//  Performance monitoring and profiling utilities
//

import Foundation
import os.log
import Darwin  // FIX P0: For Mach APIs (task_info, thread_info, etc.)

/// Performance monitor using Swift actor for thread-safe metric collection.
/// Battery monitoring is handled on the main actor separately.
actor PerformanceMonitor {

    // MARK: - Singleton

    static let shared = PerformanceMonitor()

    // MARK: - Properties

    private let logger = OSLog(subsystem: "com.mactalk.app", category: "Performance")
    private var timers: [String: CFAbsoluteTime] = [:]

    // Battery mode tracking - accessed from main actor for timer
    @MainActor private static var _isBatteryMode: Bool = false
    @MainActor private static var batteryMonitorTimer: Timer?

    /// Current battery mode status (async accessor for non-MainActor contexts)
    var isBatteryMode: Bool {
        get async { await MainActor.run { Self._isBatteryMode } }
    }

    /// Synchronous battery mode check - only call from MainActor context
    @MainActor
    static var currentBatteryMode: Bool {
        _isBatteryMode
    }

    // Performance metrics
    private var metrics: [String: [TimeInterval]] = [:]

    // MARK: - Initialization

    private init() {
        Task { @MainActor in
            Self.startBatteryMonitoring()
        }
    }

    // MARK: - Timer Methods

    /// Start a performance timer with a given identifier
    func startTimer(_ identifier: String) {
        timers[identifier] = CFAbsoluteTimeGetCurrent()
    }

    /// Stop a performance timer and log the duration
    @discardableResult
    func stopTimer(_ identifier: String) -> TimeInterval? {
        guard let startTime = timers.removeValue(forKey: identifier) else {
            os_log(.error, log: logger, "Timer '%{public}@' was never started", identifier)
            return nil
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime

        // Log performance
        os_log(.info, log: logger, "⏱️ %{public}@: %.3fms", identifier, duration * 1000)

        // Store metric
        recordMetric(identifier, duration: duration)

        return duration
    }

    /// Measure the execution time of a block (async version)
    func measure<T>(_ identifier: String, block: () async throws -> T) async rethrows -> T {
        startTimer(identifier)
        defer { _ = stopTimer(identifier) }
        return try await block()
    }

    /// Convenience for synchronous contexts - records metric asynchronously
    nonisolated func measureSync<T>(_ identifier: String, block: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let duration = CFAbsoluteTimeGetCurrent() - start
            Task { await self.recordMetric(identifier, duration: duration) }
        }
        return try block()
    }

    // MARK: - Metrics

    private func recordMetric(_ identifier: String, duration: TimeInterval) {
        if metrics[identifier] == nil {
            metrics[identifier] = []
        }
        metrics[identifier]?.append(duration)

        // Keep only last 100 measurements
        if let count = metrics[identifier]?.count, count > 100 {
            metrics[identifier]?.removeFirst()
        }
    }

    /// Get statistics for a metric
    func getStatistics(for identifier: String) -> MetricStatistics? {
        guard let durations = metrics[identifier], !durations.isEmpty else {
            return nil
        }

        let sorted = durations.sorted()
        let count = durations.count

        return MetricStatistics(
            identifier: identifier,
            count: count,
            min: sorted.first ?? 0,
            max: sorted.last ?? 0,
            average: durations.reduce(0, +) / Double(count),
            median: sorted[count / 2],
            p95: sorted[Int(Double(count) * 0.95)],
            p99: sorted[Int(Double(count) * 0.99)]
        )
    }

    /// Get all metric statistics
    func getAllStatistics() -> [MetricStatistics] {
        return metrics.keys.compactMap { getStatistics(for: $0) }
    }

    /// Clear all metrics
    func clearMetrics() {
        metrics.removeAll()
    }

    // MARK: - Battery Monitoring

    @MainActor
    private static func startBatteryMonitoring() {
        updateBatteryStatus()

        // Update battery status every 30 seconds
        batteryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            Task { @MainActor in
                updateBatteryStatus()
            }
        }
    }

    @MainActor
    private static func updateBatteryStatus() {
        #if os(macOS)
        // Run pmset on background queue to avoid blocking UI
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g", "batt"]

            let pipe = Pipe()
            process.standardOutput = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let newBatteryMode = !output.contains("AC Power")

                    // Update isBatteryMode on main actor
                    await MainActor.run {
                        let wasOnBattery = _isBatteryMode
                        _isBatteryMode = newBatteryMode

                        // Log battery mode changes
                        if wasOnBattery != newBatteryMode {
                            let logger = OSLog(subsystem: "com.mactalk.app", category: "Performance")
                            os_log(.info, log: logger, "🔋 Battery mode: %{public}@", newBatteryMode ? "ON" : "OFF")
                        }
                    }
                }
            } catch {
                let logger = OSLog(subsystem: "com.mactalk.app", category: "Performance")
                os_log(.error, log: logger, "Failed to check battery status: %{public}@", error.localizedDescription)
            }
        }
        #endif
    }

    // MARK: - Memory Monitoring

    func logMemoryUsage() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            let usedMB = Double(info.resident_size) / 1024.0 / 1024.0
            os_log(.info, log: logger, "💾 Memory usage: %.2f MB", usedMB)
        }
    }

    // MARK: - CPU Monitoring

    func logCPUUsage() {
        var threadsList: thread_act_array_t?
        var threadsCount = mach_msg_type_number_t(0)

        let result = task_threads(mach_task_self_, &threadsList, &threadsCount)

        if result == KERN_SUCCESS, let threads = threadsList {
            var totalCPU: Double = 0

            for threadIndex in 0..<Int(threadsCount) {
                var threadInfo = thread_basic_info()
                var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)

                let infoResult = withUnsafeMutablePointer(to: &threadInfo) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                        thread_info(threads[threadIndex], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                    }
                }

                if infoResult == KERN_SUCCESS {
                    totalCPU += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
                }
            }

            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(Int(threadsCount) * MemoryLayout<thread_t>.stride))

            os_log(.info, log: logger, "⚡ CPU usage: %.2f%%", totalCPU)
        }
    }

    // MARK: - Performance Report

    func generateReport() async -> String {
        var report = "=== MacTalk Performance Report ===\n\n"

        let batteryMode = await isBatteryMode
        report += "Battery Mode: \(batteryMode ? "ON" : "OFF")\n\n"

        let stats = getAllStatistics().sorted { $0.identifier < $1.identifier }

        if stats.isEmpty {
            report += "No performance metrics recorded yet.\n"
        } else {
            report += "Performance Metrics:\n"
            report += "-------------------\n\n"

            for stat in stats {
                report += "\(stat.identifier):\n"
                report += "  Count:   \(stat.count)\n"
                report += "  Average: \(String(format: "%.3f", stat.average * 1000))ms\n"
                report += "  Median:  \(String(format: "%.3f", stat.median * 1000))ms\n"
                report += "  Min:     \(String(format: "%.3f", stat.min * 1000))ms\n"
                report += "  Max:     \(String(format: "%.3f", stat.max * 1000))ms\n"
                report += "  P95:     \(String(format: "%.3f", stat.p95 * 1000))ms\n"
                report += "  P99:     \(String(format: "%.3f", stat.p99 * 1000))ms\n\n"
            }
        }

        return report
    }

    // MARK: - Types

    struct MetricStatistics: Sendable {
        let identifier: String
        let count: Int
        let min: TimeInterval
        let max: TimeInterval
        let average: TimeInterval
        let median: TimeInterval
        let p95: TimeInterval
        let p99: TimeInterval
    }
}
