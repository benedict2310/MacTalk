# Product Requirements Document — MacTeach

**Product:** MacTalk  
**Feature:** History and Personal Vocabulary  
**Working name:** MacTeach  
**Version:** 1.0  
**Status:** Proposed  
**Last updated:** 2026-08-09  
**Target platform:** macOS 26.0 or later

---

## 1. Executive summary

MacTeach makes MacTalk improve when it gets a user's words wrong. It combines two
ideas that must be presented as one product feature:

1. **History** preserves enough local provenance for a user to inspect and correct
   a recent transcription.
2. **Personal Vocabulary** turns an explicit correction into durable knowledge
   that can influence recognition and, where appropriate, deterministically repair
   a known output.

The primary user promise is:

> Correct MacTalk once, and it should recognize that word correctly next time.

MacTeach is not a generic text-replacement utility and it must not silently learn
from everything the user types. A vocabulary entry can contain a preferred written
form, known misrecognitions, an optional spoken form, language, application scope,
and priority. MacTalk then uses the same entry in up to two safe ways:

- **Recognition hinting:** bias the selected ASR engine toward the intended term.
- **Deterministic correction:** replace a specific, repeatable misrecognition after
  ASR using scoped, whole-word or whole-phrase matching.

History is a prerequisite rather than an optional follow-up. Without raw output,
final output, session metadata, and an explicit correction action, MacTalk cannot
reliably distinguish a recognition error from a stylistic edit or typo.

---

## 2. Context and current state

MacTalk currently provides:

- Local Whisper and Parakeet transcription.
- Full-recording final inference.
- Incremental/final transcript reconciliation.
- Language selection and automatic language detection.
- Basic filler removal, punctuation spacing, sentence capitalization, and terminal
  punctuation.
- Clipboard output and optional insertion into the active application.
- Timestamp-aligned microphone and application-audio composition.
- Verified, revision-pinned model downloads and provider-specific engine lifecycles.

MacTalk does not currently provide:

- Transcription history.
- A personal vocabulary.
- An explicit correction workflow.
- Persistent wrong-form to written-form mappings.
- Whisper prompt-based vocabulary hints.
- Parakeet custom-vocabulary rescoring.
- Confidence-driven correction suggestions.
- Pronunciation or spoken-form training.

The existing `ASREngine` boundary is provider-neutral. Whisper and Parakeet state
must remain siloed: a shared vocabulary entry may be translated into separate
engine-specific request parameters, but one engine's decoder configuration must
never be reused by the other.

---

## 3. Product goals

### 3.1 Primary goals

1. Let users find and inspect recent transcripts without leaving MacTalk.
2. Let users correct a word or phrase from History in a few seconds.
3. Make a saved correction affect the current transcript immediately.
4. Improve future recognition of names, acronyms, product names, technical terms,
   and other specialized vocabulary.
5. Reliably fix repeatable misrecognitions regardless of the selected ASR engine.
6. Keep history, vocabulary, and correction processing local by default.
7. Make every learned entry visible, editable, disableable, and removable.
8. Preserve MacTalk's current transcription behavior when History or Personal
   Vocabulary is disabled.

### 3.2 Secondary goals

- Support import and export of vocabulary and correction pairs.
- Allow important terms to be prioritized.
- Allow vocabulary to be scoped by language and application.
- Provide the data model required for future pronunciation training, confidence-
  driven alternatives, and opt-in correction suggestions.
- Allow retained recordings to be reprocessed with another already-available
  engine or model.

### 3.3 Non-goals

- Silently monitoring edits made in other applications.
- Uploading transcripts, audio, vocabulary, or corrections to a service.
- General-purpose snippets or text-expansion macros in the first release.
- Team/shared dictionaries in the first release.
- Full Whisper or Parakeet fine-tuning on the user's device.
- Treating an arbitrary manual text edit as proof of an ASR error.
- Persisting audio by default.
- Automatically downloading another model when reprocessing a History item.

---

## 4. Product principles

### 4.1 One feature, multiple internal mechanisms

Users manage **Personal Vocabulary**, not separate “dictionary,” “replacement,”
and “training” products. Internally, MacTalk must retain the distinction between:

- recognition hints that influence decoding;
- exact replacements that run after decoding; and
- spoken-form or pronunciation information that may be consumed by a future
  acoustic-biasing implementation.

### 4.2 Explicit teaching over invisible learning

