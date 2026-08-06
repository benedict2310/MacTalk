# Parakeet Source-Loader Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` or `executing-plans` task-by-task.

**Goal:** Atomically replace production compiled-path Parakeet loading with verified source snapshots and in-memory CoreML assets.

**Architecture:** `ParakeetBootstrap` becomes the single composition root for source preparation, snapshot verification, and `VerifiedParakeetModelLoader`. Bootstrap state retains `VerifiedParakeetLoadedModels`, so immutable snapshot bytes and CoreML assets outlive `AsrManager`. A monotonically increasing bootstrap generation owns publication; obsolete operations may finish but cannot replace a newer manager.

**Tech Stack:** Swift 6, XCTest, CoreML, FluidAudio, generated Parakeet provenance.

---

### Task 1: Characterize the cutover boundary

**Files:**
- Modify: `MacTalk/MacTalkTests/ParakeetSourceArtifactMaterializerTests.swift`
- Modify: `MacTalk/MacTalkTests/ParakeetDownloadTransportTests.swift`

- [ ] **Step 1: Write failing static rules**

Replace Task 10's inactive-wiring assertions with tests that read `ParakeetBootstrap.swift` and require `ParakeetSourcePreparer`, `VerifiedParakeetSourceSnapshotProvider`, and `VerifiedParakeetModelLoader`, while rejecting `AsrModels.load(from:)`, `ModelHub.loadModels`, `MLModel(contentsOf:)`, and `MLModelAsset(url:)`.

- [ ] **Step 2: Run the focused tests red**

Run:
```bash
xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk -destination 'platform=macOS,arch=arm64' -only-testing:MacTalkTests/ParakeetSourceArtifactMaterializerTests -only-testing:MacTalkTests/ParakeetDownloadTransportTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```
Expected: failure because bootstrap still calls `AsrModels.load(from:)`.

- [ ] **Step 3: Commit the characterization**
```bash
git add MacTalk/MacTalkTests/ParakeetSourceArtifactMaterializerTests.swift MacTalk/MacTalkTests/ParakeetDownloadTransportTests.swift
git commit -m 'test: specify source loader cutover'
```

### Task 2: Add injectable source-bootstrap composition and generation ownership

**Files:**
- Modify: `MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift`
- Create: `MacTalk/MacTalkTests/ParakeetBootstrapTests.swift`

- [ ] **Step 1: Write failing hermetic tests**

Introduce injected test doubles for preparation, snapshot provision, and model loading. Verify one successful `ensureReady()` publishes the exact loader result, retains it in bootstrap state, and returns its `AsrManager`. Start operation A, block it immediately before publication, start newer operation B, release A, and assert only B is retained/published.

- [ ] **Step 2: Run tests red**

Run:
```bash
xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk -destination 'platform=macOS,arch=arm64' -only-testing:MacTalkTests/ParakeetBootstrapTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```
Expected: compile/test failure because dependencies and generation ownership do not exist.

- [ ] **Step 3: Implement the minimal composition**

Add an internal initializer accepting a source preparer factory, snapshot provider factory, model loader, and post-load cleanup collaborator. `loadManager()` must: prepare canonical source, make a verified snapshot, load it through `VerifiedParakeetModelLoader`, and retain the complete `VerifiedParakeetLoadedModels` with the manager. Increment generation before each replacement operation; publish only if the completing generation still owns state. Production construction uses `ParakeetSourceStore.canonical(parent: ParakeetModelDownloader.modelsDirectory)` and pinned generated provenance.

- [ ] **Step 4: Run focused tests green and commit**
```bash
xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk -destination 'platform=macOS,arch=arm64' -only-testing:MacTalkTests/ParakeetBootstrapTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
git add MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift MacTalk/MacTalkTests/ParakeetBootstrapTests.swift
git commit -m 'feat: load Parakeet from verified source snapshots'
```

### Task 3: Delete compiled storage only after verified source load

**Files:**
- Modify: `MacTalk/MacTalk/Whisper/ParakeetModelDownloader.swift`
- Modify: `MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift`
- Modify: `MacTalk/MacTalkTests/ParakeetBootstrapTests.swift`

- [ ] **Step 1: Write failing tests**

Use a temporary root and injected cleanup collaborator. Assert cleanup is not called when source preparation, snapshot verification, or byte-model loading fails; assert it is called once only after a verified manager is successfully published; assert failed cleanup does not discard the already-ready source manager or source retry material.

- [ ] **Step 2: Implement descriptor-safe legacy cleanup**

Expose one narrowly named compiled-generation cleanup operation on `ParakeetModelDownloader`. It must acquire the store's exclusive lock, validate the exact compiled directory name, reject unexpected link/non-directory targets, and remove only the compiled active generation after successful source publication. Treat cleanup failure as non-fatal telemetry/state detail, never as permission to use compiled path loading.

- [ ] **Step 3: Run focused tests and commit**
```bash
xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk -destination 'platform=macOS,arch=arm64' -only-testing:MacTalkTests/ParakeetBootstrapTests -only-testing:MacTalkTests/ParakeetDownloadTransportTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
git add MacTalk/MacTalk/Whisper/ParakeetModelDownloader.swift MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift MacTalk/MacTalkTests/ParakeetBootstrapTests.swift
git commit -m 'feat: retire compiled Parakeet generation after source load'
```

### Task 4: Integrate and close

- [ ] Run source/static/bootstrap suites, `./scripts/test-lanes.sh repeat`, full unsigned XCTest, XcodeGen drift check, `git diff --check`, and `./build.sh run`.
- [ ] Obtain fresh specification, quality, and security reviews; remediate every actionable finding and re-review.
- [ ] Record commits, test output, review artifacts, and any external hardware/TCC limits in `TODO-889521ac`; close only after all gates pass.
