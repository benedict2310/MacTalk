//
//  PerformanceMonitor.swift
//  MacTalk
//
//  Performance monitoring and profiling utilities
//

import Foundation
import os.log
import Darwin  // FIX P0: For Mach APIs (task_info, thread_info, etc.)

final class PerformanceMonitor {

    // MARK: - Singleton

    static let shared = PerformanceMonitor()

    // MARK: - Properties

    private let logger = OSLog(subsystem: "com.mactalk.app", category: "Performance")
    private var timers: [String: CFAbsoluteTime] = [:]
    private let timerLock = NSLock()

    // Battery mode tracking
    private(set) var isBatteryMode: Bool = false
    private var batteryMonitorTimer: Timer?

    // Performance metrics
    private var metrics: [String: [TimeInterval]] = [:]
    private let metricsLock = NSLock()

    // MARK: - Initialization

    private init() {
        startBatteryMonitoring()
    }

    deinit {
        batteryMonitorTimer?.invalidate()
    }

    // MARK: - Timer Methods

    /// Start a performance timer with a given identifier
    func startTimer(_ identifier: String) {
        timerLock.lock()
        timers[identifier] = CFAbsoluteTimeGetCurrent()
        timerLock.unlock()
    }

    /// Stop a performance timer and log the duration
    @discardableResult
    func stopTimer(_ identifier: String) -> TimeInterval? {
        timerLock.lock()
        defer { timerLock.unlock() }

        guard let startTime = timers[identifier] else {
            os_log(.error, log: logger, "Timer '%{public}@' was never started", identifier)
            return nil
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        timers.removeValue(forKey: identifier)

        // Log performance
        os_log(.info, log: logger, "⏱️ %{public}@: %.3fms", identifier, duration * 1000)

        // Store metric
        recordMetric(identifier, duration: duration)

        return duration
    }

    /// Measure the execution time of a block
    func measure<T>(_ identifier: String, block: () throws -> T) rethrows -> T {
        startTimer(identifier)
        defer { stopTimer(identifier) }
        return try block()
    }

    /// Measure async execution time
    func measureAsync<T>(_ identifier: String, block: () async throws -> T) async rethrows -> T {
        startTimer(identifier)
        defer { stopTimer(identifier) }
        return try await block()
    }

    // MARK: - Metrics

    private func recordMetric(_ identifier: String, duration: TimeInterval) {
        metricsLock.lock()
        defer { metricsLock.unlock() }

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
        metricsLock.lock()
        defer { metricsLock.unlock() }

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
        metricsLock.lock()
        let identifiers = Array(metrics.keys)
        metricsLock.unlock()

        return identifiers.compactMap { getStatistics(for: $0) }
    }

    /// Clear all metrics
    func clearMetrics() {
        metricsLock.lock()
        metrics.removeAll()
        metricsLock.unlock()
    }

    // MARK: - Battery Monitoring

    private func startBatteryMonitoring() {
        updateBatteryStatus()

        // Update battery status every 30 seconds
        batteryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.updateBatteryStatus()
        }
    }

    private func updateBatteryStatus() {
        #if os(macOS)
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
                let wasOnBattery = isBatteryMode
                isBatteryMode = !output.contains("AC Power")

                // Log battery mode changes
                if wasOnBattery != isBatteryMode {
                    os_log(.info, log: logger, "🔋 Battery mode: %{public}@", isBatteryMode ? "ON" : "OFF")
                }
            }
        } catch {
            os_log(.error, log: logger, "Failed to check battery status: %{public}@", error.localizedDescription)
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

    func generateReport() -> String {
        var report = "=== MacTalk Performance Report ===\n\n"

        report += "Battery Mode: \(isBatteryMode ? "ON" : "OFF")\n\n"

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

    struct MetricStatistics {
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