MacTalk may suggest a vocabulary entry after repeated explicit corrections, but it
must not create a permanent correction rule without confirmation. Every suggested
or learned entry must disclose its source.

### 4.3 Repair the transcript without changing its meaning

MacTeach is intended to correct recognition and formatting, not rewrite the user's
message. Deterministic corrections must be bounded and explainable. Future semantic
post-processing is outside this PRD.

### 4.4 Local, inspectable, and reversible

History and vocabulary live on the Mac. Users can inspect, export, disable, or
delete them. Removing an entry must stop both its recognition hint and its
replacement behavior immediately.

### 4.5 Quality must be measured, not assumed

Vocabulary prompting can over-bias a decoder. Each stage must be evaluated for
both improved recall and false-positive substitutions on a representative corpus.

---

## 5. Users and primary scenarios

### 5.1 People and product names

MacTalk produces “Mac Talk” when the user intended “MacTalk.” The user opens the
latest History item, selects “Mac Talk,” chooses **Teach MacTalk…**, enters
“MacTalk,” and saves. The visible transcript is repaired immediately. Future
recordings bias recognition toward “MacTalk” and still replace the known wrong
form if it appears.

### 5.2 Acronyms

MacTalk produces “a pie” or “A.P.I.” when the user intended “API.” The user creates
one entry with written form `API`, spoken form `A P I`, and multiple known wrong
forms. The written capitalization is preserved exactly.

### 5.3 Ambiguous homophones

MacTalk produces “flow” when a glaciologist intended “floe.” MacTalk must not offer
an unconditional global replacement by default. The user can create an application-
scoped or phrase-scoped entry, or enable recognition hinting without exact
replacement.

### 5.4 Code and identifiers

The user teaches identifiers such as `TimestampedAudioComposer`, `ASREngine`, or
`TCC`. The entry may be scoped to Xcode and related developer tools so it does not
distort general dictation.

### 5.5 Reprocessing a poor transcript

If the user opted to retain recordings, a History item can be reprocessed using a
different already-downloaded engine or model. The original result remains available
and the user explicitly chooses which result becomes the item's current output.

---

## 6. Scope and release phases

### Phase 0 — History foundation

- Local, bounded text history.
- History list and detail views.
- Raw, cleaned, and delivered text provenance.
- Copy, delete, delete all, search, and retention settings.
- Optional persisted audio, disabled by default.
- Latest-session in-memory audio for immediate correction.

### Phase 1 — Manual Personal Vocabulary

- Vocabulary list and entry editor.
- Written form, known wrong forms, language, application scope, priority, and
  enabled state.
- Deterministic replacement engine.
- Import and export.
- Apply a saved correction to the current History item.

### Phase 2 — Teach from History and Whisper hinting

- **Teach MacTalk…** from a selected range or History item.
- Correction events linked to their History provenance.
- Whisper `initial_prompt` integration with a bounded, ranked hint set.
- “Correct last transcription” command and configurable shortcut.

### Phase 3 — Parakeet vocabulary integration

- FluidAudio custom-vocabulary/CTC rescoring integration.
- Verified CTC model provenance and download flow where required.
- Provider-specific thresholds and false-positive safeguards.

### Phase 4 — Suggestions and advanced correction

- Confirm-before-save suggestions after repeated explicit corrections.
- Confidence-backed alternative hypotheses when engine data is available.
- Optional pronunciation recording only when a production recognition path can
  consume it; do not ship a decorative recording control.

---

## 7. User experience requirements

### 7.1 Navigation

Add two peer menu items to the MacTalk menu:

- **History…**
- **Personal Vocabulary…**

History is also opened by the post-transcription notification or HUD action when
available. Personal Vocabulary can be opened from a correction sheet or Settings.

### 7.2 History window

The History window contains:

- A searchable, newest-first list.
- Date/time, short transcript preview, provider, language, duration, and source-app
  icon/name when available.
- Filters for provider, language, source application, and corrected/uncorrected.
- A detail view with:
  - current delivered text;
  - raw engine text;
  - cleaned text;
  - corrections applied;
  - provider, model identity, language, capture mode, and timings;
  - retained-audio availability;
  - Copy, Teach MacTalk, Reprocess, Export, and Delete actions.

Raw and intermediate text are collapsed by default. The user-facing current output
must remain visually primary.

### 7.3 Teach MacTalk flow

The correction sheet contains:

