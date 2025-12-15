# S.02.1a - Utilities & Singleton Concurrency

**Epic:** Swift 6 Migration
**Status:** Pending
**Date:** 2025-12-15
**Dependency:** S.02.0, S.02.1

---

## 1. Objective

Migrate utility classes and singletons to be Swift 6 concurrency-safe.

**Goal:** Ensure all shared utility services have proper isolation without breaking their cross-cutting usage patterns.

---

## 2. Scope

This story covers non-UI utility classes that are used throughout the codebase:

| Class | Current Pattern | Risk Level |
|-------|-----------------|------------|
| `AppSettings` | Singleton + NSLock | Medium |
| `ClipboardManager` | Enum + static state | Medium |
| `PerformanceMonitor` | Singleton + NSLock | Low |
| `DebugLogger` | Static methods | Low |
| `ModelManager` | Singleton + callbacks | High |
| `ModelDownloader` | NSObject + delegate | Medium |
| `SHA256Streamer` | Static methods | Low |

---

## 3. Implementation Plan

### Step 1: AppSettings Migration

**Current State (AppSettings.swift):**
```swift
final class AppSettings {
    static let shared = AppSettings()
    private let lock = NSLock()

    var provider: ASRProvider {
        get {
            lock.lock()
            defer { lock.unlock() }
            // ...
        }
        set {
            lock.lock()
            // ...
            lock.unlock()
            NotificationCenter.default.post(...)
        }
    }
}
```

**Issues:**
- NSLock not suitable for Swift 6 strict mode
- Notification posted outside lock (correct) but threading unclear
- Other properties (`autoPaste`, `modelIndex`, etc.) not protected

**Migration - Option A: @MainActor (Recommended)**
```swift
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    var provider: ASRProvider {
        didSet {
            if oldValue != provider {
                NotificationCenter.default.post(
                    name: AppSettings.providerDidChangeNotification,
                    object: self
                )
            }
        }
    }

    // All properties now MainActor-isolated
    var autoPaste: Bool { ... }
    var modelIndex: Int { ... }
}
```

**Why @MainActor:**
- Settings are primarily accessed from UI code
- Notifications should post on main thread
- Simplifies access pattern (no await needed from UI)

**Call Site Updates:**
```swift
// Before (anywhere)
let provider = AppSettings.shared.provider

// After (from MainActor context)
let provider = AppSettings.shared.provider  // Same!

// After (from background)
let provider = await MainActor.run { AppSettings.shared.provider }
```

### Step 2: ClipboardManager Migration

**Current State (ClipboardManager.swift):**
```swift
enum ClipboardManager {
    private static var clipboardHistory: [String] = []
    private static let maxHistorySize = 10

    static func setClipboard(_ text: String) { ... }
    static func addToHistory(_ text: String) { ... }
}
```

**Issues:**
- `clipboardHistory` is mutable static state (data race!)
- No synchronization
- `NSPasteboard` operations must be main thread

**Migration:**
```swift
@MainActor
enum ClipboardManager {
    private static var clipboardHistory: [String] = []

    static func setClipboard(_ text: String) {
        // NSPasteboard requires main thread - now guaranteed
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func addToHistory(_ text: String) {
        // Now isolated - no race possible
        clipboardHistory.insert(text, at: 0)
        if clipboardHistory.count > maxHistorySize {
            clipboardHistory.removeLast()
        }
    }
}
```

### Step 3: PerformanceMonitor Migration

**Current State (PerformanceMonitor.swift):**
```swift
final class PerformanceMonitor {
    static let shared = PerformanceMonitor()
    private var timers: [String: CFAbsoluteTime] = [:]
    private let timerLock = NSLock()
    private var metrics: [String: [TimeInterval]] = [:]
    private let metricsLock = NSLock()
}
```

**Issues:**
- Multiple NSLocks (correct but verbose)
- `batteryMonitorTimer` accessed without lock
- Called from multiple threads (audio, inference, UI)

**Migration - Option: Actor**
```swift
actor PerformanceMonitor {
    static let shared = PerformanceMonitor()

    private var timers: [String: CFAbsoluteTime] = [:]
    private var metrics: [String: [TimeInterval]] = [:]

    // Battery monitoring stays on main
    @MainActor private var batteryMonitorTimer: Timer?
    nonisolated private(set) var isBatteryMode: Bool = false

    func startTimer(_ identifier: String) {
        timers[identifier] = CFAbsoluteTimeGetCurrent()
    }

    func stopTimer(_ identifier: String) -> TimeInterval? {
        guard let startTime = timers.removeValue(forKey: identifier) else {
            return nil
        }
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        recordMetric(identifier, duration: duration)
        return duration
    }

    // Convenience for sync contexts
    nonisolated func measure<T>(_ identifier: String, block: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let duration = CFAbsoluteTimeGetCurrent() - start
            Task { await self.recordMetric(identifier, duration: duration) }
        }
        return try block()
    }
}
```

