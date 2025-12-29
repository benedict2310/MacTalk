# S.03.1h - Rolling Summaries

**Epic:** Real-Time Streaming Transcription
**Status:** Draft
**Date:** 2025-12-14
**Dependency:** S.03.1a (requires finalized segments)
**Priority:** Low (Nice-to-have)

---

## 1. Objective

Generate periodic summaries during long transcription sessions without waiting for post-processing.

**Goal:** Users see bullet-point summaries update every 5-10 seconds during meetings/lectures.

---

## 2. Architecture Context & Reuse

- Summaries should consume finalized segments from streaming (S.03.1a) or batch results, not raw partials.
- Keep summaries local only (no network calls) and avoid heavy work on the main thread.

## 3. Acceptance Criteria

- [ ] Summary bullets appear every 5-10 seconds of finalized transcription
- [ ] Summaries are extractive (key phrases from transcript)
- [ ] Summary panel is collapsible/hideable
- [ ] Summaries can be copied separately from full transcript
- [ ] No external API calls (fully local)

---

## 4. Scope Decision

### Option A: Rule-Based Extraction (MVP)
- Extract sentences containing key phrases
- Identify topic shifts via keyword analysis
- Simple but predictable

### Option B: Local LLM Summarization (Future)
- Use local model (e.g., Llama via llama.cpp)
- Higher quality but heavier resources
- Defer to future story

**Decision:** Start with Option A for MVP.

---

## 5. Implementation Plan

### Step 1: Extractive Summarizer

```swift
/// Rule-based extractive summarizer for real-time use
final class ExtractiveSummarizer {
    struct Config {
        var minSentencesForSummary: Int = 3
        var maxBullets: Int = 5
        var keywordWeight: Double = 1.5
        var positionWeight: Double = 1.2  // First/last sentences score higher
    }

    private let config: Config
    private var processedText: String = ""
    private var bullets: [String] = []

    init(config: Config = Config()) {
        self.config = config
    }

    /// Process new finalized segment, return updated bullets
    func process(segment: ASRFinalSegment) -> [String] {
        processedText += " " + segment.text

        let sentences = extractSentences(from: processedText)
        guard sentences.count >= config.minSentencesForSummary else {
            return bullets
        }

        // Score sentences
        let scored = sentences.enumerated().map { (index, sentence) in
            (sentence: sentence, score: scoreSentence(sentence, index: index, total: sentences.count))
        }

        // Select top N
        let topSentences = scored
            .sorted { $0.score > $1.score }
            .prefix(config.maxBullets)
            .map { $0.sentence }

        // Maintain chronological order
        bullets = sentences.filter { topSentences.contains($0) }

        return bullets
    }

    private func extractSentences(from text: String) -> [String] {
        // Use NLTokenizer for proper sentence splitting
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count > 20 {  // Skip very short sentences
                sentences.append(sentence)
            }
            return true
        }

        return sentences
    }

    private func scoreSentence(_ sentence: String, index: Int, total: Int) -> Double {
        var score: Double = 0

        // Length score (prefer medium-length sentences)
        let wordCount = sentence.components(separatedBy: .whitespaces).count
        if wordCount >= 5 && wordCount <= 25 {
            score += 1.0
        }

        // Position score (first and last sentences often important)
        if index == 0 || index == total - 1 {
            score += config.positionWeight
        }

        // Keyword score
        let keywords = extractKeywords(from: processedText)
        let sentenceWords = Set(sentence.lowercased().components(separatedBy: .whitespaces))
        let keywordOverlap = Double(keywords.intersection(sentenceWords).count)
        score += keywordOverlap * config.keywordWeight

        // Contains numbers (often important facts)
        if sentence.range(of: "\\d+", options: .regularExpression) != nil {
            score += 0.5
        }

        return score
    }

    private func extractKeywords(from text: String) -> Set<String> {
        // Simple TF-based keyword extraction
        let words = text.lowercased()
            .components(separatedBy: .whitespaces)
            .filter { $0.count > 4 }  // Skip short words

        var frequency: [String: Int] = [:]
        for word in words {
            frequency[word, default: 0] += 1
        }

        // Top 10% by frequency
        let threshold = frequency.values.sorted().dropFirst(frequency.count * 9 / 10).first ?? 1
        return Set(frequency.filter { $0.value >= threshold }.keys)
    }

    func reset() {
        processedText = ""
        bullets = []
    }
}
```