| Field | Behavior |
|---|---|
| MacTalk heard | Pre-filled with the selected or inferred wrong phrase |
| I meant | Required preferred written form |
| Spoken form | Optional text such as “A P I”; advanced disclosure |
| Improve recognition | Enabled by default for uncommon terms |
| Always replace | Enabled when a stable wrong form is present |
| Language | Defaults to the recording language |
| Use in | Everywhere or selected applications |
| Priority | Normal or Important |

On Save:

1. Validate and resolve conflicts.
2. Create or update a Personal Vocabulary entry.
3. Record a correction event linked to the History item.
4. Re-run deterministic corrections for that History item.
5. Update its current output and show an Undo action.
6. Make the entry available to the next ASR request without restarting an engine
   unless the provider API strictly requires it.

If no range is selected, MacTalk should propose the lowest-confidence phrase when
available. Otherwise, it preselects the final word or asks the user to select text.

### 7.4 Correct-last shortcut

Provide a command named **Correct Last Transcription…**. It opens the newest History
item and focuses its correction selection. The default shortcut must not conflict
with the existing start/stop shortcut and must be configurable through the existing
shortcut infrastructure.

Voice-triggered “correct that” is a future enhancement, not part of the initial
release.

### 7.5 Personal Vocabulary window

The window supports:

- Search across written form, spoken form, and wrong forms.
- Filters for language, application scope, source, enabled state, and priority.
- Sorting by priority, most recently modified, most used, and alphabetical.
- Add, edit, duplicate, enable/disable, and delete.
- Clear indication of entry source:
  - manually added;
  - taught from correction;
  - suggested;
  - imported.
- Usage count and last-applied date.
- Import and export as UTF-8 CSV.

Suggested entries display a visible badge and require acceptance before they affect
recognition or output.

### 7.6 Accessibility

- Every action must be keyboard accessible.
- VoiceOver must announce the heard form, intended form, scope, enabled state, and
  conflict state.
- Do not communicate source or priority using color alone.
- Text differences must have a non-color representation.
- Destructive operations require confirmation and return focus predictably.

---

## 8. Functional requirements — History

### HIST-001: Exactly one terminal record

A successfully finalized, non-empty recording session creates exactly one History
record. Incremental partials must not create separate records. A cancelled or empty
session creates no record.

### HIST-002: Preserve pipeline provenance

History must distinguish:

1. `rawASRText` — the engine's final text before cleanup;
2. `cleanedText` — output after the existing `TranscriptCleaner`;
3. `deliveredText` — text after Personal Vocabulary replacements and any future
   approved output stages;
4. `correctedText` — optional user-approved correction of the delivered text.

The effective current text is `correctedText ?? deliveredText`.

### HIST-003: Session metadata

Store only the metadata required for product behavior and debugging:

- record and session UUIDs;
- creation and completion timestamps;
- provider;
- model ID and immutable model revision;
- requested and detected language when available;
- capture mode;
- duration and inference timing;
- source application bundle identifier and display name when available;
- whether automatic insertion succeeded;
- whether retained audio exists;
- schema version.

Do not store captured surrounding text, clipboard contents, window titles, contact
data, or screen content.

### HIST-004: Retention defaults

- Text history is enabled by default.
- Default retention is 30 days or 500 records, whichever bound is reached first.
- Available policies: Off, 1 day, 7 days, 30 days, 90 days, and Forever.
- Persisted audio is disabled by default and has a separate retention policy.
- Changing to a shorter policy begins asynchronous pruning immediately.
- Turning History off offers to delete existing history but does not delete without
  confirmation.

### HIST-005: Audio retention

- The completed recording may remain in memory for up to 15 minutes or until the
  next recording starts, enabling immediate correction without a persisted file.
- Persisted audio requires an explicit **Keep recordings in History** setting.
- Persisted audio uses a compressed, lossless-or-high-quality format suitable for
  reprocessing; the implementation must validate that decoding produces 16 kHz mono
  Float32 input equivalent to the live pipeline.
- Audio files are referenced by opaque record UUID, never transcript content.
- Deleting a record deletes its audio in the same logical operation, with orphan
  cleanup on next launch after interrupted deletion.

### HIST-006: Reprocessing

- Reprocess is enabled only when retained audio exists.
- The user selects an installed provider/model and language.
- Missing models produce an explicit download requirement; reprocessing never starts
  a download silently.
- The original transcription remains immutable as provenance.
- The reprocessed candidate is stored separately until the user chooses **Use this
  result**.
