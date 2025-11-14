# Liquid Glass UI Implementation Guide

**Version:** 1.0
**Last Updated:** 2025-11-10

---

## Table of Contents

1. [Overview](#overview)
2. [Design Goals](#design-goals)
3. [Apple Technologies Used](#apple-technologies-used)
4. [Implementation Components](#implementation-components)
   - [NSVisualEffectView for Glass Effects](#nsvisualeffectview-for-glass-effects)
   - [Borderless Window Configuration](#borderless-window-configuration)
   - [Scale Animations (In/Out)](#scale-animations-inout)
   - [Audio-Reactive Wave Visualization](#audio-reactive-wave-visualization)
5. [Complete Implementation](#complete-implementation)
6. [Performance Considerations](#performance-considerations)
7. [Best Practices](#best-practices)
8. [References](#references)

---

## Overview

This document describes the implementation approach for creating a liquid glass bubble UI on macOS that features:

- **Dark glass aesthetic** using native macOS visual effects
- **Borderless window** with no default close/minimize buttons
- **Smooth animations** that expand from center when appearing and contract to center when disappearing
- **Audio-reactive wave visualization** that responds smoothly to audio input levels

The implementation uses only native Apple frameworks (AppKit, QuartzCore) for optimal performance and native look-and-feel.

---

## Design Goals

1. **Native macOS Look**: Use `NSVisualEffectView` for authentic glass/blur effects
2. **Minimal Chrome**: Remove all default window controls (title bar, buttons)
3. **Smooth Animations**: Physics-based spring animations for natural motion
4. **Audio Reactivity**: Real-time wave visualization that responds to audio levels
5. **Performance**: Hardware-accelerated rendering using Core Animation layers
6. **Accessibility**: Maintain appropriate window behaviors for system integration

---

## Apple Technologies Used

### NSVisualEffectView
Provides native glass/blur effects with various materials optimized for different contexts.

**Key Properties:**
- `material` - Visual appearance style (`.hudWindow` for dark glass)
- `blendingMode` - How effect blends with background (`.behindWindow` or `.withinWindow`)
- `state` - Enable/disable effect (`.active` or `.inactive`)
- `maskImage` - Optional mask for custom shapes

**Official Documentation:** https://developer.apple.com/documentation/appkit/nsvisualeffectview

### NSWindow
Core window class with extensive configuration options for appearance and behavior.

**Key Properties for Borderless Windows:**
- `styleMask: [.borderless]` - Removes title bar and controls
- `backgroundColor: .clear` - Transparent background
- `isOpaque: false` - Allows transparency
- `hasShadow: true` - Adds depth shadow
- `level: .floating` - Window layering level
- `collectionBehavior` - Window behavior (spaces, expose, etc.)

**Official Documentation:** https://developer.apple.com/documentation/appkit/nswindow

### CABasicAnimation
Provides single-keyframe animations for layer properties.

**Key Properties:**
- `fromValue` - Starting value
- `toValue` - Ending value
- `duration` - Animation duration
- `timingFunction` - Easing curve

**Official Documentation:** https://developer.apple.com/documentation/quartzcore/cabasicanimation

### CASpringAnimation
Physics-based spring animation for natural motion with bounce effects.

**Key Properties:**
- `damping` - Spring damping (10-20 for subtle bounce)
- `stiffness` - Spring stiffness (200-400 for responsive feel)
- `mass` - Object mass (default 1.0)
- `initialVelocity` - Starting velocity
- `settlingDuration` - Calculated duration until spring settles

**Official Documentation:** https://developer.apple.com/documentation/quartzcore/caspringanimation

### CAShapeLayer
Hardware-accelerated layer for rendering vector paths.

**Key Properties:**
- `path` - CGPath to render
- `strokeColor` - Line color
- `fillColor` - Fill color
- `lineWidth` - Stroke width
- `lineCap` - Line cap style (`.round`, `.butt`, `.square`)

**Use Case:** Efficient rendering of animated sine wave paths for audio visualization.

---

## Implementation Components

### NSVisualEffectView for Glass Effects

#### Available Materials

The `NSVisualEffectView.Material` enum provides various materials optimized for different UI contexts:

**Dark Glass Materials (recommended for this use case):**
- `.hudWindow` - **Recommended**: Dark, semi-transparent HUD style
- `.fullScreenUI` - Dark material for full-screen interfaces
- `.popover` - Slightly lighter material for popovers
- `.underWindowBackground` - Under-window blur effect

**Other Materials:**
- `.titlebar` - Standard title bar material
- `.sidebar` - Sidebar material
- `.menu` - Menu background material
- `.sheet` - Sheet background material
- `.windowBackground` - Standard window background
- `.contentBackground` - Content area background
- `.tooltip` - Tooltip background

#### Blending Modes

- **`.behindWindow`** - Blends with content behind the window (desktop, other apps)
  - Best for floating overlays and HUDs
  - Makes entire window stand out above desktop
  - Used by sheets and popovers

- **`.withinWindow`** - Blends with window's own content
  - Best for scrolling content or internal chrome
  - Content below remains partially visible
  - Used by toolbars

#### Implementation Example

```swift
let visualEffectView = NSVisualEffectView()
visualEffectView.material = .hudWindow  // Dark glass effect
visualEffectView.blendingMode = .behindWindow  // Blend with desktop
visualEffectView.state = .active  // Enable effect
visualEffectView.wantsLayer = true
visualEffectView.layer?.cornerRadius = 100  // Circular bubble
visualEffectView.layer?.masksToBounds = true
```

#### Important Notes

From Apple's documentation:

> "The material and blending mode you assign determines the exact appearance of the visual effect. Not all materials support transparency, and materials apply vibrancy in different ways. The appearance and behavior of materials can also change based on system settings, so always pick a material based on its intended use."

> "AppKit creates visual effect views automatically for window titlebars, popovers, and source list table views. You don't need to add visual effect views to those elements of your interface."

**Vibrancy Considerations:**
- The presence of a visual effect view does not automatically add vibrancy to content
- Custom views must override `allowsVibrancy` and return `true`
- Enable vibrancy only in leaf views of view hierarchy
- Vibrancy works best with grayscale content
- Use built-in colors: `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor`, `quaternaryLabelColor`

**Subclassing Restrictions:**
- Always call `super` if overriding `viewDidMoveToWindow()` or `viewWillMove(toWindow:)`
- Do not override `draw(_:)` or `updateLayer()`

---

### Borderless Window Configuration

To create a window without default close/minimize buttons and title bar:

#### Basic Window Creation

```swift
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
```

#### Style Mask Options

- **`.borderless`** - No title bar, no resize controls
- **`.nonactivatingPanel`** - Panel doesn't activate when shown (optional, for non-modal overlays)

Other useful style masks:
- `.titled` - Standard title bar (opposite of borderless)
- `.closable` - Close button
- `.miniaturizable` - Minimize button
- `.resizable` - Resize handle
- `.fullSizeContentView` - Content extends under title bar

#### Window Appearance Configuration

```swift
// Transparent background
window.backgroundColor = .clear
window.isOpaque = false

// Shadow for depth
window.hasShadow = true

// Hide title bar elements (for non-borderless windows)
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden

// Window behavior
window.isMovableByWindowBackground = false  // Prevent dragging
window.level = .floating  // Stay on top
window.collectionBehavior = [.canJoinAllSpaces, .stationary]
```

#### Window Level Options

From `NSWindow.Level`:
- `.normal` - Standard window level
- `.floating` - Floats above normal windows
- `.statusBar` - Status bar level
- `.popUpMenu` - Pop-up menu level
- `.modalPanel` - Modal panel level
- `.screenSaver` - Screen saver level

#### Collection Behavior Options

Control window behavior in Mission Control and Spaces:
- `.canJoinAllSpaces` - Window appears in all spaces
- `.stationary` - Window appears in all spaces and isn't a window in expose
- `.transient` - Window doesn't appear in windows menu or expose
- `.fullScreenAuxiliary` - Can coexist with full-screen window

#### Circular Window Shape

```swift
window.contentView?.wantsLayer = true
window.contentView?.layer?.cornerRadius = 100  // Half of width/height for circle
window.contentView?.layer?.masksToBounds = true
```

---

### Scale Animations (In/Out)

#### Animate IN: Expand from Center

Use `CASpringAnimation` for natural, bouncy scale-in effect:

```swift
func animateIn() {
    guard let window = window else { return }

    // Start invisible
    window.alphaValue = 0
    window.makeKeyAndOrderFront(nil)

    // Create spring animation for scale
    let springAnimation = CASpringAnimation(keyPath: "transform.scale")
    springAnimation.fromValue = 0.0
    springAnimation.toValue = 1.0
    springAnimation.damping = 15  // Controls bounce (higher = less bounce)
    springAnimation.stiffness = 300  // Controls responsiveness (higher = faster)
    springAnimation.duration = springAnimation.settlingDuration  // Use calculated duration

    // Apply animation to window's content view
    window.contentView?.layer?.add(springAnimation, forKey: "scaleIn")

    // Fade in opacity
    window.animator().alphaValue = 1.0
}
```

#### Spring Animation Parameters

**`damping`** (default 10.0)
- Controls oscillation damping
- Lower values = more bounce
- Higher values = less bounce
- Recommended range: 10-20 for subtle bounce, 5-10 for pronounced bounce

**`stiffness`** (default 100.0)
- Controls spring tension
- Lower values = slower, more gradual
- Higher values = faster, snappier
- Recommended range: 200-400 for responsive UI

**`mass`** (default 1.0)
- Object mass
- Higher values = more inertia, slower settling
- Lower values = less inertia, faster settling

**`initialVelocity`** (default 0.0)
- Starting velocity of animation
- Can be positive or negative
- Useful for continuing motion from previous animation

**Alternative: Simple Duration/Bounce API**

```swift
// Simpler API introduced in newer macOS versions
let springAnimation = CASpringAnimation(perceptualDuration: 0.5, bounce: 0.3)
springAnimation.fromValue = 0.0
springAnimation.toValue = 1.0
```

#### Animate OUT: Contract to Center

Use `CABasicAnimation` for smooth, quick scale-out:

```swift
func animateOut(completion: @escaping () -> Void = {}) {
    guard let window = window else { return }

    // Create scale animation
    let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
    scaleAnimation.fromValue = 1.0
    scaleAnimation.toValue = 0.0
    scaleAnimation.duration = 0.25
    scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeIn)

    // Use CATransaction to get completion callback
    CATransaction.begin()
    CATransaction.setCompletionBlock {
        window.orderOut(nil)
        completion()
    }

    // Apply scale animation
    window.contentView?.layer?.add(scaleAnimation, forKey: "scaleOut")

    // Fade out opacity using NSAnimationContext
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.25
        window.animator().alphaValue = 0
    })

    CATransaction.commit()
}
```

#### Timing Functions

Available `CAMediaTimingFunction` names:
- `.linear` - Constant speed
- `.easeIn` - Slow start, fast end
- `.easeOut` - Fast start, slow end
- `.easeInEaseOut` - Slow start and end, fast middle
- `.default` - System default easing

#### Important: Anchor Point

For scale animations to expand/contract from center, ensure anchor point is centered:

```swift
window.contentView?.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
```

Default anchor point is (0.5, 0.5), so this is usually not necessary unless explicitly changed.

---

### Audio-Reactive Wave Visualization

#### Overview

Create smooth sine wave visualizations that respond to audio levels using `CAShapeLayer` for hardware-accelerated rendering.

#### Wave View Implementation

```swift
class AudioWaveView: NSView {
    private var waveLayers: [CAShapeLayer] = []
    private let numberOfWaves = 3  // Multiple layers for depth

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupWaveLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWaveLayers() {
        for i in 0..<numberOfWaves {
            let layer = CAShapeLayer()
            layer.strokeColor = NSColor.white.withAlphaComponent(0.3 - CGFloat(i) * 0.1).cgColor
            layer.fillColor = nil
            layer.lineWidth = 2.0
            layer.lineCap = .round
            layer.lineJoin = .round
            self.layer?.addSublayer(layer)
            waveLayers.append(layer)
        }
    }

    /// Update wave visualization based on audio level (0.0 - 1.0)
    func updateAudioLevel(_ level: Float) {
        let amplitude = CGFloat(level) * 40.0  // Max wave height in points

        for (index, layer) in waveLayers.enumerated() {
            let frequency = 2.0 + CGFloat(index) * 1.0  // Different frequencies for depth
            let phase = CGFloat(index) * 0.5  // Offset phases for visual variety
            let layerAmplitude = amplitude * (1.0 - CGFloat(index) * 0.2)  // Decrease amplitude per layer

            updateWavePath(layer, amplitude: layerAmplitude, frequency: frequency, phase: phase)
        }
    }

    private func updateWavePath(_ layer: CAShapeLayer, amplitude: CGFloat,
                               frequency: CGFloat, phase: CGFloat) {
        let width = bounds.width
        let height = bounds.height
        let midY = height / 2

        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: midY))

        // Generate smooth sine wave with 100 sample points
        let numberOfPoints = 100
        for i in 0...numberOfPoints {
            let x = CGFloat(i) / CGFloat(numberOfPoints) * width
            let normalizedX = x / width

            // Sine wave calculation
            let y = sin((normalizedX * frequency * 2 * .pi) + phase) * amplitude + midY

            path.line(to: NSPoint(x: x, y: y))
        }

        // Smoothly animate path changes
        let animation = CABasicAnimation(keyPath: "path")
        animation.duration = 0.1  // Fast update for responsive feel
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.fromValue = layer.path
        animation.toValue = path.cgPath

        layer.add(animation, forKey: "waveAnimation")
        layer.path = path.cgPath
    }
}
```

#### Sine Wave Mathematics

The wave visualization uses the standard sine wave equation:

```
y = A * sin(f * 2π * x + φ) + offset
```

Where:
- **A** (amplitude) - Wave height, driven by audio level
- **f** (frequency) - Number of complete waves across view width
- **x** - Normalized position (0.0 to 1.0)
- **φ** (phi/phase) - Horizontal offset for wave variety
- **offset** - Vertical centering (midY)

#### Performance Optimization

**Why CAShapeLayer:**
- Hardware-accelerated rendering via Core Animation
- Efficient path updates without redrawing entire view
- Automatic interpolation between path changes
- No need to override `draw(_:)` or manage drawing contexts

**Update Rate:**
- Call `updateAudioLevel()` at 60fps for smooth animation
- Use audio callback thread, but dispatch layer updates to main thread:

```swift
// In audio callback
let audioLevel = Float(rmsLevel)  // Calculate from audio buffer
DispatchQueue.main.async {
    waveView.updateAudioLevel(audioLevel)
}
```

**Path Caching:**
- Generate paths with fixed number of points (100 is good balance)
- Avoid excessive point density (diminishing visual returns)
- Use `.easeOut` timing for smooth transitions between updates

#### Customization Options

**Multiple Wave Layers:**
- Layer 0: Highest amplitude, highest opacity (primary wave)
- Layer 1: Medium amplitude, medium opacity (depth)
- Layer 2: Lowest amplitude, lowest opacity (background depth)

**Color Variations:**
```swift
// Monochrome with opacity
layer.strokeColor = NSColor.white.withAlphaComponent(0.3).cgColor

// Colored waves
layer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.5).cgColor

// Gradient stroke (more complex, requires CAGradientLayer)
```

**Wave Patterns:**
```swift
// Single wave: frequency = 1.0
// Multiple waves: frequency = 2.0, 3.0, 4.0
// Complex patterns: Combine multiple sine waves with different frequencies
```

**Animation Speed:**
```swift
// Responsive (fast updates): duration = 0.05 - 0.1
// Smooth (slower updates): duration = 0.2 - 0.3
```

---

## Complete Implementation

### AudioBubbleWindowController

Complete window controller that combines all components:

```swift
import Cocoa
import QuartzCore

class AudioBubbleWindowController: NSWindowController {
    private var visualEffectView: NSVisualEffectView!
    private var waveView: AudioWaveView!

    convenience init() {
        // Create borderless window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.init(window: window)
        setupWindow()
    }

    private func setupWindow() {
        guard let window = window else { return }

        // Configure window appearance
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Add glass effect background
        visualEffectView = NSVisualEffectView(frame: window.contentView!.bounds)
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .hudWindow  // Dark glass
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 100  // Circular
        visualEffectView.layer?.masksToBounds = true

        window.contentView?.addSubview(visualEffectView)

        // Add wave visualization on top
        waveView = AudioWaveView(frame: window.contentView!.bounds)
        waveView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(waveView)

        // Center window on screen
        window.center()
    }

    // MARK: - Public API

    /// Show the bubble with scale-in animation
    func show() {
        guard let window = window else { return }

        // Start invisible
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)

        // Spring animation for scale
        let springAnimation = CASpringAnimation(keyPath: "transform.scale")
        springAnimation.fromValue = 0.0
        springAnimation.toValue = 1.0
        springAnimation.damping = 15
        springAnimation.stiffness = 300
        springAnimation.duration = springAnimation.settlingDuration

        window.contentView?.layer?.add(springAnimation, forKey: "scaleIn")

        // Fade in
        window.animator().alphaValue = 1.0
    }

    /// Hide the bubble with scale-out animation
    func hide(completion: @escaping () -> Void = {}) {
        guard let window = window else { return }

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = 1.0
        scaleAnimation.toValue = 0.0
        scaleAnimation.duration = 0.25
        scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeIn)

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            window.orderOut(nil)
            completion()
        }

        window.contentView?.layer?.add(scaleAnimation, forKey: "scaleOut")

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            window.animator().alphaValue = 0
        })

        CATransaction.commit()
    }

    /// Update wave visualization with current audio level
    /// - Parameter level: Audio level from 0.0 (silent) to 1.0 (max)
    func updateAudioLevel(_ level: Float) {
        waveView.updateAudioLevel(level)
    }
}
```

### Usage Example

```swift
// Create bubble window controller
let bubbleController = AudioBubbleWindowController()

// Show it with animation
bubbleController.show()

// Update with audio levels (call repeatedly from audio callback)
// audioLevel should be normalized 0.0 - 1.0
bubbleController.updateAudioLevel(audioLevel)

// Hide with animation
bubbleController.hide {
    print("Bubble hidden")
}
```

### Integration with Audio Pipeline

Assuming you have an audio capture system that provides RMS levels:

```swift
class AudioCaptureManager {
    private var bubbleController: AudioBubbleWindowController?

    func startCapture() {
        bubbleController = AudioBubbleWindowController()
        bubbleController?.show()

        // Start audio capture...
    }

    func stopCapture() {
        bubbleController?.hide {
            self.bubbleController = nil
        }

        // Stop audio capture...
    }

    // Called from audio callback
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Calculate RMS level
        let rmsLevel = calculateRMS(buffer)

        // Update bubble on main thread
        DispatchQueue.main.async {
            self.bubbleController?.updateAudioLevel(rmsLevel)
        }
    }

    private func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0.0 }
        let frameLength = Int(buffer.frameLength)
        let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)

        var sum: Float = 0.0
        for sample in samples {
            sum += sample * sample
        }

        let rms = sqrtf(sum / Float(frameLength))
        return min(rms * 5.0, 1.0)  // Scale and clamp to 0-1
    }
}
```

---

## Performance Considerations

### Core Animation Layer-Backing

**Why it matters:**
- Layer-backed views use hardware-accelerated rendering
- Animations run on separate thread (no main thread blocking)
- Compositing handled by GPU

**Ensure layer-backing:**
```swift
view.wantsLayer = true  // Enable layer-backing
```

### Animation Performance

**Best Practices:**
- Use `CABasicAnimation` and `CASpringAnimation` instead of `NSAnimation`
- Avoid animating expensive properties (prefer `transform`, `opacity`, `position`)
- Use `shouldRasterize = true` for complex layer hierarchies (with caution)
- Keep layer hierarchy shallow

**Property Performance:**
- **Fast:** `transform`, `opacity`, `position`, `bounds`
- **Medium:** `cornerRadius`, `borderWidth`, `shadowOpacity`
- **Slow:** `shadowPath` changes, `masksToBounds` with complex content

### Wave Rendering Optimization

**Path Complexity:**
- 100 points per wave is sufficient for smooth curves
- More points = diminishing visual returns + higher CPU cost
- Avoid real-time path generation on audio thread

**Update Rate:**
- 60fps updates ideal for smooth animation
- 30fps acceptable for less critical animations
- Throttle updates if needed to maintain performance

**Memory Considerations:**
- Reuse `CAShapeLayer` instances (don't recreate)
- Avoid retaining large path objects unnecessarily
- Use explicit animations (remove when complete)

### Transparency and Blending

**Overhead:**
- Transparent windows require additional compositing
- `NSVisualEffectView` performs real-time blurring (GPU-accelerated)
- Multiple overlapping transparent layers multiply cost

**Optimization:**
- Keep visual effect view as background (base layer)
- Avoid excessive nesting of transparent views
- Use opaque views for content where possible

### Display Link for Smooth Updates

For very smooth audio visualization, consider using `CVDisplayLink`:

```swift
class AudioWaveView: NSView {
    private var displayLink: CVDisplayLink?
    private var currentAudioLevel: Float = 0.0

    func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)

        guard let displayLink = displayLink else { return }

        CVDisplayLinkSetOutputCallback(displayLink, { (_, _, _, _, _, context) -> CVReturn in
            guard let context = context else { return kCVReturnSuccess }
            let view = Unmanaged<AudioWaveView>.fromOpaque(context).takeUnretainedValue()

            DispatchQueue.main.async {
                view.updateWaveDisplay()
            }

            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())

        CVDisplayLinkStart(displayLink)
    }

    func stopDisplayLink() {
        guard let displayLink = displayLink else { return }
        CVDisplayLinkStop(displayLink)
    }

    func setAudioLevel(_ level: Float) {
        currentAudioLevel = level
    }

    private func updateWaveDisplay() {
        updateAudioLevel(currentAudioLevel)
    }
}
```

---

## Best Practices

### Window Behavior

1. **Use `.nonactivatingPanel` for overlays** that shouldn't steal focus
2. **Set appropriate window level** (`.floating` for HUDs, `.normal` for standard windows)
3. **Handle window ordering** carefully to avoid z-order conflicts
4. **Test with multiple displays** and Spaces configurations

### Visual Effect Views

1. **Choose material based on intended use**, not appearance
2. **Don't nest visual effect views** unnecessarily (performance impact)
3. **Handle Dark Mode** automatically (materials adapt to system appearance)
4. **Test on different backgrounds** (desktop wallpapers, other apps)

### Animations

1. **Use completion handlers** to sequence animations properly
2. **Clean up animations** when view is removed from hierarchy
3. **Respect Reduce Motion** accessibility setting:
```swift
if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    // Show without animation
} else {
    // Animate normally
}
```

### Audio Integration

1. **Normalize audio levels** to 0.0 - 1.0 range before visualization
2. **Update on main thread** (Core Animation requires main thread)
3. **Handle audio interruptions** gracefully (hide bubble when audio stops)
4. **Smooth level changes** (apply low-pass filter to avoid jittery waves):
```swift
private var smoothedLevel: Float = 0.0
private let smoothingFactor: Float = 0.3

func updateAudioLevel(_ rawLevel: Float) {
    smoothedLevel = smoothedLevel * (1.0 - smoothingFactor) + rawLevel * smoothingFactor
    waveView.updateAudioLevel(smoothedLevel)
}
```

### Memory Management

1. **Weak references** for delegates and callbacks
2. **Release window** when done (if using manual memory management)
3. **Stop animations** before releasing window
4. **Remove from superview** before deallocation

### Accessibility

1. **Don't block important UI** with floating windows
2. **Provide VoiceOver descriptions** if window contains important info
3. **Handle keyboard navigation** if window accepts interaction
4. **Respect system preferences** (Reduce Motion, Increase Contrast)

---

## References

### Apple Documentation

- [NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview)
- [NSWindow](https://developer.apple.com/documentation/appkit/nswindow)
- [CABasicAnimation](https://developer.apple.com/documentation/quartzcore/cabasicanimation)
- [CASpringAnimation](https://developer.apple.com/documentation/quartzcore/caspringanimation)
- [CAShapeLayer](https://developer.apple.com/documentation/quartzcore/cashapelayer)
- [Core Animation Programming Guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/)

### Related MacTalk Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) - Overall system architecture
- [UI Components](ARCHITECTURE.md#ui-components) - Existing UI components
- [Audio Pipeline](ARCHITECTURE.md#audio-pipeline) - Audio capture and processing

### WWDC Sessions

- WWDC 2013: Session 220 - Implementing Engaging UI on iOS
- WWDC 2014: Session 236 - Building Adaptive Apps with UIKit
- WWDC 2016: Session 240 - UIKit + Core Animation: Performance Optimization
- WWDC 2019: Session 227 - Font Management and Text Scaling

### External Resources

- [objc.io: Advanced Core Animation](https://www.objc.io/issues/12-animations/)
- [Ray Wenderlich: Core Animation Tutorial](https://www.raywenderlich.com/library?q=core%20animation)

---

**Last Updated:** 2025-11-10
**Maintained by:** MacTalk Development Team
