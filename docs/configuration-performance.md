# Configuration performance review

Reviewed September 5, 2026. Tracking: [Performance Improvements](https://plane.wallingford.me/dev/projects/4240f444-584f-42a3-adf9-2c486a4d8f55/modules/fdeb88b3-fd4a-4d06-97de-79d930a87c1a).

## Findings and implementation

The local archive contained 654 transcripts in 259 KB of JSON, with 68 KB of statistics. These aggregate measurements did not require exposing transcript contents. History constructed every card eagerly, repeatedly formatted full text, and observed playback updates throughout the list at 10 Hz. Persistence also decoded and rewrote the whole archive on the main actor. Audio files were not read during initial history browsing.

| Plane work | Change |
| --- | --- |
| SPEAKTYPE-1 | SQLite history store, transactional legacy migration, background queries and ordered writes, newest 50 transcripts in the shared facade, flush on quit |
| SPEAKTYPE-2 | Lazy 50-entry pages, debounced substring search, bounded previews, quick Copy, isolated expanded playback, visible errors and responsive actions |
| SPEAKTYPE-3 | Lazy inactive CoreML service, background model inventory, exact app-owned deletion with confirmation, deterministic model fallback and row timer cleanup |
| SPEAKTYPE-4 | Cached calendar-aware statistics summaries, stable chart IDs, bounded Dashboard previews, no model preload merely opening Dashboard |
| SPEAKTYPE-5 | Separate General and Transcription settings, remembered tab, visible engine-switch feedback |

The history database lives at `~/Library/Application Support/SpeakType/history.sqlite`. SQLite WAL transactions make each mutation durable before it appears in the UI. The legacy JSON remains in UserDefaults as a recovery copy. A migration marker prevents cleared/deleted records from being imported again. Migration preserves transcript contents, IDs, dates, audio paths, model and language metadata. Deleting transcripts preserves historical statistics; Clear All also preserves saved audio, as before.

Date/ID ordering is indexed. Search is case- and diacritic-insensitive literal substring matching in SQLite; it scans search text on the database actor, then decodes only the returned page. The lightweight statistics array remains in memory for compatibility and is updated incrementally; views build compact summaries off-main once per revision/calendar change. These choices bound transcript decoding and layout without claiming constant-time search or constant memory for statistics.

## Research informing the ergonomics

[Superwhisper History](https://superwhisper.com/docs/get-started/interface-history) documents search and reprocessing from the history panel. [Wispr Flow history actions](https://docs.wisprflow.ai/articles/4465314211-delete-transcripts-and-history-in-wispr-flow) emphasize quick copy and explicit deletion behavior. SpeakType adopts search, direct copy, and clear action feedback while retaining its local storage and existing deletion semantics.

The initial batch merged in [PR #41](https://github.com/mggarofalo/speaktype/pull/41). Its signed Release build was installed and relaunched on September 5; the installed executable matched the built executable and retained the SpeakType Local Dev signature.

## Follow-up implementation

| Plane work | Change |
| --- | --- |
| SPEAKTYPE-6 | Checks paginated GitHub repository tags, selects the newest stable semantic version, and shows success/failure in Settings. A single reusable update window links to the tagged source and explains manual installation. Automatic checks remain opt-in; skip/reminder preferences are preserved. |
| SPEAKTYPE-7 | Search languages by name or code in a popover, navigate results with arrow keys, select with Return and dismiss with Escape. Current selection, recents, auto-detect, per-model preferences and English-only restrictions are preserved. |
| SPEAKTYPE-8 | Register complete transcription operations before scheduling them; on quit finalize active capture, await transcription and save enqueueing, flush history, then free the engine. Reject new input during termination and prevent simultaneous file import and microphone capture in the file transcription screen. |

The update implementation follows GitHub’s [repository tags endpoint](https://docs.github.com/en/rest/repos/repos#list-repository-tags), including page-based retrieval with up to 100 tags per request.

The shutdown coordinator uses asynchronous AppKit termination and has no forced five-second exit. It can wait for a long decode to finish. If history reports an error, termination is cancelled and an alert keeps the app open. It does not guarantee recovery from all storage failures: existing HistoryService behavior discards failed mutations and clears earlier errors after a later successful write. **SPEAKTYPE-9** tracks retained failed writes, retry ordering and recovery separately.

The follow-up batch passed a signed Release build and **278 unit tests**, with zero failures. SwiftLint across touched files still reports existing line/file-length and empty-count errors; a baseline check against main reproduced them. New service, picker and updater files have no lint errors. Deterministic lifecycle tests suspend operations before execution and between decode/save, check multiple concurrent operations, reject work after termination begins, and verify flush failure prevents engine teardown. Update tests cover semantic ordering, prereleases, pagination, incomplete/empty results, errors and preference behavior. Language tests cover filtering, recents and visual/keyboard ordering. The lifecycle admission guards in SwiftUI were reviewed, but live capture/quit behavior still needs the manual checks below. The installed build remains PR #41 until this follow-up batch is merged and installed.

## Validation

Initial-batch validation passed: signed Release build and all 276 unit tests, zero failures and zero skips. Two independent adversarial reviews completed; their confirmed startup and repeated-error-reporting findings were fixed and revalidated. Targeted SwiftLint reported no errors; existing style and unrelated engine-concurrency warnings remain.

The real XCTest 10,000-entry synthetic archive measured **314 ms** for encoding/import/setup and **3.3 ms** for a substring search in a Debug test build on this Mac. The facade retained **50 transcripts**. These are observations, not brittle timing assertions or measurements of interactive UI latency. A separate optimized harness using the production store/facade measured 210 ms migration and 4.35 ms search while a main-actor heartbeat continued; its transcription normalization was stubbed, and no audio/model inference was performed.

Regression coverage includes migration/restart/metadata, malformed migration recovery, mutations during initial load, deletion with retained statistics/audio semantics, editing entries outside the recent page, literal wildcard and Unicode search, equal-date pagination, deleting the final item on a page, calendar/daylight-saving boundaries, model inventory/deletion boundaries, and deterministic selection.

### Manual UI acceptance checklist

The agent environment cannot grant the UI runner Accessibility access, so these checks require a human with the signed build. Unit tests and the synthetic benchmark do not establish that the rainbow spinner is gone in interactive use.

- Open History with the existing archive; confirm the first 50 rows render promptly and Next/Previous reach older entries.
- Type and clear searches rapidly; confirm the latest query wins, counts match, and no-results has an obvious recovery action.
- Copy a collapsed entry; expand a long entry and verify full transcript copying, text selection, audio playback, and re-transcription.
- Navigate away during playback, change pages/search, delete the expanded entry, and clear history; playback must stop and state stay consistent.
- Resize to the minimum supported window width; check action menus, search, settings tabs, keyboard focus, and VoiceOver labels.
- Reopen the app; verify migrated history and statistics. Confirm Clear All retains statistics and recordings as described.
- Open AI Models under each engine; check inventory feedback, model selection, deletion confirmation, and a failed deletion error.
- Visit General, Transcription, Audio, and Permissions; leave Settings and return; the selected tab should remain. Switch to an engine missing the selected model and confirm visible guidance.

- Search spoken languages by name/code; use arrow keys, Return and Escape; confirm the highlight remains visible and VoiceOver announces selections. Switch to an English-only model and confirm the picker disables.
- Check for updates manually with normal connectivity and offline; verify visible results, source link, close/skip/reminder actions and a single update window.
- Quit during microphone capture, model loading, file transcription and history re-transcription; relaunch and verify each successful result was saved. A long decode should delay quit while the app remains responsive.
- During microphone capture, confirm file upload/drop is unavailable and Stop Recording still works. During file transcription, confirm new recording/import is unavailable.
