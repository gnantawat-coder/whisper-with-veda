# Veda — development handoff

Native macOS local dictation app. User communicates in Thai and expects actual installed fixes, not just passing unit tests. Read outputs/Veda/VALIDATION.md before claiming completion.

## Workspace
- App source: outputs/Veda/Sources/{main,Core,AudioCapture,Visuals,SnapTranslate}.swift (build.sh lists them; render harness needs -framework Vision -framework Translation)
- Build: bash outputs/Veda/scripts/build.sh; tests: bash outputs/Veda/scripts/test.sh. Both pin `-target arm64-apple-macos15.0` (LSMinimumSystemVersion 15.0): this Mac runs macOS 27.0 while the installed SDK defaults to macosx28.0, and an unpinned binary (minos 28) is refused by LaunchServices (-10825). Any ad-hoc swiftc invocation (render harness, probes) must pass the same -target.
- Installed app: ~/Applications/Veda.app (single canonical installation).
- Install helper: work/install-update.py. Build artifacts are deliberately .bundle-backup under work/build-artifacts.noindex to avoid duplicate launchable apps.
- Current development version: 0.1.32. Check actual installed Info.plist/diagnostics rather than assuming installed version.
- Diagnostics: /private/tmp/veda-diagnostics.json. No transcripts there; pendingCount is a count only.

## Current scope
- TH transcription, Thai-to-English translation, and Snap Translate (default ⇧⌘3, user-recordable; region capture → on-device OCR → on-device Apple Translation, TH↔EN). QA/wake word/TTS for dictation were explicitly removed at user request; do not restore those. Spoken translation for Snap Translate (opt-in toggle, AVSpeechSynthesizer) was requested later and is in scope. Signing identity (stable TCC) deferred by user.
- Mac Fn hold: record; release: transcribe/insert. Keychron K2 Max light key mapped by user to F18; externalF18 option enabled.
- New code: Fn+Space and F18+Space toggle Veda TH/EN, consume Space release and ignore repeats. They do not change macOS input source. Chord cancels current recording rather than inserting it.
- Small centered strip with voice level and rotating cyan/indigo/violet aura; separate settings window opens only explicitly.
- New Settings sidebar: dictation, held transcripts, diagnostics, personal profile.
- Runtime prefers ~/Library/Application Support/Veda/models/ggml-large-v3-q5_0.bin, then ggml-large-v3.bin, then ggml-medium.bin, otherwise bundled small. q5_0 matched f16 output exactly on all test audio (TH and EN) and is 15–29% faster; --audio-ctx reductions silently drop sentences and were rejected. large-v3-turbo was rejected: it cannot translate to English. Model files also kept in work/model-evaluation for A/B (scratch harness pattern: separate whisper-server on port 18799). Current improvement was measured on one supplied clip and a generated fixture, not a broad user study.

## Known issues / important constraints
- Ad-hoc signing means changing executable invalidates macOS TCC grants. Never bypass TCC, alter its database or weaken signature requirements. Minimize reinstall cycles; use a legitimate stable signing identity if available. User must authenticate normal permission dialogs.
- Accessibility switch On may still correspond to stale binary. Actual AXIsProcessTrusted and exclusiveFnReady diagnostics are authoritative. Removing/readding exact app through normal Settings fixed it previously.
- Insertion remains unverified across user's editors. AXSelectedText can report success with no visible insertion. New code reads value back, then uses Unicode key events only if original field/value/caret remain unchanged. Unknown/changed targets retain text. No automatic chat send or clipboard replacement.
- Pending transcripts are RAM-only. Preserve ALL before quit/update through private one-time migration JSON /private/tmp/veda-upgrade-pending-<uid>.json (0600), deleted on restore. Never store user transcripts in repository/handoff/logs. Do not kill app before preserving them.
- User-provided test clip IMG_7165: small translated speech-to-text clause as 'make it different'; medium gave 'change the speech into text'. Thai spelling still imperfect. Prompt-only workaround failed and was not adopted.
- Private recordings/test data under work/ should not be published. Personal calibration is not fine-tuning; do not claim the app has learned the user's voice. Need opt-in paired audio/correct transcripts and separate held-out evaluation before accuracy claims.
- Do not synthesize Fn or capture microphone autonomously; use supplied audio files or user-initiated test.
- Do not concurrently modify files from Claude and Codex; coordinate handoffs.

## Next priorities
1. Confirm 0.1.12 installation, actual permission readiness and physical shortcut behavior.
2. Test real Thai paired recordings and translation meaning/negation/names, compare medium vs small with latency.
3. Verify safe insertion into actual user editors; do not label held or unverified output as inserted.
4. Personal calibration profile with user-approved vocabulary/examples, no automatic semantic rewriting.