- Reprocessing must use the vocabulary snapshot effective at reprocess time and
  record that fact.

### HIST-007: Storage and threading

- No history or audio file I/O may occur on an audio render callback.
- Writes occur after final output is established and are serialized by a dedicated
  actor or equivalent single-owner boundary.
- A History write failure must not suppress clipboard or insertion output.
- The UI reflects pending persistence without presenting an uncommitted record as
  durable.

### HIST-008: Search and export

- Search is case- and diacritic-insensitive across current transcript text and
  vocabulary correction metadata.
- A History item can be exported as plain text or JSON metadata.
- Audio is exported only through an explicit separate action.
- Bulk History export is out of scope for the first release.

---

## 9. Functional requirements — Personal Vocabulary

### VOC-001: Entry model

Each entry contains:

- stable UUID;
- preferred written form;
- zero or one spoken-form text value;
- zero or more known wrong forms;
- language or language-independent designation;
- application scope;
- Normal or Important priority;
- recognition-hint enabled flag;
- deterministic-replacement enabled flag;
- enabled/disabled state;
- source and source History record when applicable;
- creation and modification timestamps;
- application count and last-applied timestamp;
- schema version.

Wrong forms are separate child records so one preferred form can repair multiple
misrecognitions.

### VOC-002: Validation

- Written form must be non-empty after trimming.
- Entries and wrong forms must be valid Unicode and bounded in length.
- A wrong form cannot normalize to its own written form.
- Duplicate written-form/language/scope combinations update or merge after user
  confirmation rather than creating invisible duplicates.
- Conflicting wrong forms must be rejected or require the user to choose precedence.
- Control characters are rejected except intentional line breaks in a future snippet
  feature.

### VOC-003: Deterministic replacement semantics

The replacement engine must:

- match complete Unicode-aware words or complete phrases;
- never replace a substring inside another word;
- prefer the longest matching phrase;
- perform one non-recursive pass so replacements cannot cascade;
- apply language and application scope before matching;
- write the preferred form with its configured capitalization;
- preserve surrounding whitespace and punctuation;
- be deterministic across app launches and ASR providers;
- return a structured list of applied edits for History and Undo.

Case-insensitive matching is the default. A future advanced option may enable exact-
case matching if a demonstrated use case requires it.

### VOC-004: Recognition-hint selection

Do not send the entire vocabulary to an engine. Build a bounded hint set for each
recording using, in order:

1. matching language;
2. matching application scope;
3. Important priority;
4. recent successful application;
5. correction frequency;
6. recency of modification;
7. compact token cost.

The selector must enforce provider-specific count and token budgets. For Whisper,
the prompt must remain within the supported initial-prompt budget and leave space
for normal previous-text conditioning. The exact limit is derived from the loaded
model/context rather than hard-coded where the native API exposes it.

### VOC-005: Whisper integration

- Extend the native bridge to accept an optional UTF-8 initial prompt or prompt
  tokens owned for the full duration of `whisper_full`.
- Generate a compact, language-appropriate prompt containing only selected terms.
- Do not indiscriminately enable `carry_initial_prompt`; benchmark first because it
  can reduce the effectiveness of previous-text conditioning.
- Use the same vocabulary snapshot for one recording session.
- Record prompt/hint identifiers in developer diagnostics, never the term text.
- Preserve current behavior when no hints are selected.

### VOC-006: Parakeet integration

- Adapt selected generic vocabulary hints into FluidAudio's provider-specific custom-
  vocabulary configuration.
- Use the custom CTC vocabulary/keyword rescoring supported by the pinned FluidAudio
  release only after a real-model accuracy and false-positive gate passes.
- Any additional CTC model becomes a first-class verified artifact with immutable
  revision, SHA-256, bounded download, staging, and publication rules consistent with
  existing model security architecture.
- Per-term thresholds and acoustic rescue controls remain Parakeet-owned settings and
  must never appear in Whisper state.
- If Parakeet vocabulary resources are unavailable, deterministic replacements still
  apply and recognition hinting reports unavailable rather than failing transcription.

### VOC-007: Session snapshot

Capture a vocabulary snapshot when recording begins. Editing vocabulary during an
active session affects the next session, matching existing settings snapshot behavior.
Replacements for the terminal result use the same snapshot unless the user explicitly
applies a newly saved correction from History afterward.

### VOC-008: Import and export

- CSV encoding is UTF-8 with a versioned header.
- Required column: `written_form`.
- Optional columns: `wrong_form`, `spoken_form`, `language`, `bundle_id`, `priority`,
  `recognition_hint`, and `replacement`.
