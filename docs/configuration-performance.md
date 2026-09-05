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

The shutdown coordinator uses asynchronous AppKit termination and has no forced five-second exit. It can wait for a long decode to finish. If history reports an error, termination is cancelled and an alert keeps the app open. The **SPEAKTYPE-9** recovery protocol below extends this lifecycle ordering to retain failed mutations across retries and restarts. Ordinary read errors do not block quitting when no recovery work remains.

The follow-up batch passed a signed Release build and **282 unit tests**, with zero failures. SwiftLint across touched files still reports existing line/file-length and empty-count errors; a baseline check against main reproduced them. New service, picker and updater files have no lint errors. Deterministic lifecycle tests suspend operations before execution and between decode/save, check multiple concurrent operations, reject work after termination begins, and verify flush failure prevents engine teardown. Update tests cover semantic ordering, prereleases, pagination, incomplete/empty results, errors and preference behavior. Language tests cover filtering, recents and visual/keyboard ordering. Two independent adversarial reviews completed. Their recording/import overlap and modifier-hotkey quit/cancel race findings were fixed and verified. Shortcut regressions cover SpeakType’s own Command-Q versus a different foreground app and other modifier combinations. A parallel test run also exposed existing shared engine-preference interference; the two affected test classes now use scoped, process-local overrides. The final normal parallel unit gate passed all 282 tests. Live capture/quit behavior still needs the manual checks below. The follow-up batch merged in [PR #42](https://github.com/mggarofalo/speaktype/pull/42) and was installed with the same signing identity. The installed executable matched the validated Release executable.

## Validation

Initial-batch validation passed: signed Release build and all 276 unit tests, zero failures and zero skips. Two independent adversarial reviews completed; their confirmed startup and repeated-error-reporting findings were fixed and revalidated. Targeted SwiftLint reported no errors; existing style and unrelated engine-concurrency warnings remain.

The real XCTest 10,000-entry synthetic archive measured **314 ms** for encoding/import/setup and **3.3 ms** for a substring search in a Debug test build on this Mac. The facade retained **50 transcripts**. These are observations, not brittle timing assertions or measurements of interactive UI latency. A separate optimized harness using the production store/facade measured 210 ms migration and 4.35 ms search while a main-actor heartbeat continued; its transcription normalization was stubbed, and no audio/model inference was performed.

Regression coverage includes migration/restart/metadata, malformed migration recovery, mutations during initial load, deletion with retained statistics/audio semantics, editing entries outside the recent page, literal wildcard and Unicode search, equal-date pagination, deleting the final item on a page, calendar/daylight-saving boundaries, model inventory/deletion boundaries, and deterministic selection.

### Manual UI acceptance checklist

The XCTest UI runner still lacks Accessibility access. Native computer-use access did work against the installed PR #42 build: History opened with 655 entries, advanced to page 2 of 14, filtered to page 1 of 1 for a matching search, and returned to page 1 of 14 after clearing it. Settings showed a successful update-check result; language search filtered to Hindi, Escape dismissed the popover, and arrow/Return selection retained Auto-detect. General settings and Dashboard were restored afterward. These checks establish functional UI behavior, not a measured interactive latency or a complete VoiceOver/live-recording audit. The remaining checks below require a human or an isolated UI fixture.

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
- With Command as the hold-to-record hotkey, verify SpeakType’s Command-Q saves capture while a modifier combination sent to another app still cancels it.
- Quit during microphone capture, model loading, file transcription and history re-transcription; relaunch and verify each successful result was saved. A long decode should delay quit while the app remains responsive.
- During microphone capture, confirm file upload/drop is unavailable and Stop Recording still works. During file transcription, confirm new recording/import is unavailable.

## Failed-save recovery (SPEAKTYPE-9)

A failed mutation must remain recoverable even after a successful read or later save request. Pending additions, edits, deletions and clears are written to a separate recovery journal before SQLite applies them. Each operation has a stable ID recorded in the same database transaction as its effect. Retry and restart process the queue in order and skip already committed operations; journal cleanup precedes retirement of the corresponding database receipt. A failed operation holds later changes behind it, preserving deletion and clear ordering.

History exposes a save-recovery banner that cannot be dismissed with the number of pending changes and a Retry saves action. Read errors stay separate. Quit waits for active transcription, attempts pending recovery once, and keeps the app open if pending work or an unreadable recovery journal remains. A corrupt journal is preserved for repair rather than replaced; new changes stay in memory if the journal itself cannot be written. This handles ordinary write errors and restart recovery without claiming that unavailable storage can always persist new content.

An exclusive recovery-journal lock prevents the production and beta apps from replacing each other’s pending saves. A second instance can browse existing history; its new changes remain pending until the other instance closes and recovery is retried. Audio cleanup records the original file’s identity so retries cannot unlink a replacement at the same path.

Regression coverage includes injected SQLite write failures followed by later changes, repeated retry, restart, commit-before-journal-cleanup failure, snapshot failure after a successful write, edit/delete/clear ordering, corrupt journals and write-protected recovery paths. Competing-owner tests cover idle quit, pending-work handoff, refreshed statistics and a failed statistics reload that must preserve disk work ahead of later RAM arrivals. Audio tests cover failed unlink retry and replacement-file protection. Tests use isolated temporary data; production history is not damaged to simulate failures.

Final SPEAKTYPE-9 validation passed: signed Release build, all **297 unit tests** with zero failures/skips, and focused SwiftLint with zero errors. Two independent adversarial reviews completed; shared-journal ownership, retryable audio cleanup, ownership-transfer statistics and transfer-failure ordering were corrected and revalidated. Production history was not modified to exercise failure paths.