**File:** `MacTalk/MacTalk/Utilities/ExtractiveSummarizer.swift`

### Step 2: Summary Panel UI

```swift
// In HUDWindowController or separate SummaryPanelController
final class SummaryPanelController {
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private var bulletViews: [NSTextField] = []

    func setup(in containerView: NSView) {
        scrollView.documentView = stackView
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4

        // Add collapse button
        // Layout...
    }

    func updateBullets(_ bullets: [String]) {
        // Clear existing
        bulletViews.forEach { $0.removeFromSuperview() }
        bulletViews.removeAll()

        // Add new bullets
        for bullet in bullets {
            let bulletView = NSTextField(labelWithString: "• \(bullet)")
            bulletView.font = .systemFont(ofSize: 12)
            bulletView.textColor = .secondaryLabelColor
            bulletView.lineBreakMode = .byWordWrapping
            bulletView.maximumNumberOfLines = 2

            stackView.addArrangedSubview(bulletView)
            bulletViews.append(bulletView)
        }
    }

    func copyBullets() {
        let text = bulletViews.map { $0.stringValue }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
```

### Step 3: Integration with StreamingManager

```swift
// In StreamingManager
private let summarizer = ExtractiveSummarizer()
var onSummaryUpdated: (([String]) -> Void)?

func handleFinalizedSegment(_ segment: ASRFinalSegment) {
    // ... existing finalization logic ...

    // Update summary
    if AppSettings.shared.rollingSummariesEnabled {
        let bullets = summarizer.process(segment: segment)
        onSummaryUpdated?(bullets)
    }
}
```

### Step 4: Settings

```swift
extension AppSettings {
    var rollingSummariesEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "rollingSummariesEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "rollingSummariesEnabled") }
    }

    var summaryUpdateInterval: TimeInterval {
        // 5-30 seconds
        get { UserDefaults.standard.double(forKey: "summaryUpdateInterval").clamped(to: 5...30) }
        set { UserDefaults.standard.set(newValue, forKey: "summaryUpdateInterval") }
    }

    var maxSummaryBullets: Int {
        get { UserDefaults.standard.integer(forKey: "maxSummaryBullets").clamped(to: 3...10) }
        set { UserDefaults.standard.set(newValue, forKey: "maxSummaryBullets") }
    }
}
```

---

## 6. Future Enhancements

### Local LLM Summarization (S.03.1h-v2)
- Integrate llama.cpp for abstractive summaries
- Use small model (3B params) for speed
- Generate actual summaries, not just extraction

### Topic Segmentation
- Detect topic changes
- Group bullets by topic
- Show topic headers

---

## 7. Test Plan

### Unit Tests
- `ExtractiveSummarizerTests` - Sentence extraction, scoring
- Edge cases: very short text, single sentence
- Keyword extraction accuracy

### Manual Testing
- Long meeting recording, verify bullets are relevant
- Test with different content types (technical, casual)

---

## 8. Files Summary

### New Files
- `MacTalk/MacTalk/Utilities/ExtractiveSummarizer.swift`
- `MacTalk/MacTalk/UI/SummaryPanelController.swift`
- `MacTalk/MacTalkTests/ExtractiveSummarizerTests.swift`

### Modified Files
- `MacTalk/MacTalk/Whisper/StreamingManager.swift` - Summary integration
- `MacTalk/MacTalk/HUDWindowController.swift` - Summary panel placement
- `MacTalk/MacTalk/SettingsWindowController.swift` - Summary settings