- Multiple rows may share a written form to express multiple wrong forms.
- Import includes preview, validation errors, duplicate/conflict counts, and explicit
  confirmation.
- Export contains vocabulary only, never History text or audio.

### VOC-009: Deletion and disabling

- Disabling an entry preserves it but removes it from hint selection and replacement.
- Deleting an entry removes its active behavior immediately.
- Historical correction events retain the written forms needed to explain past
  output, but no longer link to a live entry.

---

## 10. Functional requirements — Teaching and suggestions

### TEACH-001: Explicit correction event

A correction event records:

- History record ID;
- wrong text and intended text;
- ranges against the exact source-text version;
- limited surrounding-token context required to replay the edit;
- language and application scope chosen by the user;
- linked vocabulary entry ID;
- timestamp;
- whether the entry was created, merged, or updated.

Correction events must not store unrelated document context.

### TEACH-002: Range stability

Store edits using both source ranges and the source-text version/hash. If the History
text changed, re-locate only an unambiguous whole phrase. Otherwise, ask the user to
select again rather than modifying the wrong occurrence.

### TEACH-003: Immediate repair and Undo

- Saving an entry recomputes the current History output from its immutable pipeline
  source, not by repeatedly mutating already-replaced text.
- Undo restores the previous vocabulary state and History text during the current UI
  session.
- A later reversal is performed by editing or deleting the vocabulary entry.

### TEACH-004: Suggested learning

After at least two identical explicit corrections, MacTalk may suggest creating or
strengthening an entry. Suggestions must:

- exclude common words unless app- or phrase-scoped;
- never activate without confirmation;
- show the supporting correction count;
- be dismissible permanently for that candidate;
- expire when supporting History records age out without deleting an accepted entry;
- avoid proposing sensitive surrounding text.

### TEACH-005: Alternatives

When structured engine alternatives or word confidence are available, the correction
sheet may show a short ranked list. Choosing an alternative remains an explicit
correction event. MacTalk must not fabricate alternatives using an unrelated language
model in this feature.

---

## 11. Data architecture

### 11.1 Recommended persistence approach

Use a versioned SQLite store owned by a dedicated actor, using the system SQLite
library to avoid a new third-party dependency. Store optional audio as files in a
private application-support subdirectory and reference them by UUID.

Recommended location:

```text
~/Library/Application Support/MacTalk/
├── MacTeach.sqlite
└── HistoryAudio/
    └── <record-uuid>.<extension>
```

The database should use WAL mode, foreign keys, explicit transactions, and ordered
schema migrations. Database access must be abstracted behind protocols so tests can
use temporary stores.

### 11.2 Logical schema

```text
history_records
  id, session_id, created_at, completed_at
  provider, model_id, model_revision
  requested_language, detected_language, capture_mode
  source_bundle_id, source_display_name
  raw_asr_text, cleaned_text, delivered_text, corrected_text
  duration_ms, inference_ms, insertion_succeeded
  audio_file_id, schema_version

history_candidates
  id, history_record_id, provider, model_id, language
  text, created_at, vocabulary_snapshot_id, selected

vocabulary_entries
  id, written_form, spoken_form, language
  priority, hint_enabled, replacement_enabled, enabled
  source, source_history_id
  created_at, updated_at, application_count, last_applied_at
  schema_version

vocabulary_wrong_forms
  id, vocabulary_entry_id, wrong_form, normalized_form

vocabulary_app_scopes
  vocabulary_entry_id, bundle_id

correction_events
  id, history_record_id, vocabulary_entry_id
  source_text_version, wrong_text, intended_text
  range_location, range_length, limited_context
  created_at, operation

dismissed_suggestions
  normalized_wrong_form, normalized_written_form, language, scope_hash
```

This is a logical model; migrations may adjust physical columns and indexes.

### 11.3 Ownership boundaries

- `HistoryStore` owns History persistence, retention, search, candidates, and audio
  lifecycle.
- `PersonalVocabularyStore` owns entries, conflicts, import/export, and snapshots.
- `VocabularyReplacementEngine` is a pure, deterministic transformation.
- `VocabularyHintSelector` is a pure ranking and budget component.
- `MacTeachCoordinator` owns UI intents and cross-store transactions.
- `TranscriptionController` emits structured terminal results but does not query UI
  state or manage History screens.