## Handoff on 2026-09-09: unfinished changes
The working tree contains an uninstalled personal-profile UI in main.swift: profile name, vocabulary injected into dictation requests, import of a 16kHz mono WAV up to 30 seconds, and user-confirmed expected/heard text pairs (max 20). These are local UserDefaults; audio is not retained, and no acoustic model training occurs. Initial Swift typecheck passed with an allowedFileTypes deprecation warning. This feature still needs usability review, tests, build, and visual verification before installation. Consider accepting normal phone recordings with safe conversion, since requiring preconverted WAV is inconvenient.
The idle marker was changed to a continuous capsule 44x9 with softer border/shadow; vertical padding now 9 to fit the existing panel. This is also uninstalled. Finish the profile subtitle and review layout. Do not claim either change has reached the installed 0.1.12 app.
Claude desktop Code has been pointed at this exact local folder, with worktree off so existing untracked sources are present. Chat's veda-project MCP server is separately configured in Claude desktop config; its standalone read/scope test passed, but client connection has not yet been verified. Code mode can read/build the local project directly without that Chat MCP.

## Latest checkpoint — 2026-09-10, ready for Claude continuation
Codex finished this bounded cleanup and is no longer editing: profile-specific subtitle added; WAV picker now uses UniformTypeIdentifiers/allowedContentTypes; saving examples is disabled and guarded while transcription is running; empty/whitespace expected text cannot be saved. Idle capsule padding remains 9 so it fits the panel.
Validation: all 56 existing core/placement/shortcut checks passed; full Swift typecheck passed without the prior deprecation warning; build.sh completed successfully. Existing tests do NOT validate personal-profile storage, audio import or visual appearance. Build ZIP is a DEVELOPMENT artifact still labelled 0.1.12, not installed: bump version/build before any release. Installed app was not stopped or changed, and pending transcripts were not touched.
Next: review/render profile and idle bar, improve ordinary phone-audio import if appropriate, test profile persistence/import with supplied fixtures, then version and install only after preserving all live pending text. User will continue in Claude; work from this checkpoint rather than restarting implementation.

## Latest checkpoint — 2026-09-10, Claude session, 0.1.14 installed
Found and fixed a gap the previous handoff assumed was working: nothing in the project ever WROTE /private/tmp/veda-upgrade-pending-<uid>.json, so every version up to and including the installed 0.1.12 discarded held transcripts on quit. Writing now happens in PendingArchive.save (Core.swift), called first in applicationWillTerminate. A first attempt deleted the archive when quitting with an empty tray, which destroyed text an earlier session had left unrestored; caught by end-to-end testing against the installed build, fixed, and covered by regression tests. User confirmed 0.1.12 had nothing pending before the update, so no transcripts were lost.
Also in 0.1.14: ordinary phone recordings (m4a/mp3/caf/aiff, any rate, stereo) are converted locally to 16 kHz mono via CalibrationAudio.wav16kMono; profile text fields share one styled editor with placeholders; PersonalProfile/AudioImport moved into Core.swift so they are testable; diagnostics build reads Info.plist instead of a hard-coded string and reports pendingCount; the snapshot renderer covers the profile page (empty, filled, full page) and draws the idle marker at its real 74x32 size.
Validation: 82 checks pass (was 56), full typecheck clean, 16 real audio-conversion checks pass, preserve/restore verified end to end against the installed app. Profile page and idle capsule reviewed visually in outputs/Veda/ui-check.
Not yet done: ad-hoc signing invalidated TCC, so Microphone and Accessibility must be re-granted by the user before Fn, insertion, or transcription accuracy can be tested on 0.1.14. Personal calibration has still never been run on a real Thai recording end to end. Stale 0.1.0 bundles from 2026-09-07 remain in /private/tmp/veda-sign.OuvJlS and /private/tmp/veda-package-check; Spotlight does not index them.

## Checkpoint — 2026-09-10 later, 0.1.15 installed (large-v3 + Thai normalizer)
User reported many Thai errors. Evidence on 3 local clips showed model-level tone/consonant errors, not Unicode. A/B of medium / large-v3-turbo / large-v3: large-v3 fixed most and kept EN translation; turbo cannot translate; decoding flags did not help on medium. Installed large-v3 (3.1 GB, sha256 64d182b4…) and ThaiText.normalized (Core.swift) for decomposed SARA AM / mark order / zero-width. 91 tests. Held transcripts (2 real) survived the update through PendingArchive. TCC must be re-granted again (no signing identity on this Mac).
Next: user records the 6 calibration utterances + 3 held-out into work/calibration/ (m4a fine); measure medium vs large-v3 char edit distance and in-app latency; then investigate insertion into the Claude desktop composer (2 held texts came from there).

