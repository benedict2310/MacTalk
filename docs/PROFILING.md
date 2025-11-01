# MacTalk Performance Profiling Guide

**Version:** 1.0
**Last Updated:** 2025-10-22
**Target:** Phase 5 - Performance Optimization

---

## Table of Contents

1. [Overview](#overview)
2. [Performance Targets](#performance-targets)
3. [Built-in Performance Monitoring](#built-in-performance-monitoring)
4. [Instruments Profiling](#instruments-profiling)
5. [Optimization Strategies](#optimization-strategies)
6. [Battery Mode](#battery-mode)
7. [Troubleshooting](#troubleshooting)

---

## Overview

MacTalk includes built-in performance monitoring and supports comprehensive profiling with Xcode Instruments. This guide covers how to measure, analyze, and optimize performance.

### Key Performance Areas

- **Audio Processing**: Real-time capture, mixing, and resampling
- **Whisper Inference**: ML model execution with Metal acceleration
- **UI Responsiveness**: Menu bar, HUD, and settings window
- **Memory Management**: Minimize footprint and prevent leaks
- **Battery Usage**: Optimize for MacBook battery life

---

## Performance Targets

### Latency Targets (M4, small model Q5_0)

| Operation | Target | Acceptable | Critical |
|-----------|--------|------------|----------|
| Streaming latency (first partial) | < 500ms | < 750ms | < 1000ms |
| Audio capture callback | < 10ms | < 20ms | < 50ms |
| Audio format conversion | < 5ms | < 10ms | < 20ms |
| Level meter update | < 16ms (60 FPS) | < 33ms (30 FPS) | < 50ms |
| HUD text update | < 16ms | < 33ms | < 50ms |
| End-to-end finalization (10s audio) | < 2s | < 4s | < 6s |

### Resource Targets

| Resource | Target | Acceptable | Critical |
|----------|--------|------------|----------|
| Memory (idle) | < 100 MB | < 200 MB | < 300 MB |
| Memory (recording, small model) | < 500 MB | < 1 GB | < 2 GB |
| Memory (recording, large model) | < 1.5 GB | < 2.5 GB | < 4 GB |
| GPU usage (streaming) | < 40% | < 60% | < 80% |
| CPU usage (streaming) | < 30% | < 50% | < 70% |
| Disk I/O (recording) | Minimal | < 1 MB/s | < 5 MB/s |

---

## Built-in Performance Monitoring

MacTalk includes `PerformanceMonitor` for real-time performance tracking.

### Using Performance Monitor

```swift
import Foundation

// Measure a synchronous operation
let result = PerformanceMonitor.shared.measure("AudioConversion") {
    return mixer.convert(buffer: audioBuffer)
}

// Measure an async operation
let transcript = await PerformanceMonitor.shared.measureAsync("Transcription") {
    return await engine.transcribe(samples: samples)
}

// Manual timer control
PerformanceMonitor.shared.startTimer("CustomOperation")
// ... do work ...
PerformanceMonitor.shared.stopTimer("CustomOperation")
```

### Generating Performance Reports

```swift
// In StatusBarController or debug menu
let report = PerformanceMonitor.shared.generateReport()
print(report)

// Example output:
// === MacTalk Performance Report ===
//
// Battery Mode: OFF
//
// Performance Metrics:
// -------------------
//
// AudioConversion:
//   Count:   1000
//   Average: 4.235ms
//   Median:  4.102ms
//   Min:     2.001ms
//   Max:     12.456ms
//   P95:     6.789ms
//   P99:     9.123ms
```

### Monitoring Memory and CPU

```swift
// Log current memory usage
PerformanceMonitor.shared.logMemoryUsage()
// Output: 💾 Memory usage: 125.34 MB

// Log current CPU usage
PerformanceMonitor.shared.logCPUUsage()
// Output: ⚡ CPU usage: 23.45%
```

### Viewing Logs

Performance logs use `os_log` and can be viewed in Console.app:

```bash
# Filter for MacTalk performance logs
log stream --predicate 'subsystem == "com.mactalk.app" AND category == "Performance"' --level info
```

---

## Instruments Profiling

### Time Profiler

**Purpose:** Identify hot spots and CPU-intensive operations

**How to use:**
1. Open MacTalk.xcodeproj in Xcode
2. Select Product → Profile (Cmd+I)
3. Choose "Time Profiler" template
4. Click Record
5. Perform typical operations (start recording, transcribe, stop)
6. Click Stop after 30-60 seconds

**Analysis:**
- Focus on the heaviest stack traces
- Look for:
  - Audio callback performance (should be < 10ms)
  - Whisper inference time
  - UI update overhead
  - Unexpected blocking operations

**Optimization targets:**
- Any function taking > 50ms should be investigated
- Audio callbacks must stay under 10ms to avoid dropouts
- UI updates should be < 16ms for smooth 60 FPS

### Allocations

**Purpose:** Track memory allocations and identify leaks

**How to use:**
1. Product → Profile → Allocations
2. Record during typical usage
3. Mark Generation (⌘ + /) at key points
4. Look for:
   - Growing heap size
   - Leaked objects
   - Abandoned memory
   - Large transient allocations

**Analysis:**
- Check for leaks (red bars in timeline)
- Review persistent allocations
- Look for unnecessary retain cycles

**Optimization targets:**
- Zero memory leaks
- Minimize transient allocations in audio callbacks
- Keep total memory under targets (see above)

### Leaks

**Purpose:** Detect memory leaks

**How to use:**
1. Product → Profile → Leaks
2. Record during extended usage
3. Stop and check for any detected leaks

**Analysis:**
- Investigate any leak detection
- Check reference cycles in callbacks
- Verify proper cleanup in deinit

### GPU

**Purpose:** Monitor Metal GPU usage for Whisper inference

**How to use:**
1. Product → Profile → Metal System Trace (or GPU)
2. Record during transcription
3. Analyze GPU utilization and shader performance

**Analysis:**
- GPU utilization should be < 60% during streaming
- Look for GPU stalls or inefficiencies
- Verify Metal backend is active

### Energy Log

**Purpose:** Measure battery impact

**How to use:**
1. Product → Profile → Energy Log
2. Record for extended period (5-10 minutes)
3. Review energy impact score

**Analysis:**
- Energy impact should be "Low" to "Medium"
- High CPU or GPU usage indicates optimization needed
- Check wake-ups and background activity

---

## Optimization Strategies

### Audio Processing Optimizations

#### 1. Use Accelerate Framework

```swift
import Accelerate

// ✅ Good: Use vDSP for RMS calculation
func calculateRMS(samples: [Float]) -> Float {
    var rms: Float = 0
    vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
    return rms
}

// ❌ Bad: Manual loop
func calculateRMSSlow(samples: [Float]) -> Float {
    let sum = samples.reduce(0) { $0 + $1 * $1 }
    return sqrt(sum / Float(samples.count))
}
```

#### 2. Minimize Allocations in Audio Callbacks

```swift
// ✅ Good: Reuse buffers
class AudioProcessor {
    private var reusableBuffer: [Float] = []

    func process(buffer: AVAudioPCMBuffer) {
        reusableBuffer.removeAll(keepingCapacity: true)
        // ... process ...
    }
}

// ❌ Bad: Allocate in callback
func process(buffer: AVAudioPCMBuffer) {
    let samples = [Float](repeating: 0, count: 1024) // ❌ Allocation!
}
```

#### 3. Optimize Format Conversions

```swift
// ✅ Good: Cache AVAudioConverter instances
private var cachedConverters: [AVAudioFormat: AVAudioConverter] = [:]

func getConverter(for format: AVAudioFormat) -> AVAudioConverter? {
    if let cached = cachedConverters[format] {
        return cached
    }
    let converter = AVAudioConverter(from: format, to: targetFormat)
    cachedConverters[format] = converter
    return converter
}
```

### Whisper Inference Optimizations

#### 1. Use Appropriate Model Size

```swift
// Battery mode: Use smaller model
if PerformanceMonitor.shared.isBatteryMode {
    modelType = .base  // Faster, less accurate
} else {
    modelType = .small // Balanced
}
```

#### 2. Batch Processing

```swift
// ✅ Good: Process in optimal chunk sizes
let chunkSize = 16000 * 3  // 3 seconds at 16kHz

// ❌ Bad: Too small chunks (overhead)
let chunkSize = 16000 / 10  // 0.1 seconds
```

#### 3. Thread Management

```swift
// ✅ Good: Use dedicated queue for inference
let inferenceQueue = DispatchQueue(label: "com.mactalk.inference", qos: .userInitiated)

inferenceQueue.async {
    let result = whisperEngine.transcribe(samples)
    DispatchQueue.main.async {
        self.updateUI(result)
    }
}
```

### UI Optimizations

#### 1. Batch UI Updates

```swift
// ✅ Good: Throttle updates
private var lastUpdateTime: TimeInterval = 0
private let updateThrottle: TimeInterval = 0.1 // 100ms

func updatePartialTranscript(_ text: String) {
    let now = CACurrentMediaTime()
    guard now - lastUpdateTime >= updateThrottle else { return }
    lastUpdateTime = now

    DispatchQueue.main.async {
        self.hudController?.update(text: text)
    }
}
```

#### 2. Minimize Main Thread Work

```swift
// ✅ Good: Heavy work off main thread
DispatchQueue.global(qos: .utility).async {
    let processedText = self.postProcess(transcript)
    DispatchQueue.main.async {
        self.displayText(processedText)
    }
}
```

---

## Battery Mode

MacTalk automatically detects battery mode and can adjust performance settings.

### Battery Mode Optimizations

```swift
func configureForBatteryMode(_ enabled: Bool) {
    if enabled {
        // Use smaller model
        modelType = .tiny

        // Reduce chunk processing frequency
        chunkDurationMs = 1000  // 1s instead of 750ms

        // Disable non-essential features
        enableVisualization = false

        // Reduce UI update frequency
        uiUpdateThrottle = 0.2  // 200ms instead of 100ms
    } else {
        // Restore full performance settings
        modelType = UserDefaults.standard.defaultModel
        chunkDurationMs = 750
        enableVisualization = true
        uiUpdateThrottle = 0.1
    }
}
```

### Monitoring Battery State

```swift
// Listen for battery mode changes
NotificationCenter.default.addObserver(
    forName: .batteryModeChanged,
    object: nil,
    queue: .main
) { [weak self] _ in
    let isBatteryMode = PerformanceMonitor.shared.isBatteryMode
    self?.configureForBatteryMode(isBatteryMode)
}
```

---

## Troubleshooting

### High CPU Usage

**Symptoms:** CPU > 70%, fans spinning, sluggish performance

**Diagnosis:**
1. Profile with Time Profiler
2. Check for busy loops or polling
3. Verify audio callback performance

**Solutions:**
- Reduce model size
- Increase chunk duration
- Optimize hot paths identified in profiler

### High Memory Usage

**Symptoms:** Memory > 2 GB, slowdowns, system pressure

**Diagnosis:**
1. Profile with Allocations
2. Check for memory leaks with Leaks instrument
3. Review large buffer allocations

**Solutions:**
- Release large buffers after use
- Implement buffer pooling
- Fix memory leaks
- Use smaller model

### Audio Dropouts/Glitches

**Symptoms:** Crackling, gaps in audio, transcription errors

**Diagnosis:**
1. Check audio callback duration (should be < 10ms)
2. Profile with Time Profiler during recording
3. Review thread priority settings

**Solutions:**
- Move heavy work out of audio callbacks
- Increase buffer sizes (if latency acceptable)
- Reduce concurrent operations during recording

### Slow Transcription

**Symptoms:** Long wait for final transcript, high latency

**Diagnosis:**
1. Profile Whisper inference with Time Profiler
2. Check GPU usage with Metal profiling
3. Verify Metal backend is active

**Solutions:**
- Use smaller model
- Verify Metal acceleration is enabled
- Check for CPU throttling (thermal)

### High GPU Usage

**Symptoms:** GPU > 80%, visual stuttering in other apps

**Diagnosis:**
1. Profile with Metal System Trace
2. Check model size and inference frequency

**Solutions:**
- Use smaller model
- Reduce inference frequency (increase chunk duration)
- Enable battery mode optimizations

---

## Performance Checklist

Before releasing or during optimization:

- [ ] Profile with Time Profiler - no functions > 50ms in hot path
- [ ] Profile with Allocations - no memory leaks
- [ ] Profile with Leaks - zero leaks detected
- [ ] Profile with GPU - utilization < 60% during typical use
- [ ] Test on battery - energy impact "Low" or "Medium"
- [ ] Test with all model sizes - meets latency targets
- [ ] Test concurrent operations - no blocking
- [ ] Review PerformanceMonitor reports - all metrics within targets
- [ ] Test memory usage - stays under budget
- [ ] Test on M1 - performance acceptable (not just M4)

---

## Additional Resources

- [Xcode Instruments User Guide](https://help.apple.com/instruments/)
- [Metal Performance Tuning](https://developer.apple.com/metal/Metal-Performance-Tuning.pdf)
- [WWDC: Optimizing App Performance](https://developer.apple.com/videos/play/wwdc2023/10181/)
- [Energy Efficiency Guide for Mac Apps](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-Mac/)

---

**Document Version:** 1.0
**Last Updated:** 2025-10-22
**Next Review:** After initial profiling results