- Engine adapters consume an immutable provider-neutral vocabulary snapshot and map
  it to provider-specific parameters.

Avoid making `StatusBarController` the direct persistence owner. Compose a focused
coordinator consistent with the current status-bar coordinator architecture.

### 11.4 Proposed ASR boundary evolution

Introduce immutable request context rather than adding unrelated positional
parameters:

```swift
struct ASRRequestContext: Sendable {
    let language: String?
    let vocabularyHints: [ASRVocabularyHint]
    let vocabularySnapshotID: UUID?
}

struct ASRVocabularyHint: Sendable, Equatable {
    let id: UUID
    let writtenForm: String
    let spokenForm: String?
    let priority: ASRVocabularyPriority
}
```

The exact public API may differ after red-phase tests, but it must remain immutable,
provider-neutral, and session-scoped. Parakeet thresholds, CTC state, Whisper prompt
tokens, and similar details stay inside their engine adapters.

### 11.5 Pipeline order

The terminal text pipeline becomes:

```text
ASR final result
  → rawASRText
  → existing TranscriptCleaner
  → cleanedText
  → VocabularyReplacementEngine
  → deliveredText
  → clipboard / insertion
  → History persistence
  → optional later explicit correctedText
```

If History persistence fails, delivery still succeeds. If replacement fails safely,
the unchanged cleaned text is delivered and the failure is privacy-safely logged.

---

## 12. Privacy and security

### 12.1 Defaults

- Transcripts and vocabulary remain local.
- Text History is on with bounded retention.
- Persisted recordings are off.
- No captured app context is stored.
- No analytics event contains transcript, wrong-form, written-form, spoken-form, or
  audio content.

### 12.2 Filesystem controls

- Create MacTeach storage directories with user-only permissions.
- Use explicit, validated application-support paths.
- Never derive paths from transcript or vocabulary content.
- Mark optional audio files as excluded from unnecessary backup if consistent with
  product backup expectations.
- Do not claim application-level encryption; users may rely on FileVault unless a
  future threat model requires separate encryption.

### 12.3 Logging

Allowed diagnostic fields include record ID, provider, model ID, counts, durations,
entry IDs, hint counts, token budget, and result status. Text and audio are forbidden
in production logs. Extend the existing privacy logging tests to cover every new
MacTeach type.

### 12.4 Deletion

- Per-record, per-entry, all-History, all-audio, and all-vocabulary deletion are
  independently available.
- Material deletion must remove database content and associated audio files.
- Interrupted deletion is resumed or reconciled on next launch.
- Import never overwrites existing entries without preview and confirmation.

---

## 13. Settings

Add a **History & Vocabulary** settings section:

| Setting | Default |
|---|---|
| Save text history | On |
| Text retention | 30 days / maximum 500 records |
| Keep recordings in History | Off |
| Audio retention | 7 days when enabled |
| Personal Vocabulary | On |
| Suggest words after repeated corrections | On |
| Correct-last shortcut | Unassigned or conflict-free default |

Settings are owned by `AppSettings` and included in its synchronized snapshot where
recording behavior depends on them. Retention changes may act immediately and do not
need to wait for the next recording.

---

## 14. Performance and reliability targets

- No MacTeach work on real-time audio callbacks.
- Create a text-only History record within 100 ms after terminal output without
  delaying clipboard or insertion completion.
- Apply deterministic replacements to a typical transcript in under 20 ms with
  1,000 enabled entries on supported hardware.
- Build engine hints in under 10 ms for 1,000 entries.
- History search should return the first page within 100 ms for 10,000 records.
- Storage remains bounded according to retention settings.
- A corrupt optional audio file must not make its History text unreadable.
- Database migration failure must preserve the original store and present a
  recoverable error; it must not silently reset user data.
- One recording creates no more than one terminal History record even when final
  callbacks race with stop or engine replacement.

---

## 15. Quality measurement

Before enabling recognition hinting in production, build a local, consented quality
corpus with:

- ordinary dictation;
- proper nouns;
- acronyms and technical vocabulary;
- singular and plural forms;
- similar-sounding distractors;
- multiple supported languages;
- quiet speech and common background noise;
- app-scoped terminology.

Measure:

- overall word error rate;
- keyterm recall;
- keyterm precision and false-positive rate;
- exact written-form accuracy;
- replacement precision;
- regression rate on utterances without keyterms;
- finalization latency;
- hint-building latency.