## Checkpoint — 2026-09-10, 0.1.16 installed (drop audio onto profile card, 120 s limit)
User recorded the calibration list in one take with a Shure MV7+ via MOTIV Mix (file <private recording, not in repo> — private, never copy into the repo). Calibration card now accepts dragged files; AudioImport.maxSeconds is 120. 92 tests. 4 held transcripts survived this update. TCC re-grant needed once more.
Next: user re-grants permissions, drops the recording, pastes the verbatim text; then measure medium vs large-v3 on that file (scratch harness ab.py pattern), and look at Claude desktop composer insertion (now 4 held texts from there).

## Checkpoint — 2026-09-10, 0.1.17 installed (drop fix)
Dropping onto the transcript NSTextView pasted the path; fixed with FileDropTextView routing file URLs to importCalibration(url:). Always pass an absolute -module-cache-path to swiftc -typecheck (relative path crashes the frontend). Pending: user re-grants TCC, drops the MOTIV recording, supplies verbatim text; then A/B medium vs large-v3 on it.

## Checkpoint — 2026-09-10, 0.1.18 installed (q5_0, hold diagnostics, re-scorable examples, first git commit)
Diagnostics now carry holdReason (why text was held: no target/role, focus changed, value/caret changed, or which insert step failed) and profileCER. `Veda.app/Contents/MacOS/Veda --probe-focus` (installed binary, after TCC granted) prints the focused field's role. Next: user re-grants TCC, dictates once into the Claude desktop composer, then read holdReason and fix insertion from evidence. Latency: q5_0 adopted; streaming not possible with whisper-server; do not use --audio-ctx. Signing identity (item 3) deferred by user.

## Checkpoint — 2026-09-10, 0.1.19 installed (Claude composer insertion)
Evidence from holdReason: Claude desktop composer is AXTextArea; AXSelectedText is a no-op; Unicode key events do change the field but the read-back never equals the predicted string. Insertion.succeeded (Core.swift) now judges by "field changed and contains the dictated text". Unconfirmed on Claude after the fix. Known weak spot: English words inside Thai sentences (Voice to Text→Void2Text, Claude→คลอส); vocabulary hints do not fix it. User is recording a held-out set of real work sentences (list given in chat) to drop onto the profile card.

## Checkpoint — 2026-09-10, 0.1.20 installed (removed -nt)
`-nt` made whisper.cpp drop speech just before the 30 s window boundary (whole sentence lost in a 37 s take). Never re-add it. cleaned() joins segment newlines with spaces. Held-out CER on the user's real work sentences: 10.7% (7.1% treating digits as spoken numbers); remaining errors are English words inside Thai (Claude, Codex, main.swift, Voice to Text, Keychron). Claude desktop insertion confirmed working by the user on 0.1.19. Next candidates: code-switching (English terms) — vocabulary hints do not help; consider a user-confirmed term list applied only to exact recognised variants after explicit approval per term, never global substitution.

## Checkpoint — 2026-09-10, 0.1.21 installed (icon, approved terms, Snap Translate)
Sidebar mark now equals the app icon; stale Launch Services registrations removed. Approved term corrections (profile card) apply only to exact recognised variants during dictation. Snap Translate implemented but untested end to end: needs Screen Recording TCC and the first-use language pack download. Per-update TCC re-grant still required (ad-hoc). Next: user tests ⌘⇧2, approves terms (คลอส→Claude, Codec→Codex, Voice2Tech→Voice to Text, Keycon→Keychron), records the held-out set per sentence if wanted.

## Checkpoint — 2026-09-10, 0.1.22 installed (Snap card redesign, ⇧⌘3 default, recordable shortcut)
Snap Translate confirmed working end to end by the user on 0.1.21. Shortcut is now SnapShortcut (any chord with a modifier), default ⇧⌘3 at the user's request — it shadows macOS full-screen capture; verify the system does not also fire, otherwise the user disables it in Keyboard › Shortcuts › Screenshots. Result card: borderless material card near the pointer, click-outside/Esc dismiss, single filled copy action. Approved-term corrections still untested in real dictation.

## Checkpoint — 2026-09-10, 0.1.23 installed (HID tap attempt, relaunch button, spoken translation)
Session-level tap did not pre-empt macOS ⇧⌘3 (system screenshot fired alongside Veda). Tap now tries HID level first; diagnostics tapLevel says which was accepted. Screen Recording grant needs a fresh process: settings card has "เปิด Veda ใหม่". If the system screenshot still fires with tapLevel=hid, the user must disable Keyboard › Shortcuts › Screenshots or choose another chord. Verify after the user re-grants permissions.