**Alternative: Keep @unchecked Sendable**

If actor overhead is unacceptable for performance monitoring:
```swift
final class PerformanceMonitor: @unchecked Sendable {
    static let shared = PerformanceMonitor()
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    struct State {
        var timers: [String: CFAbsoluteTime] = [:]
        var metrics: [String: [TimeInterval]] = [:]
    }
}
```

### Step 4: ModelManager Migration

**Current State (ModelManager.swift):**
```swift
final class ModelManager {
    static let shared = ModelManager()
    private let downloader = ModelDownloader()
    var onDownloadState: ((ModelDownloader.State) -> Void)?
    private var isDownloading = false
    private var currentDownloadSpec: ModelSpec?
}
```

**Issues:**
- `onDownloadState` callback not @Sendable
- `isDownloading` and `currentDownloadSpec` accessed without synchronization
- Callback may be called from URLSession delegate queue

**Migration:**
```swift
@MainActor
final class ModelManager {
    static let shared = ModelManager()

    private let downloader = ModelDownloader()

    // Callback isolated to MainActor
    var onDownloadState: ((ModelDownloader.State) -> Void)?

    private var isDownloading = false
    private var currentDownloadSpec: ModelSpec?

    func ensureAvailable(_ spec: ModelSpec) async throws -> URL {
        // Check if model exists
        if ModelStore.exists(spec) {
            return ModelStore.path(for: spec)
        }

        // Prevent concurrent downloads
        guard !isDownloading else {
            throw ModelManagerError.downloadInProgress
        }

        isDownloading = true
        currentDownloadSpec = spec
        defer {
            isDownloading = false
            currentDownloadSpec = nil
        }

        // Start download and await completion
        return try await withCheckedThrowingContinuation { continuation in
            downloader.onState = { [weak self] state in
                Task { @MainActor in
                    self?.onDownloadState?(state)

                    switch state {
                    case .done(let url):
                        continuation.resume(returning: url)
                    case .failed(let error):
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
            }
            downloader.start(spec: spec)
        }
    }
}
```

### Step 5: ModelDownloader Migration

**Current State (ModelDownloader.swift):**
```swift
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    var onState: ((State) -> Void)?
    // URLSession delegate methods called on delegate queue
}
```

**Issues:**
- Delegate methods called on arbitrary queue
- `onState` callback not thread-safe
- Multiple dispatch to main queue scattered through code

**Migration:**
```swift
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    // Callback always dispatched to main
    var onState: (@MainActor (State) -> Void)?

    private func notifyState(_ state: State) {
        Task { @MainActor in
            self.onState?(state)
        }
    }

    // URLSessionDownloadDelegate
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        notifyState(.running(progress: progress))
    }
}
```

---

## 4. Acceptance Criteria

- [ ] `AppSettings` is `@MainActor` isolated
- [ ] `ClipboardManager` is `@MainActor` isolated
- [ ] `PerformanceMonitor` is actor or `@unchecked Sendable` with justification
- [ ] `ModelManager` is `@MainActor` isolated
- [ ] `ModelDownloader` callbacks are `@MainActor`
- [ ] All call sites updated (no new warnings)
- [ ] Existing tests pass
- [ ] No runtime threading issues

---

## 5. Testing Strategy

### Unit Tests
- [ ] `AppSettings` property changes post notifications on main thread
- [ ] `ClipboardManager` clipboard operations work
- [ ] `PerformanceMonitor` timer accuracy within 5%
- [ ] `ModelManager` prevents concurrent downloads

### Integration Tests
- [ ] Settings changes in SettingsWindowController propagate correctly
- [ ] Model download progress updates UI smoothly
- [ ] Clipboard operations work during transcription

### Thread Sanitizer
```bash
xcodebuild test \
  -project MacTalk.xcodeproj \
  -scheme MacTalk \
  -enableThreadSanitizer YES \
  -only-testing:MacTalkTests/ModelManagerTests \
  -only-testing:MacTalkTests/SettingsTests
```

---

## 6. Risk Assessment

**Risk Level: MEDIUM**

| Component | Risk | Mitigation |
|-----------|------|------------|
| AppSettings | Low | Simple @MainActor, well-tested |
| ClipboardManager | Low | Already main-thread operations |
| PerformanceMonitor | Medium | Actor overhead acceptable for profiling |
| ModelManager | Medium | Callback threading needs careful testing |
| ModelDownloader | Medium | URLSession delegate threading |

**Estimated Effort:** 4-6 hours