An improvement in keyterm recall is not sufficient if false-positive substitutions
or general WER regress materially. Provider-specific launch gates must be recorded in
the implementation story.

---

## 16. Red/green TDD and verification requirements

Every implementation slice follows red/green TDD. Tests are committed alongside the
smallest production change that makes them pass.

### 16.1 History tests

- Exactly one record for a successful session.
- No record for empty or cancelled sessions.
- Raw, cleaned, delivered, and corrected stages remain distinct.
- Store migrations preserve records and vocabulary.
- Retention prunes the correct records and associated audio.
- Interrupted audio deletion is reconciled.
- Search respects Unicode, case, and diacritics.
- History failure does not suppress output.
- Reprocessing preserves the original result.

### 16.2 Replacement tests

- Whole-word and whole-phrase matching.
- No substring replacement (`cat` must not alter `caterpillar`).
- Longest match wins.
- No recursive/cascading replacements.
- Exact preferred capitalization.
- Unicode and punctuation boundaries.
- Language and application scoping.
- Conflict detection and deterministic precedence.
- Disable and delete take effect immediately.
- Recomputing from immutable source is idempotent.

### 16.3 Hint-selection tests

- Language and app scope filtering.
- Important entries outrank ordinary entries.
- Stable deterministic ordering.
- Provider token/count budgets are never exceeded.
- Disabled and replacement-only entries are excluded.
- Session snapshot does not change during recording.
- No raw term text enters production diagnostics.

### 16.4 Engine tests

- Whisper bridge preserves no-prompt behavior.
- Whisper prompt lifetime is valid through native inference.
- UTF-8 prompts are handled correctly.
- Parakeet configuration remains provider-specific.
- Missing Parakeet vocabulary resources degrade to ordinary transcription.
- Real-model lanes measure keyterm recall and false positives when models are
  provisioned; deterministic lanes never download a model.

### 16.5 UI and accessibility tests

- Teach sheet is correctly pre-filled.
- Save, conflict, Undo, delete, and disable flows.
- Correct-last targets the newest eligible History item.
- Keyboard and VoiceOver labels.
- Audio-disabled and model-unavailable reprocessing states.
- Destructive confirmation and focus restoration.

### 16.6 Required verification after implementation changes

- Run focused tests during each red/green cycle and the complete deterministic
  unit lane before merging production changes.
- Run the TSan-compatible lane for concurrency-sensitive storage and session
  changes; it is not required for documentation, test-only, or routine UI work.
- Run `./build.sh run` once for a coherent runtime batch when manual app
  validation is needed; documentation, test-only, and CI-only edits do not
  require app restart.
- Run the real-model quality lane when vocabulary hinting changes.
- Follow the lifecycle-contract, review, worker-budget, and validation rules in
  [`AGENT_WORKFLOW.md`](../development/AGENT_WORKFLOW.md).

---

## 17. Acceptance criteria

MacTeach 1.0 is complete when:

1. A finalized transcript appears exactly once in local History.
2. The user can select a wrong phrase, teach the intended phrase, and immediately
   see the current History output repaired.
3. The correction creates or updates one visible Personal Vocabulary entry.
4. A known wrong form is corrected identically under Whisper and Parakeet.
5. Whole-word matching prevents substring corruption.
6. Whisper receives a bounded vocabulary prompt selected from the session snapshot.
7. Vocabulary changes during a recording affect only the next recording.
8. History text is bounded by the configured retention policy.
9. Audio is never persisted unless the user explicitly enables it.
10. The user can delete one record, all History, one vocabulary entry, or all
    vocabulary data.
11. Production logs contain no transcript, vocabulary, correction, app-context, or
    audio content.
12. All required deterministic, concurrency, migration, privacy, and accessibility
    tests pass.

Parakeet decoder-time vocabulary support may ship in the next minor release if its
additional verified model and quality gate are not ready. Deterministic correction
must still work for Parakeet in MacTeach 1.0.

---

## 18. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Excess vocabulary degrades recognition | Ranked bounded hints; measure false positives |
| A bad rule corrupts unrelated words | Whole phrase boundaries, app/language scope, confirmation, Undo |
| Silent learning stores mistakes | Explicit acceptance; visible source badges; reversible entries |
| History creates a privacy surprise | Clear onboarding, bounded text retention, audio off by default |
| Audio storage grows without bound | Independent retention, size accounting, orphan cleanup |
| Database failure blocks dictation | Async persistence; output succeeds independently |
| Engine settings become mixed | Provider-neutral snapshot plus provider-owned adapters |
| Model update changes hint behavior | Provider/model-specific quality gates and regression corpus |
| User expects pronunciation recording to train ASR | Do not expose recording until a real consuming path exists |
| Reprocessing silently downloads large models | Require installed model or explicit download workflow |