## Checkpoint — 2026-09-10, 0.1.24 installed
HID-level tap confirmed accepted (tapLevel=hid on 0.1.23). Fixed: repeated capture in the same direction hung because translationTask needs an invalidated configuration; card height now measured from content; voice selection never picks novelty voices. Pending user confirmation of all three plus whether macOS's own ⇧⌘3 still fires alongside.

## Checkpoint — 2026-09-10, 0.1.25 installed
Repeated Snap Translate hang root cause: a fresh TranslationSession.Configuration invalidated once equals the previous one, so translationTask never re-ran. Keep one configuration per direction and invalidate it in place. 20 s watchdog with retry. Always run build/install scripts with absolute paths (a relative call after cd silently skipped the install once). Awaiting user confirmation of second-capture translation, speech, and card size.

## Checkpoint — 2026-09-10, 0.1.26 installed (persona-review items)
Snap Translate now uses Veda's own full-screen picker (SCScreenshotManager freeze → whole-screen OCR → forgiving drag / click-a-paragraph / loupe). Term suggestions from saved examples. Elapsed-seconds counter on the bar. 3-step setup card auto-opens when permissions are missing. "ข้อความพัก" renamed "ยังไม่ได้พิมพ์" in UI only (internal names unchanged). Untested on the real screen: picker, loupe, click-paragraph, multi-display. UX review: outputs/Veda/UX-REVIEW-0.1.25.md.

## Checkpoint — 2026-09-10, 0.1.27 installed
User preferred the system region picker over Veda's own overlay; the overlay (frozen screen, loose selection, click-a-paragraph, loupe) was removed again and lives only in git history (7e16e72). Do not re-add without being asked. Everything else from the persona review stays. Awaiting user tests of: term suggestions on their real example, elapsed counter, setup card.

## Checkpoint — 2026-09-10, 0.1.28 installed (slang modes)
Slang glossary (Core `Slang`, 46 seed entries, user additions in UserDefaults slangCustom) with polite/chat modes on the Snap card and in settings. Plain-language rewrite before translation, chat-mode swap-back after, notes always shown with register badges. Dictation EN mode not covered (whisper translates audio directly). Awaiting user tests of 0.1.27/0.1.28 items.

## Checkpoint — 2026-09-10, 0.1.29 installed
Fixed: the slang "เพิ่ม" button was permanently disabled because SlangEntry required optional keys to exist in the dictionary the form builds lazily. Only th and en are required now. Lesson for any future form built on [String: String]: a guard on a key is not a guard on a value.

## Checkpoint — 2026-09-12, 0.1.30 installed (cold-start warm-up)
The 5 s wait the user reported is a cold-start effect, not audio length: their latency.csv shows ~5-6.4 s on the first dictation after hours idle and ~1.7 s back-to-back. Fix: LocalBackend.warmUp() transcribes 1 s of the bundled test-jfk.wav, fired at Fn *press* and only when idle >= 90 s, so it overlaps with speaking. Never warm up with silence (12.7 s) and never use audio_ctx (garbage output, 6-12 s stalls at 384/640 - measured twice now, 0.1.20 and 0.1.30). Threads make no difference on M5. Not yet proven to fix the 5 s case - hours of idle cannot be simulated; latency.csv now logs idle_before_s and warm_up_ms so the p90 can be checked over the coming days.

## Checkpoint — 2026-09-17, 0.1.31 installed (openai/whisper comparison)
Compared Veda's decoding with openai/whisper docs and measured on the user's two recordings: beam 5 (openai default) is worse and slower for Thai; -sns no effect; thresholds already identical; the initial prompt is the only lever that helps (list of terms: 10.7% -> 8.0% CER on real work sentences; a sentence-style prompt hallucinates names - never use it). "Claude" is never heard directly (คอร์ด/คลอส); user's approved terms only cover คอส/คอด. Added VocabularyHarvest: terms from saved examples' expected text offered into the vocabulary list. Toolchain: macOS 27 + SDK 28 - deployment target now pinned to 26.0. Pending tray was empty at the 0.1.30 quit (no archive written).

## Checkpoint — 2026-09-17, 0.1.32: sharing with friends
Public GitHub repo "whisper-with-veda" (user's choice, MIT) built from a clean single-commit export of the current tree; the dev repo's own history contains unreachable multi-GB blobs and must never be pushed. Personal paths/names scrubbed; PDFs/AGENTS.md untracked. macOS floor lowered to 15; accurate model (large-v3-q5_0) is downloaded in-app with sha256 verification. gh CLI lives in ~/.local/bin (device-flow login by the user). Untested: real download on a fresh Mac, macOS 15/16 runtime. Friends still face Gatekeeper "Open Anyway" and per-update TCC re-grants until the user buys Apple Developer Program.