---

## 19. Implementation map

Expected new components; exact names may change during implementation:

```text
MacTalk/MacTalk/History/
  HistoryRecord.swift
  HistoryStore.swift
  HistoryRetentionPolicy.swift
  HistoryWindowController.swift
  HistoryViewModel.swift

MacTalk/MacTalk/Vocabulary/
  PersonalVocabularyEntry.swift
  PersonalVocabularyStore.swift
  VocabularyReplacementEngine.swift
  VocabularyHintSelector.swift
  VocabularyImportExport.swift
  PersonalVocabularyWindowController.swift

MacTalk/MacTalk/StatusBar/
  MacTeachCoordinator.swift

MacTalk/MacTalk/Audio/
  ASRRequestContext.swift

MacTalk/MacTalkTests/
  HistoryStoreTests.swift
  HistoryRetentionTests.swift
  PersonalVocabularyStoreTests.swift
  VocabularyReplacementEngineTests.swift
  VocabularyHintSelectorTests.swift
  MacTeachCoordinatorTests.swift
  MacTeachPrivacyTests.swift
```

Expected existing integration points:

- `TranscriptionController.swift` — emit structured terminal pipeline stages.
- `ASREngine.swift` — accept immutable request context and preserve structured words.
- `NativeWhisperEngine.swift` and `WhisperBridge.h/.mm` — prompt integration.
- `ParakeetEngine.swift` — provider-owned custom-vocabulary adapter.
- `AppSettings.swift` — History, audio retention, vocabulary, and shortcut settings.
- `StatusBarController.swift` and status-bar coordinators — composition and menu effects.
- `SettingsWindowController.swift` — settings surfaces.
- `GeneratedModelProvenance.swift` and model provenance tooling — any new Parakeet
  CTC artifact.
- `project.yml` — only if generated source discovery requires explicit additions;
  regenerate the Xcode project rather than editing it manually.

---

## 20. Inspiration and rationale

- [Wispr Flow dictionary](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary)
  combines recognition boosting, explicit misspelling correction, filtered auto-add,
  priority, source badges, and CSV import in one vocabulary product.
- [Dragon correction](https://www.nuance.com/products/help/dragon/dragon-for-mac/enx/content/Correction/CorrectionMenu.html)
  keeps correction close to the original utterance, offers alternatives, and saves
  confirmed learning into a user profile.
- [Dragon Vocabulary Editor](https://www.nuance.com/products/help/dragon/dragon-for-pc/enx/dps/main/Content/DialogBoxes/vocs/voc_editor_dlg.htm)
  distinguishes written and spoken forms.
- [Superwhisper vocabulary](https://superwhisper.com/docs/get-started/interface-vocabulary)
  keeps recognition hints and deterministic replacements in one interface while
  preserving their different behavior.
- [Apple custom vocabulary](https://support.apple.com/en-ie/guide/mac-help/mchl3eb7b79a/mac)
  demonstrates language-specific lists, selection-based addition, import/export,
  and optional recorded pronunciation in a native macOS interaction model.

MacTeach should combine Wispr Flow's unified product model, Dragon's explicit
correction loop, Superwhisper's separation of decoder hints from exact replacements,
and Apple's Mac-native vocabulary management—while preserving MacTalk's stronger
local-first and verified-model boundaries.

---

## 21. Decisions and follow-up questions

Decisions made by this PRD:

- History is a prerequisite and ships before Teach-from-History.
- Text History defaults on with bounded retention.
- Persisted audio defaults off.
- Personal Vocabulary and correction are one product feature.
- Automatic learning always requires confirmation.
- Exact replacement ships for both engines before provider-specific decoder bias is
  considered complete.
- App and language scope are first-class rather than retrofitted later.

Questions to validate during design and implementation planning:

1. Should the correct-last command receive a default shortcut or remain unassigned?
2. Is 30 days / 500 records the right default after usability testing?
3. Which compressed audio format best preserves reprocessing parity and reasonable
   storage size on supported macOS versions?
4. Should a source application name be retained when its bundle identifier is no
   longer installed?
5. What measured Parakeet threshold and CTC model size pass the product quality gate?
