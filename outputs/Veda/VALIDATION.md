# Validation — 2026-09-07

## ผ่าน

- Swift app compile ด้วย Swift 6.3.3 บน arm64, macOS SDK 26.5, deployment minimum 26.0
- whisper.cpp v1.8.3 build แบบ static และ embedded Metal สำเร็จ มีเพียงคำเตือนของ dependency; ไม่ต้องมี dylib นอกระบบ
- Core tests 18 checks: unknown focus; unchanged focus; app switch away/back; field/caret/selection/value change; lost AX access; TH/EN multipart translate flag; Thai source flag; WAV bytes; multipart terminator; cleanup preserves wording/negation/numbers
- โมเดล multilingual small ดาวน์โหลดครบและบันทึก SHA-256 ใน README
- CPU backend `/health` → 200 {status:ok}; transcribe bundled upstream English JFK WAV สำเร็จ เวลาคำขอ curl 1.442343 s (หนึ่งครั้ง)
- แอปเปิดผ่าน native app tooling แถบลอยและ Settings render ครบ สถานะ “กด Fn ค้างเพื่อพูด” backend `/health` พร้อม
- Backend จากแอปปกติ (ค่าเริ่มต้นเปิด GPU) ถอด upstream English JFK WAV สำเร็จ เวลาคำขอ curl 0.795346 s (หนึ่งครั้ง) ข้อความตรงกับประโยคตัวอย่าง
- ไม่มีการขอหรือกดยอมรับสิทธิ์ Microphone/Accessibility โดย agent และไม่ได้กด Fn เพื่อเริ่มบันทึกเสียง

## ไม่ใช่ผล benchmark TH/EN

เวลาข้างต้นคือ smoke test ไฟล์เสียงอังกฤษประมาณ 11 วินาที ไม่ได้ผ่าน Fn/audio capture/UI insertion และไม่ได้ใช้ภาษาไทย จึงใช้แทน latency ผู้ใช้หรือเปรียบเทียบความเร็ว CPU/GPU โดยสรุปไม่ได้ TH/EN release latency จะถูกบันทึกเมื่อผู้ใช้ทดลองจริง ยังไม่มีค่าที่วัดแล้ว

## ข้อจำกัดของพื้นที่ทดสอบ

Metal backend ที่รันจาก restricted shell ล้มเหลวขณะจัดสรร buffer แต่ backend ที่เปิดจากแอปตามปกติโหลดและ inference สำเร็จ เสียงสังเคราะห์จาก `say` ใน restricted shell ออกมาไม่มีเสียง จึงไม่ได้ใช้เป็นหลักฐานคุณภาพภาษาไทย

## ยังต้องทดสอบ

สิทธิ์ไมค์/Accessibility, physical Fn press/release, meter, Escape ทั้งสองช่วง, AX insertion ใน TextEdit และแอปปลายทางจริง, focus observer ของแต่ละแอป, ความแม่นภาษาไทยปนอังกฤษ/คำปฏิเสธ/ตัวเลข และคุณภาพแปลอังกฤษสำหรับสั่ง AI โดยผู้ใช้เป็นผู้กดเริ่มเสียงเอง ดูรายการใน README

## UI refinement ตามคำขอเพิ่มเติม

- Idle เหลือขีดเล็ก 28 × 4 pt (หน้าต่างรวม 46 × 20 pt) ตรวจ screenshot ของแอปจริงแล้ว
- เฉพาะ listening/processing ขยายเป็นแถบ compact สูง 38 pt ไม่มีชื่อ Veda หรือ hold fn
- เลือกภาษาได้ใน Settings ที่เปิดจากขีดเล็กหรือ menu bar ตรวจ Accessibility tree แล้ว
- Swift build และ core tests ผ่านหลังเปลี่ยน UI
- File Provider ใน Documents เติม FinderInfo กลับลง app bundle ทำให้ strict codesign verification ในตำแหน่งนี้ไม่ผ่าน แม้แอปเปิดทำงานได้ จึงแนบ Veda.zip จาก bundle ที่ sign และ strict verify สำเร็จใน staging ที่อยู่นอก File Provider หากต้องย้ายใช้ถาวรให้แตก ZIP ลง Applications บนเครื่อง

# Fix validation — 2026-09-08 / Veda 0.1.2

## สาเหตุที่ตรวจพบจริง

- อ่านจากแอป 0.1.1 ที่ผู้ใช้เปิดอยู่และ diagnostics: ได้รับ Fn ปล่อย แต่ lastStage เป็นปฏิเสธก่อนเริ่มอัด จึงยังไม่มี latency หรือข้อความพัก
- ณ ก่อนอัปเดต Microphone เป็น authorized แต่ AXIsProcessTrusted เป็น false ข้อความหลักยังค้างเรื่องไมค์ นี่คือ bug ที่ยืนยันแล้ว
- หลัง rebuild เป็น 0.1.2 macOS รายงาน Microphone เป็น notDetermined และ Accessibility false สำหรับ binary ใหม่ ดังนั้นต้องให้สิทธิ์กับรุ่นสุดท้ายใหม่ ไม่ถือว่าสิทธิ์รุ่นเก่าคงอยู่

## แก้ไข

- PermissionGate แยกไมค์/Accessibility/พร้อม และอัปเดต blocker หลังให้สิทธิ์แต่ละรายการ ไม่ค้างเหตุผลเก่า
- บอก path/build จริงใน Settings, diagnostic มี timestamp/PID, last Fn event และ pipeline stage; ไม่มี transcript/เสียงใน diagnostics
- ปุ่มสิทธิ์แยกกัน กรณี microphone denied เปิด pane ที่ถูกต้อง ไม่เรียก requestAccess ซ้ำแบบไม่มีผล
- ลงทะเบียน global event monitor ใหม่เมื่อ Accessibility เปลี่ยน
- การกดเริ่มที่ล้มเหลวแสดง Settings พร้อมสาเหตุและขีดสีส้ม; แยกไฟล์เสียงว่าง/สั้น/เบา/backend error
- ทดสอบโมเดลแบบไม่ใช้ไมค์ด้วย bundled upstream JFK WAV ผ่าน URLSession + multipart ของแอปเอง โดยแยกจาก latency.csv ผู้ใช้
- ย้ายตำแหน่งใช้งานเป็น ~/Applications/Veda.app หลังได้รับ filesystem permission และอัปเดต launcher ทั้งสอง outputs ให้ชี้ตำแหน่งนี้ หลีกเลี่ยง File Provider ใน Documents
- idle 24×3 pt ไม่มีพื้นหลังซ้อน; active capsule สูง 28 pt เหลือภาษาและ waveform หรือ spinner ชุดเดียว

## ผลตรวจ

- Swift build 0.1.2 ผ่าน; core checks 22 ข้อผ่าน รวม regression การอนุญาตไมค์แล้วต้องแสดง AX เป็น blocker ที่เหลือ
- codesign --verify --deep --strict บนแอปที่ติดตั้งผ่าน; Info.plist ผ่าน plutil
- เปิดแอปจาก ~/Applications/Veda.app ตรวจ path/version ผ่าน AX tree
- คลิกตรวจโมเดลโดยไม่ใช้ไมค์จากแอปที่ติดตั้ง: WAV → URLSession/HTTP → whisper → ข้อความผ่านใน 300 ms หนึ่งครั้ง เป็น fixture ภาษาอังกฤษ ไม่ใช่ latency Fn/TH/EN ของผู้ใช้
- Settings render ผ่านการตรวจ screenshot และ UI tree; ตัว agent ไม่กด Fn เริ่มเสียง ไม่อนุมัติ permission แทนผู้ใช้ ไม่ส่ง Enter/Send

## ขอบเขตที่ยังพิสูจน์ไม่ได้

ยังไม่มีสิทธิ์ Microphone/Accessibility ของแอปที่ติดตั้ง จึงยังทดสอบ microphone capture หรือ AX insertion กับแอปปลายทางจริงไม่ได้ การทดสอบ focus safety เป็น core tests เท่านั้น ยังไม่ควรอ้างว่าครบ end-to-end ด้วยเสียงจริง ผู้ใช้ต้องอนุญาตสองสิทธิ์ใน Settings แล้วกลับไปช่องข้อความก่อนกด Fn; หากยังไม่ทำงานให้ดู last event/stage และข้อความพักซึ่งตอนนี้แสดงสาเหตุชัดเจน

# Veda 0.1.3 — 2026-09-08

- ตรวจวิดีโอ IMG_7129.MOV (7.92 วินาที) โดยดึงเฉพาะเฟรม ไม่ถอด/ฟังเนื้อหาเสียง: Settings เปิดทับแอปเป้าหมายช่วงประมาณ 2.6 วินาที สอดคล้องกับ block() ของรุ่นเดิม
- Diagnostics สดของ 0.1.2 ณ ตรวจก่อนอัปเดต: mic authorized, AX false, Fn up ได้รับแล้ว, ติดตั้ง path ถูกต้อง จึงแยกหลักฐานนี้จากรูป Microphone ที่ผู้ใช้เปิดแล้ว
- Refactor main/audio/focus queue, hold latch, ไม่เปิด Settings จาก block(), TH/EN ปัจจุบัน, fallback พักเมื่อ AX ไม่พร้อม ทำใน source แล้ว
- Core checks 26 ข้อผ่าน รวม queued start หลัง release ไม่เรียก action, session เก่าไม่ผ่าน latch ใหม่, cancel invalidates hold
- พรีวิวที่ compile ด้วย UI_PREVIEW ใช้ Bar เดียวกับแอปจริง แต่ไม่เริ่ม backend/ไมค์: เปิดด้วย native UI tooling, คลิก EN แล้ว AX selected value เปลี่ยนและ diagnostics sessionMode=EN, screenshot แถบ compact/cloud/waveform ตรวจแล้ว ไม่ใช้เป็นหลักฐานเสียงจริง
- Cloud icon วาดจาก native path และบรรจุ ICNS; macOS sips อ่านเป็น icns 1024×1024 ได้
- ไม่มี valid code-signing identity บนเครื่อง จึงยังใช้ ad-hoc ไม่ได้อ้างว่า permission จะคงอยู่ทุก rebuild
- ย้าย source/scripts/tests/runtime มายัง workspace ใหม่ ~/Documents/ChatGPT/Veda โดยต่อจากงานเดิม

## Final install check 0.1.3

- Build จาก workspace ใหม่ผ่าน รวมปรับการแจ้งข้อผิดพลาดเมื่อ prepare สำเร็จแต่ record() ล้มเหลว
- Source/AudioCapture shutdown ปิด recorder และลบเสียงชั่วคราวก่อนออกตามปกติ
- ติดตั้งทับตำแหน่งเดิมหลังได้รับ filesystem permission: ~/Applications/Veda.app
- codesign --verify --deep --strict ผ่านในตำแหน่งติดตั้ง; Info.plist version=0.1.3; ICNS อ่านโดย sips ผ่าน
- เปิดด้วย native app tooling ตรวจ AX tree แสดง 0.1.3 และ path ถูกต้อง
- กดตรวจโมเดลโดยไม่ใช้ไมค์: fixture → WAV/HTTP → โมเดล → ข้อความผ่าน 298 ms หนึ่งครั้ง ไม่ใช่ latency Fn หรือผลเสียงไทย
- Core tests รอบสุดท้าย 26 ข้อผ่าน และ shell syntax checks ผ่าน
- สถานะ macOS ของรุ่นติดตั้งใหม่: Microphone notDetermined; Accessibility false ดังนั้นยังไม่สามารถทดสอบ capture หรือ insertion จริง ผู้ใช้ต้องให้ Microphone ก่อนรับเสียง และ Accessibility ก่อนแทรกอัตโนมัติ หากมีเพียงไมค์ รุ่นใหม่จะพักผลให้คัดลอกแทน
- ไม่อ้างว่าแก้ความหน่วงด้วยตัวเลข end-to-end แล้ว: overlayDispatchMS วัดการสั่ง UI ส่วน captureReadyMS/latency Fn จะมีข้อมูลเมื่อผู้ใช้กดเริ่มจริง การย้ายคิวและเตรียมโมเดลเป็นการปรับ implementation ที่ยังต้องวัดกับเสียงจริง

# Veda 0.1.4 — one-bar UI / simulated UX review

- ยืนยันว่าพรีวิวเก่า (local.veda.preview) ยังเปิดอยู่และ AX ได้รับอนุญาต แต่ app จริง local.veda.dictation ไม่ได้ AX; ปิด preview ผ่าน native UI แล้วก่อนอัปเดต ไม่ใช่การเดาว่าผู้ใช้เปิดแอปเองซ้ำ
- เพิ่ม SingleInstanceLock ด้วย flock ก่อนสร้าง panel/backend และทดสอบแข่ง acquire/release ใน core tests
- เลิก build พรีวิวที่รันค้างทั้งระบบ; --render-overlays สร้าง idle/listening/processing/held/permission PNG แบบ offscreen แล้วจบ process ไม่มี Fn monitor หรือ recorder/backend
- ตรวจ PNG แล้ว: active แถบเดียว ไม่มีเมฆ ไม่มีป้ายแยกเหนือแถบ; held มีคำอธิบายและปุ่มคัดลอกในแคปซูลเดียว; permission มีข้อความ+ตั้งค่าในแคปซูลเดียว
- เปลี่ยน cloud เป็น native waveform 4 แท่งใน bundle/menu; idle สีดำ alpha0.38 เส้นเดียว ไม่เปลี่ยนเป็นสีส้ม
- core tests 30 ข้อผ่าน รวม single instance และ language set มีเฉพาะ TH/EN
- build และ strict codesign ของแอปที่ติดตั้งผ่าน, UI tree ยืนยัน version0.1.4 และ pathเดิม
- ย้าย pending10รายการจาก UI ของรุ่นก่อนด้วย private one-time JSON; เปิดรุ่นใหม่แล้ว UI tree แสดงครบ10 และไฟล์ส่งต่อถูกลบ ไม่มีข้อความผู้ใช้ใน binary/ZIP
- ประเมินจำลอง5บุคลิกและนำผลไปแก้: คะแนน heuristic เฉลี่ย4.8→7.8/10 ไม่ใช่ผลจากคนจริงหรือ STT benchmark
- หลัง rebuild ยังต้องดูสิทธิ์ macOS ของ binaryใหม่ตามจริง ไม่มีการเปิดไมค์/ให้สิทธิ์แทนผู้ใช้
- Probe lock ของแอปที่กำลังรันจริงถูกปฏิเสธการ acquire จาก process ที่สอง (ผ่าน); ไม่ต้องเปิดแถบตัวอย่างอีกอันเพื่อพิสูจน์
- ตรวจโมเดลโดยไม่ใช้ไมค์จาก appจริงผ่าน392msหนึ่งfixture ไม่ใช่ latencyเสียงผู้ใช้
- สถานะสุดท้ายของ binary0.1.4: mic notDetermined, AXfalse จึงยังไม่ทดสอบอัด/แทรกจริงด้วย agent

## 2026-09-08 — 0.1.5 Aura / local Q&A / speech

- Swift release build and strict installed bundle signature: passed.
- 40 core checks passed (10 added: prefix routing, start-only detection, wake-only handling, preservation, language, no tools).
- Offscreen idle/listening/processing/notice rendering: inspected; original TH/EN capsule with integrated cyan/indigo Aura, no second overlay process.
- Ollama 0.33.3 downloaded from official GitHub release, Qwen3 4B Instruct 2507 Q4_K_M pulled with digest verification. Installed separately under Application Support/Veda/qa; no paid API.
- Real QuestionBackend integration: English and Thai prefix → loopback model → nonempty answer passed; cold Thai 18.09 s, subsequent English 1.49 s. This is two text fixtures, not a latency distribution or microphone end-to-end benchmark. Thai sample has awkward wording; local answer quality still needs evaluation.
- macOS voice lookup: Kanya th-TH, Samantha en-US available. AVSpeechSynthesizer.write produced 73,402 / 31,916 PCM frames, both completed. No physical speaker playback or microphone recording performed by agent.
- Whisper public JFK fixture: 359 ms on installed 0.1.5 before final minor UI/cancel adjustment; exact fixture matched. Not a Fn latency measurement.
- Preserved 14 existing pending entries via owner-checked one-time file during upgrade. No private transcripts bundled or committed into QA report.
- Fn collision unresolved outside Veda: current source has no ×/blue arrow view; installed ChatGPT/Codex source has global dictation + Hold-to-dictate setting. Its configured hotkey not confirmed. CUA denies controlling com.openai.codex; no changes made to its settings.
- New ad-hoc binary still requires Microphone and Accessibility grants. Real Fn → audio → wake → answer → physical speaker test remains for user after those grants.
- QA routes only after transcription on Fn release. No continuous wake listening; no cross-question history or screen context. Spoken answer follows system output device.

## 0.1.6 — investigation of reported failures

- Live 0.1.5 diagnostics: microphone authorized; Accessibility missing; phase outcome held, not answering. The UI contained English transcripts and a completed local answer. This contradicts a total inference failure but does not identify the owner of the separate ×/blue-button overlay in the screenshot.
- Synthetic Kanya Thai WAV → running Whisper translation produced: “Today I want to fix the program, but do not delete the user's information.” Source wake audio produced “เวดา ช่วยอาทิบายว่าทำไมท้องฟ้าเป็นสีฟ้า”. No microphone used. Thai spelling quality still imperfect.
- Running local Qwen endpoint answered the sky-color fixture, done=true. Live user microphone-to-speaker test not performed.
- 43 core checks pass. Greeting + wake and Thai tone-mark variants now recognized. EN classifies source Thai transcription before translation; this adds a second Whisper pass to normal EN dictation.
- Wake alone prompts spoken acknowledgment and arms the next Fn utterance as a question; Escape clears it. Offline weather requests return an explicit lack-of-live-data answer, not fabricated weather.
- Settings is explicitly ordered out at Fn start. All active overlay states fixed to 116×38 pt; notices use a compact action icon. All rendered states inspected; permission state remains compact.
- Total processing watchdog 90s; local QA request/resource 60/70s. Timeout cancels stale token and returns retry notice. Independent external dictation overlays remain outside Veda's control.
- One-time upgrade preserves 24 pending entries plus last question/answer, no transcript included in app bundle.

## 2026-09-08 18:25 — duplicate installation root cause confirmed

- Process inspection found both installed 0.1.6 (PID 65407) and legacy 0.1.3 (PID 65603) running. Legacy has no single-instance lock and was launched from the old Documents/Codex project. The earlier lock check did not rule out pre-lock releases.
- Inspected legacy UI: no pending transcripts. Quit it through its Exit button. Retained running installed app and its in-memory text.
- Unregistered and reversibly moved four copies (legacy, preview, current build output, package-check) to work/retired-apps.noindex/*.bundle-backup. Remaining .app in project/old project/user Applications scan: only ~/Applications/Veda.app.
- Verified one Veda process plus one whisper-server, strict codesign passes. No rebuild/re-sign/restart of installed 0.1.6, so existing microphone authorization is preserved.
- macOS Keyboard UI showed Fn configured to Show Emoji & Symbols, Dictation off. Changed Fn action to Do Nothing using System Settings and verified value. Closed System Settings. Current Veda UI is only the idle strip.
- Build script now moves build .app into a .noindex directory with .bundle-backup extension after producing ZIP; bash syntax check passes. No new binary installed.
- Accessibility remains ungranted; no microphone capture performed by agent. Other apps' global Fn shortcuts remain independent.

## 2026-09-09 — 0.1.7 dictation only

Removed Q&A, wake routing, speech output, and QuestionBackend from app sources/build. Direct EN translation restored to one Whisper request. 30 remaining Core checks pass. Installed bundle built and codesign verified. UI restored 29 pending transcripts.

Added an always-present meter inside expanded TH/EN capsule, separate from status/copy action; fixed capsule 140×32 pt inside 146×38 pt panel. Inspected installed offscreen listening render. Reopen handler and idle-strip click reveal controls; launch verified via native app control.

Reviewed 4 sampled frames of attached 7.68 s MOV. Separate ×/blue-arrow dictation bar appears and text lands before Veda's copy state. This supports two pipelines, but does not prove which app owns the second bar.

Added normal Accessibility-gated CGEvent tap for physical Fn flags, consumes Fn only, keeps other events; timeout disables/re-enables tap and cancels hold. Actual keyboard-exclusive behavior remains untested until Accessibility is granted. No agent-generated Fn or microphone recording.

Installed Whisper /inference translate=true test using synthetic Thai speech produced “Today I want to fix the program, but do not delete the user's information.” EN engine works in this fixture; real user insertion remains blocked by permissions.

System Settings listed Veda Accessibility On, while AXIsProcessTrusted remained false for current binary. Attempt to refresh this entry raised macOS Touch ID authentication sheet. User authentication required; no bypass attempted. Microphone request made through app button but remains notDetermined. Remaining end-to-end verification requires user approval in macOS.

## 2026-09-09 — 0.1.8 usability and permission investigation

Enlarged idle line 24×3 to 44×6; expanded idle panel to 74×32 pt. Added native status-item menu with reveal/settings/quit actions. Release build, strict installed signature, 30 Core checks and offscreen idle rendering passed. Preserved 35 pending entries.

New 21.2s MOV frames show two overlays at the same time: ×/blue control bar in front, Veda TH/EN/copy behind. Existing user results include English translations while diagnostics report missing Accessibility and held output. Thus translation and insertion must not be conflated.

System Settings Veda switch remains On while running app reports AX untrusted. Attempted adding current executable via + rather than assuming cached entry grants access. macOS authentication sheet requested Touch ID before opening file picker; awaiting user authentication. No other application's permissions changed. End-to-end Fn interception/insertion remains unverified. New development signature also requires current microphone grant.

## 0.1.9 — 2026-09-09
- Fixed display centering using full display frame, with Dock clearance from visible frame. Disabled background dragging; recompute on screen configuration changes.
- Added `exclusiveFnReady` diagnostics to distinguish effective Fn interception from an enabled-looking Accessibility switch.
- Core and placement checks: 38 passed. Build and installed signature verification passed.
- Reviewed IMG_7154: Veda TH/EN strip and a separate larger recording overlay are simultaneously visible. Veda retained an English translation of the user's weather test, but insertion was held because the running app reports AX untrusted.
- Installed 0.1.9 at the existing ~/Applications/Veda.app path, preserving 39 pending entries through a private one-time migration file.
- End-to-end Fn interception/insertion remains unverified: macOS authentication is required to refresh the exact installed app's Accessibility grant. New ad-hoc build also reports microphone notDetermined; this is not a completed permission repair. Do not claim the overlapping external overlay has been eliminated.

## 0.1.10 — insertion and aura
- AXSelectedText success is now followed by value readback. Unchanged editable fields use Unicode keyboard events addressed to the original PID; focus/caret are rechecked before fallback. Clipboard is untouched and no Return shortcut is sent. Changed/unknown fields retain the transcript. End-to-end web editor input remains unverified.
- Allowed capture roles restricted to text field, text area and combo box; secure fields excluded. Removed the AXSelectedText-settable requirement because editors can accept keyboard input without that setter.
- Angular cyan/indigo/violet aura rotates in 3.2 seconds during active phases, with voice-dependent glow; Reduce Motion freezes rotation. Compact panel unchanged. Offscreen processing snapshot inspected.
- Build, signature verification and 38 existing core/placement checks passed. Those checks do not exercise Unicode delivery in the user's editor.
- Installed at existing path and migrated 40 pending entries. Fresh installed diagnostics: AX untrusted and microphone notDetermined; ad-hoc binary updates invalidate grants. User must grant the updated app through macOS before live validation. No claim of successful live insertion.

## 0.1.11 — settings redesign and real clip translation review
- Native SwiftUI sidebar separates dictation, held transcripts (newest first), and diagnostics. Permission actions only appear when missing. Technical details are collapsed. Preserved vocabulary, mode, copy/delete, backend check and quit controls.
- Compiled and inspected offscreen settings screenshot at 780 x 650 points. Build succeeded. Package is prepared; installed app remains 0.1.10 to preserve currently working macOS grants during translation investigation.
- Extracted 12.91 seconds of user-supplied IMG_7165 audio and ran local Whisper small in Thai transcription and English translation modes. Thai transcription largely reflects the spoken sentence; English incorrectly renders the conversion clause as 'make it different'. Adding vocabulary prompt did not correct the meaning. No prompt patch was adopted based on that failed experiment. Translation quality is still unresolved; this UI change is not a translation fix.

### Keychron K2 Max
- Added opt-in external F18 hold shortcut, key-down/key-up event tap and autorepeat suppression, preserving Mac Fn. Settings explain Launcher mapping. Typecheck and 38 existing checks passed; no physical K2 Max test performed.
- Keyboard firmware/mapping was not modified. Mapping physical Fn to F18 requires relocating its original layer-switch action; otherwise existing Fn combinations are lost.
- Built package includes redesign and F18 option; currently installed app has not been replaced while existing permissions are valid.

## Installed 0.1.11
User explicitly requested installation. Installed/signature verified at existing path; UI confirms 0.1.11, new sidebar and 51 restored pending transcripts. Enabled external F18 option through UI. Keyboard mapping itself remains unchanged. Fresh app reports microphone notDetermined and AX untrusted; opened diagnostics and requested microphone grant without recording. Recognition/translation quality is not fixed by this release: real IMG_7165 translation has a semantic error, and tested vocabulary did not resolve it.

## 0.1.12 — medium and language chords
- Added Fn+Space / enabled F18+Space TH/EN toggle; consumes Space key-up even after trigger release, suppresses repeat toggles, cancels active recording, and resets hold state. 56 core/placement/shortcut checks passed. Physical keyboard check still requires user.
- Installed Whisper medium (~1.5 GB) outside bundle at ~/Library/Application Support/Veda/models/ggml-medium.bin; backend prefers it, bundled small remains fallback. Actual model reported in diagnostics/latency logs.
- Real supplied IMG_7165: medium EN 'Hello everyone, I'm testing the program I wrote to change the speech into text.' Small mistranslated conversion clause. Medium TH still had spelling/loanword errors; do not claim complete accuracy.
- Generated Thai negation fixture: medium TH retained prohibition, EN 'Today I want to fix the program, but do not delete user information.' Warm single-run times ~0.92 seconds TH and ~0.61 EN; not a general benchmark.
- Preserved 56 pending transcripts during install. Prepared optional paired recording calibration instructions; no fine-tuning or speaker learning performed.
- Claude local MCP veda-project configured using official filesystem server 2026.8.31. Initialization/project read/outside-directory rejection tested. Claude restart required, client connection not yet observed. CLAUDE.md provides handoff.

## 0.1.13 / 0.1.14 — 2026-09-10 — profile page, idle capsule, held-text preservation

### สิ่งที่พบก่อนแก้
- `veda-upgrade-pending-<uid>.json` มีแต่ฝั่งอ่าน (`restoreUpgradeText`) ทั้งโปรเจกต์ไม่มีโค้ดเขียนไฟล์นี้เลย แปลว่า 0.1.12 ที่ติดตั้งอยู่ **ทำข้อความพักหายทุกครั้งที่ออกจากแอป** กลไกที่ handoff อธิบายไว้จึงยังไม่เคยทำงานจริง
- ตัวเรนเดอร์ `--render-overlays` เรนเดอร์หน้า Settings ที่ section 0 เท่านั้น หน้าโปรไฟล์จึงไม่เคยถูกตรวจด้วยภาพ และแถบพักถูกเรนเดอร์ที่ขนาด active (146x38) เสมอ ไม่ใช่ขนาด idle จริง (74x32)
- ช่องข้อความในหน้าโปรไฟล์เป็น `TextEditor` เปล่า ไม่มีพื้นหลัง ขอบ หรือ placeholder ต่างจากช่องคำศัพท์ในหน้าการพิมพ์ด้วยเสียงที่มีพื้นหลังอยู่แล้ว
- ปุ่มยังเขียนว่า "เลือกไฟล์เสียง WAV" และรับเฉพาะ WAV 16 kHz mono

### แก้ไข
- `PendingArchive` (Core.swift) + `preservePendingForUpgrade()` เรียกเป็นบรรทัดแรกของ `applicationWillTerminate` เขียนไฟล์ด้วย `createFile` โหมด 0600 ตั้งแต่ตอนสร้าง ไม่ผ่านไฟล์ชั่วคราวโหมด 0644 อ่านคืนได้ทั้งรูปแบบใหม่และรูปแบบ answer/question เดิม แล้วลบทิ้งหลังคืนค่า
- `pendingCount` เพิ่มใน diagnostics — เป็นจำนวนเท่านั้น ไม่มีตัวข้อความ และ `build` อ่านจาก Info.plist แทนค่าคงที่ที่เคยฝังไว้ว่า 0.1.12
- `CalibrationAudio.wav16kMono` (AudioCapture.swift) รับ m4a/mp3/wav/caf/aiff แล้วแปลงเป็น 16 kHz mono 16-bit บนเครื่องผ่าน AVAudioConverter ไฟล์ที่แปลงอยู่ใน temporary directory เฉพาะช่วงส่งคำขอเดียวแล้วลบ
- `PersonalProfile.adding/hint` และ `AudioImport.verdict` ย้ายมาเป็นฟังก์ชันบริสุทธิ์ใน Core.swift จึงทดสอบได้จริง
- ช่องข้อความทั้งหมดใช้ `editor(...)` ร่วมกัน มีพื้นหลัง ขอบมน และ placeholder
- ตัวเรนเดอร์เพิ่ม settings-profile, settings-profile-filled, settings-profile-full-page และเรนเดอร์แถบพักที่ขนาดจริงจาก `OverlayPlacement`

### ผลตรวจ
- `scripts/test.sh`: 78 ผ่าน (เดิม 56 เพิ่ม 22) ครอบคลุมการเข้ารหัส/ถอดรหัสข้อความพัก สิทธิ์ไฟล์ 0600 การตัดตัวอย่างที่ 20 ชุด การตัดช่องว่าง คำใบ้ที่ไม่ซ้ำ และเกณฑ์ความยาวเสียง
- typecheck ทั้งโปรเจกต์ผ่าน ไม่มี warning
- ทดสอบการแปลงเสียงจริง 16 ข้อผ่านทั้งหมด: AAC stereo 16 kHz, AAC stereo 48 kHz และ AIFF stereo 44.1 kHz แปลงเป็น 16 kHz mono 16-bit ครบ WAV 16 kHz mono เดิมยังใช้ได้ ไฟล์เสียหายและไฟล์ยาว 37 วินาทีถูกปฏิเสธพร้อมข้อความไทยที่อ่านรู้เรื่อง
- ตรวจหน้าโปรไฟล์ด้วยภาพทั้งสถานะว่างและมีข้อมูล และตรวจทั้งหน้าแบบเลื่อนสุด: ลำดับ ชื่อ → คำศัพท์ → ทดสอบเสียง → ผลถอดเสียง → บันทึก → การ์ดตัวอย่าง ครบและไม่ทับกัน
- แถบพักที่ขนาด idle จริง 74x32: แคปซูล 44x9 มุมต่อเนื่อง อยู่กึ่งกลาง มีระยะขอบเหลือรอบด้าน
- การบันทึกโปรไฟล์ลง UserDefaults ยืนยันแล้วจากการรันเรนเดอร์สองรอบ ค่าที่บันทึกกลับมาครบ และเขียนคนละ domain กับแอปที่ติดตั้ง (`veda-render` ไม่ใช่ `local.veda.dictation`)
- ระหว่างทำงานทั้งหมด ไม่แตะแอปที่ติดตั้ง ไม่หยุดโปรเซส 20019 และไฟล์ diagnostics ยังเป็นของแอปจริง

### ยังพิสูจน์ไม่ได้
- ยังไม่ได้ติดตั้ง 0.1.13 ยังไม่มีการทดสอบ Fn จริง การแทรกข้อความจริง หรือความแม่นของการถอดเสียงในรุ่นนี้
- เส้นทางเก็บ/คืนข้อความพักผ่านการปิดแอปจริงยังไม่ได้ทดสอบ ทดสอบได้เฉพาะการเข้ารหัสและสิทธิ์ไฟล์
- ข้อความพักที่ค้างอยู่ใน 0.1.12 ตอนนี้ยังกู้ไม่ได้ด้วยกลไกนี้ เพราะไบนารีที่รันอยู่ไม่มีฝั่งเขียน ต้องคัดลอกออกเองก่อนปิดแอป

### 0.1.14 — บั๊กที่การทดสอบจริงจับได้ และผลติดตั้ง
ตอนทดสอบวงจรเก็บ/คืนจริงกับแอปที่ติดตั้ง 0.1.13 พบว่า `preservePendingForUpgrade` ที่เพิ่งเขียน **ลบไฟล์เก็บข้อความทิ้งเมื่อปิดแอปตอนไม่มีข้อความค้าง** ซึ่งทำลายไฟล์ที่รอบก่อนหน้าเขียนไว้แต่ยังไม่ถูกคืน — เป็นข้อมูลชนิดเดียวกับที่กลไกนี้มีไว้เพื่อปกป้อง unit test ชุดเดิมไม่จับ เพราะการเขียนไฟล์อยู่ใน main.swift ที่เทสต์เข้าไม่ถึง
- แก้โดยย้ายการเขียนไปเป็น `PendingArchive.save(_:to:)` ใน Core.swift การเขียนตอนไม่มีข้อความคืนค่า false และไม่แตะไฟล์เดิม
- เพิ่มเทสต์ถดถอย 4 ข้อ รวมเป็น 82 ข้อผ่านทั้งหมด เทสต์ชุดใหม่นี้จับบั๊กเดิมได้
- ติดตั้ง 0.1.14 แล้ว: Info.plist 0.1.14 build 15, `codesign --verify --deep --strict` ผ่าน, มีสำเนาเดียวที่ ~/Applications/Veda.app, Spotlight เห็นเฉพาะตัวนี้

### ทดสอบวงจรข้อความพักกับแอปที่ติดตั้งจริง (0.1.14)
- วางไฟล์เก็บ 0600 ตอนแอปปิด → เปิดแอป → `pendingCount` เป็น 1 และไฟล์ถูกลบหลังคืนค่า
- ปิดแอปขณะมีข้อความค้าง 1 รายการ → ไฟล์ถูกเขียนกลับ สิทธิ์ 600 เนื้อหาตรงทุกตัวอักษร
- วางไฟล์ที่ยังไม่ถูกคืนขณะแอปรันโดยถาดว่าง → ปิดแอป → ไฟล์ยังอยู่ครบ (บั๊กเดิมจะลบทิ้ง)
- ข้อความที่ใช้ทดสอบทั้งหมดเป็นข้อความที่สร้างขึ้นเอง ไม่ใช่ข้อความของผู้ใช้ และลบออกหมดแล้ว
- ผู้ใช้ยืนยันก่อนติดตั้งว่าไม่มีข้อความพักค้างใน 0.1.12 จึงไม่มีข้อความใดสูญหายจากการอัปเดตนี้

### สิ่งที่ผู้ใช้ต้องทำต่อ
การเซ็นแบบ ad-hoc ทำให้ TCC เดิมใช้ไม่ได้ตามที่บันทึกไว้ล่วงหน้า ปัจจุบัน diagnostics แสดง `microphone: ยังไม่เคยขอ`, `accessibility: ยังไม่ได้รับอนุญาต`, `exclusiveFnReady: false` ต้องอนุญาต Microphone และ Accessibility ให้ Veda ใหม่ผ่านหน้าต่างของ macOS เอง แล้วค่อยทดสอบ Fn จริง

## 0.1.15 — 2026-09-10 — Thai accuracy: model comparison and orthographic repair

### หลักฐานก่อนแก้ (medium, คลิปทดสอบ 3 คลิปในเครื่อง)
ข้อผิดพลาดเป็นระดับโมเดล ไม่ใช่ Unicode: ท้องฟ้า→ทองฟ้า (EN กลายเป็น "blue gold"), แก้ไข→แก้ไข่, โปรแกรม→โปรแกม ลอง `-bs 5 -sns -mc 0` บน medium แล้วผลเท่าเดิม ช้าขึ้น ~10% จึงไม่นำมาใช้

### เปรียบเทียบโมเดล (เสียงเดียวกัน, warm-up แล้ว, whisper-server แยกพอร์ต ไม่แตะแอปที่รัน)
| | TH ผิด/5 จุด | แปล EN | latency TH |
|---|---|---|---|
| medium | 3 | ความหมายผิดตามไทยที่ผิด | 0.8–1.1 s |
| large-v3-turbo | 2 + ผิดใหม่ (แปลง→แปรง, ทิ้ง "เวดา") | **แปลไม่ได้ พ่นไทยกลับ** | 0.9–1.0 s |
| large-v3 | 1 (ทองฟ้า ทั้งสามตัวพลาดเหมือนกัน) | ถูกความหมาย ("why the sky is blue") | 1.5–2.3 s |

เลือก large-v3 · turbo ตกรอบเพราะโหมด EN ใช้ไม่ได้ · ลำดับเลือกโมเดลใน `LocalBackend.start`: large-v3 > medium > small ตามไฟล์ที่มีใน Application Support/Veda/models (ลบไฟล์เพื่อถอยกลับ)

### จุดเพี้ยนที่แก้แบบ deterministic
large-v3 พ่น `คําพูด` (NIKHAHIT+SARA AA) แทน `คำพูด` — เพิ่ม `ThaiText.normalized` ใน Core.swift เรียกจาก `BackendRequest.cleaned` ทุกโหมด: ประกอบ ำ, จัดลำดับสระ/วรรณยุกต์ตามมาตรฐาน, ตัด zero-width, ยุบเครื่องหมายซ้ำ กฎทุกข้อแปลงการเข้ารหัสของพยางค์เดียวกันเท่านั้น ไม่แก้คำผิด (มีเทสต์ยืนยันว่า แก้ไข่ ถูกปล่อยไว้)

### ผลตรวจ
- test.sh 91 ข้อผ่าน (เพิ่ม 9) typecheck สะอาด
- ติดตั้ง 0.1.15 build 16 ตัวเก็บข้อความพักทำงานกับข้อความจริงของผู้ใช้: ก่อนปิด pendingCount 2 → ไฟล์ 600 มี 2 รายการ → หลังเปิด pendingCount 2 ไฟล์ถูกลบ · diagnostics `model: large-v3`, whisper-server โหลด ggml-large-v3.bin
- ยังไม่มี signing identity ในเครื่อง (`security find-identity` = 0) ad-hoc ต่อไป ต้องขอสิทธิ์ใหม่หลังติดตั้ง

### ยังพิสูจน์ไม่ได้
- ความแม่นวัดจากคลิปเก่า 3 คลิปเท่านั้น ผู้ใช้จะอัด 6 ประโยคตาม calibration/README.md เพื่อวัดซ้ำ ยังห้ามอ้างว่า "แม่นขึ้น" กับเสียงผู้ใช้
- latency ในแอปจริงของ large-v3 หลัง Fn ยังไม่ได้วัด (วัดได้เฉพาะผ่าน HTTP: ~2 เท่าของ medium)
- การแทรกข้อความลงช่องแชต Claude desktop ล้มเหลว 2 ครั้ง ("เป้าหมายเปลี่ยนหรือช่องไม่รองรับ Accessibility") ยังไม่ได้วิเคราะห์ role ของ composer (Electron/ProseMirror)

## 0.1.16 — 2026-09-10 — drag-and-drop calibration audio, 2-minute limit
- การ์ด "ทดสอบเสียงของฉัน" รับไฟล์ที่ลากจาก Finder ผ่าน `.onDrop(of: [.fileURL])` โซนวางมีกรอบประและไฮไลต์ตอนลากทับ ใช้ `importCalibration(url:)` ร่วมกับปุ่มเลือกไฟล์ ปิดใช้งานเงื่อนไขเดียวกัน (ต้อง idle, backend พร้อม, ไม่ได้กำลังทดสอบ)
- ขีดจำกัดความยาวขยาย 30 → 120 วินาที เพราะผู้ใช้อัดรายการคาลิเบรตรวดเดียวจาก MOTIV Mix (MV7+) เทสต์ปรับตาม: 48 วินาทีรับได้, 160 วินาทีปฏิเสธพร้อมบอกความยาว
- test.sh 92 ข้อผ่าน ตรวจโซนวางด้วยภาพใน ui-check/settings-profile-filled.png
- ติดตั้ง build 17 ข้อความพัก 4 รายการจริงถูกเก็บ (600) และคืนครบ · ต้องขอสิทธิ์ใหม่อีกครั้ง (ad-hoc)
- ยังไม่ได้ทดสอบการลากไฟล์จริงบนเครื่องผู้ใช้ และยังไม่ได้วัดความแม่นกับไฟล์ที่ผู้ใช้อัด

## 0.1.17 — 2026-09-10 — file drop actually works on the transcript box
- ผู้ใช้ลากไฟล์ลงกล่อง "พิมพ์ประโยคที่คุณพูด" แล้ว NSTextView แทรก path เป็นข้อความ (ภาพหน้าจอยืนยัน) โซนวางแบบแถบเล็กใน 0.1.16 จึงไม่พอ
- เพิ่ม `FileDropTextView` (NSViewRepresentable) override `draggingEntered/Updated/performDragOperation`: ถ้า pasteboard มี file URL ส่งให้ `importCalibration(url:)` ไม่แทรก path; การพิมพ์และวางข้อความปกติยังเหมือนเดิม และ `.onDrop` ครอบทั้งการ์ด
- test.sh 92 ผ่าน เรนเดอร์การ์ดเหมือน 0.1.16 ทุกประการ · ติดตั้ง build 18 ข้อความพัก 4 รายการคืนครบ · ต้องขอสิทธิ์ใหม่ (ผู้ใช้เพิ่งให้ 0.1.16 ไป — รอบนี้เป็นค่าใช้จ่ายของบั๊กผม)
- หมายเหตุเครื่องมือ: `swiftc -typecheck` ต้องใช้ `-module-cache-path` แบบ absolute ไม่งั้น module cache ชนกัน (signal 11) ไม่ใช่ปัญหาโค้ด
- ยังไม่ได้ทดสอบการลากจริงบนเครื่องผู้ใช้กับ build นี้

## 2026-09-10 — ผลวัดกับเสียงจริงของผู้ใช้ (MV7+, 32.8 s, 6 ประโยคจาก calibration/README.md)
อ้างอิง = ข้อความใน README ตัดช่องว่าง 274 อักขระ · ไฟล์แปลงเป็น 16 kHz mono ใน scratchpad ของเซสชันเท่านั้น ไม่คัดลอกเข้า repo
| | CER | ถ้านับตัวเลขที่อ่านเป็นคำไทยว่าถูก | latency (ทั้งไฟล์) |
|---|---|---|---|
| medium | 20.8% (57) | 19.3% | 2.9 s |
| large-v3 | **9.9% (27)** | **2.2% (6)** | 6.0 s |
medium ผิดระดับคำ: Keyboard, เหลือบรอย, โค**ตร**, โปรกันต์/โปรกัน, แก้ไข่, คอต(Claude) และทิ้งประโยค "ทดสอบหนึ่ง…ห้า" ทั้งประโยค · large-v3 เหลือ: "Claude"→คอร์ด, ช่องว่างหลัง Swift/TypeScript, ตัวเลขเป็น 1 2 3 4 5 / 9 (อ่านถูกแต่เขียนเป็นเลข)
สรุป: large-v3 ลดข้อผิดพลาดอักขระบนเสียงผู้ใช้ลง ~2 เท่า (และ ~9 เท่าถ้าไม่นับรูปแบบตัวเลข) แลก latency ~2 เท่า · ชื่อเฉพาะ "Claude" เป็นงานของช่องคำศัพท์ส่วนตัว ไม่ใช่ตัวแทนที่ข้อความ · ยังเป็นการวัด 1 ไฟล์ 1 ครั้ง ไม่มี held-out

## 0.1.18 — 2026-09-10 — q5_0, EN check, measured latency options, hold diagnostics, re-scorable examples

### ผลวัดที่ตัดสินใจจาก (เสียงเดียวกัน 4 ไฟล์ รวมเสียงผู้ใช้ 32.8 s)
| ตัวเลือก | ผลลัพธ์ | latency (ไฟล์ผู้ใช้ / คลิปสั้น) | ตัดสิน |
|---|---|---|---|
| large-v3 (f16, 3.1 GB) | อ้างอิง | 5.85 s / 1.5–2.2 s | — |
| **large-v3-q5_0 (1.08 GB)** | **ตรงกับ f16 ทุกตัวอักษร ทั้ง TH และแปล EN** | **4.16 s / 1.3–1.7 s** (เร็วขึ้น 15–29%) | ใช้ |
| `--audio-ctx 1024` | เร็วขึ้น 25% แต่**ทิ้งประโยคทั้งประโยคเงียบ ๆ** บนไฟล์ 32 s | 4.36 s | ปฏิเสธ |
| `--audio-ctx 768` | ทิ้งมากกว่า + Keychron→คีย์คลอน | 3.60 s | ปฏิเสธ |
| beam 5 + sns (บน medium ก่อนหน้า) | ไม่ต่าง ช้าขึ้น 10% | — | ปฏิเสธ |

### แปลไทย→อังกฤษ (เสียงผู้ใช้)
medium: "This program must change the voice. Thai is English." (ความหมายพัง), "keycron", Claude→"the code" · large-v3/q5_0: ทุกประโยคถูกความหมาย รวม negation "do not delete user information" และ "translate the sound of Thai into English" · ผิดเหลือ Claude→"Cod" (ชื่อเฉพาะ ทั้งสองโมเดล)

### เพิ่มใน build นี้
- ลำดับโมเดล large-v3-q5_0 > large-v3 > medium > small (ไฟล์ f16 ยังอยู่ใน models/ เป็น fallback)
- `holdReason` ใน diagnostics: บอกว่าพักเพราะไม่มีเป้าหมายตอนกด Fn (พร้อม role ที่ปฏิเสธ), โฟกัสเปลี่ยน, ค่า/เคอร์เซอร์ต่างตอนได้ผล, หรือ insert ล้มที่ขั้นไหน (AXSelectedText rc / key fallback read-back) — เฉพาะ role และขั้นตอน ไม่มีข้อความ
- `Target.capture` รับช่องที่ role ไม่อยู่ในรายการถ้า AXSelectedText ตั้งค่าได้และมี caret+value (web editor) การอ่านค่ากลับหลังแทรกยังคุมเหมือนเดิม
- `Veda --probe-focus`: รอ 3 วินาทีแล้วรายงาน role/caret ของช่องที่โฟกัส ใช้ไบนารีที่ติดตั้ง (ตัวเดียวที่มีสิทธิ์ AX)
- ตัวอย่างในโปรไฟล์เก็บ**ตำแหน่ง**ไฟล์เสียง + ชื่อโมเดล (ไม่คัดลอกไฟล์) ปุ่ม "วัดซ้ำด้วยโมเดลปัจจุบัน" รันทุกตัวอย่างที่ไฟล์ยังอยู่แล้วอัปเดตผล · `Accuracy.characterErrorRate` ใน Core (ตัดช่องว่าง, normalize ไทยก่อนเทียบ) แสดง % ผิดต่อตัวอย่างและเฉลี่ย · diagnostics `profileCER` (‰), `profileExamples`, `profileModel`
- โพรบ AX จากโปรเซสภายนอกใช้ไม่ได้ (`trusted: false`) จึงย้ายการวินิจฉัยเข้าแอป
- git: commit แรกของโปรเจกต์ (4a885bb) .gitignore กัน work/, zip, โมเดล, whisper-server

### ผลตรวจ
- test.sh 101 ผ่าน (เพิ่ม CER 7, example record 2) typecheck สะอาด · เรนเดอร์การ์ดความแม่นและตัวอย่าง (ui-check)
- ติดตั้ง build 19: ข้อความพัก 5 รายการคืนครบ · `model: large-v3-q5_0` · `profileExamples: 1, profileCER: 95` (9.5%) ตรงกับที่วัดนอกแอป (9.9% ต่างที่การตัดช่องว่าง)

### ยังพิสูจน์ไม่ได้
- Claude desktop: ยังไม่มี holdReason จริง ต้องให้ผู้ใช้พูดลงช่องแชตหนึ่งครั้งหลังให้สิทธิ์ แล้วอ่าน diagnostics
- streaming ระหว่างกด Fn ยังไม่ได้ทำ: whisper-server ไม่รองรับ input แบบ incremental และตัวเลือกลด encoder (`audio-ctx`) ทิ้งเนื้อหา ทางที่เหลือคือ warm-up/keep-alive หรือ engine อื่น ต้องวัดก่อน
- held-out 3 ประโยคของผู้ใช้ยังไม่มี

## 0.1.19 — 2026-09-10 — Claude desktop insertion, from evidence
- `holdReason` จากการพูดลงช่องแชต Claude จริง: `insert: key events sent; read-back different from expected (role AXTextArea)` — ช่องรับได้ (AXTextArea), AXSelectedText ไม่มีผล, key events ทำให้ค่าในช่อง**เปลี่ยน**แต่ไม่ตรงสตริงที่ทำนาย (editor แบบ ProseMirror จัดรูปข้อความใหม่) แอปจึงตีเป็นล้มเหลวและพักซ้ำ
- เพิ่ม `Insertion.succeeded` (Core): สำเร็จเมื่อค่าในช่องเปลี่ยนจากเดิมและมีข้อความที่พิมพ์อยู่ในนั้น (ตัดช่องว่าง/บรรทัด, normalize ไทย) หรือมีสำเนาเพิ่มขึ้นหนึ่งชุด ยังไม่นับถ้าช่องไม่เปลี่ยน/อ่านไม่ได้/ข้อความอยู่แล้วก่อนพิมพ์ — 8 เทสต์ รวม 109 ผ่าน
- ติดตั้ง build 20 ข้อความพัก 6 คืนครบ · ยังไม่ได้ยืนยันกับ Claude จริงหลังแก้ และยังไม่รู้ว่าครั้งที่ล้ม ข้อความปรากฏในช่อง Claude หรือไม่ (ถามผู้ใช้)
- ตัวอย่างข้อผิดพลาด code-switching จากผู้ใช้: "Voice to Text"→"Void2Text", "Claude"→"คลอส", "ทดสอบ"→"สดสอบ" — คำอังกฤษในประโยคไทยเป็นจุดอ่อนที่ vocabulary hint ไม่ช่วย
- ตัวอย่างในโปรไฟล์ที่บันทึกก่อน 0.1.18 ไม่มีตำแหน่งไฟล์ → ปุ่มวัดซ้ำรายงาน "ไม่มีตัวอย่างที่ยังหาไฟล์เสียงเจอ" ตามคาด ต้องบันทึกใหม่

## 0.1.20 — 2026-09-10 — held-out set exposes a silent omission from `-nt`

### เสียง held-out ของผู้ใช้ (6 ประโยคงานจริง 37.4 s, ตำแหน่งไฟล์จากตัวอย่างในโปรไฟล์ ไม่คัดลอก)
- แอป (q5_0, `-nt`) ให้ CER **23.1%** และ**ทิ้งประโยคที่ 5 ทั้งประโยค**: segment แรกจบที่ 25.0 s, segment ถัดไปเริ่ม 30.76 s — เสียงระหว่างนั้นหายเพราะไม่มี timestamp token ให้ decoder รู้ตำแหน่งที่รอยต่อหน้าต่าง 30 s
- เปิด timestamps (ถอด `-nt`): ครบทุกประโยค CER **10.7%** (7.1% ถ้านับตัวเลข "12/3/4" เท่ากับ "สิบสอง/สาม/สี่") ประโยค 2 ถูก 100% · latency คลิปสั้นเท่าเดิม (1306→1308 ms) ไฟล์ยาว +7–9% · `-nth 0.9 -nf` ไม่เปลี่ยนอะไร
- ข้อผิดที่เหลือเป็นคำอังกฤษในประโยคไทยทั้งหมด: main.swift→"Main Swift", Claude→คลอส, Codex→Codec, Voice to Text→Voice2Tech, Keychron→Keycon, โฟลเดอร์→folder
- ตัวอย่างชุด README วัดซ้ำด้วย timestamps: เท่าเดิม (ไม่มีรอยต่อ 30 s ที่มีเสียง)

### แก้
- ถอด `-nt` จาก `LocalBackend.start` · `BackendRequest.cleaned` รวมบรรทัดจาก segment เป็นช่องว่างก่อนเสมอ (artifact ของ decoder ไม่ใช่สิ่งที่ผู้ใช้พูด) 3 เทสต์ รวม 112 ผ่าน
- ผู้ใช้ยืนยันว่า 0.1.19 แทรกลงช่องแชต Claude ได้ และการล้มก่อนหน้าคือข้อความปรากฏในช่องแต่ถูกพักซ้ำ — ตรงกับที่ holdReason บอก
- ติดตั้ง build 21 ข้อความพัก 6 คืนครบ whisper-server รันโดยไม่มี -nt · diagnostics `profileCER 152` ยังรวมผลเก่าของตัวอย่าง 2 จนกว่าจะกดวัดซ้ำ

## 0.1.21 — 2026-09-10 — icon consistency, approved terms, Snap Translate

### ไอคอน
- Launch Services ลงทะเบียน Veda.app ไว้ 2 path (staging `outputs/Veda/Veda.app` ที่ถูกย้ายออกไปแล้ว + ตัวติดตั้ง) → ถอนทะเบียน staging และซาก 0.1.0 ใน /private/tmp (ลบแล้ว) แล้ว `lsregister -f` ตัวติดตั้ง เหลือ path เดียว · ต้องเปิด System Settings ใหม่จึงจะเห็นผล
- โลโก้ในแถบข้างเคยเป็น SF Symbol "waveform" ต่างจากไอคอน → `WaveformMark` (Visuals) วาด 4 แท่งสัดส่วนเดียวกับไอคอน (220:500:350:160)

### คำที่อนุมัติ (ข้อ 4)
- `TermCorrections.apply` แทนที่เฉพาะตัวสะกดที่อนุมัติ: คำละติน = ทั้งคำ ไม่สนตัวพิมพ์; คำไทย = ตรงตัว; ยาวก่อนสั้น ใช้ตอนพิมพ์ด้วยเสียงเท่านั้น ไม่แตะ "โมเดลได้" ในตัวอย่าง (คะแนนต้องสะท้อนโมเดล) · คำที่ถูกถูกเติมเข้าคำใบ้ให้โมเดลด้วย · เก็บสูงสุด 50 คู่ใน UserDefaults `profileTerms`

### Snap Translate (⌘⇧2)
- ดักใน CGEvent tap เดิม (keycode 19 + ⌘⇧ ไม่มี ⌃⌥) กลืนทั้ง down/up · `screencapture -i -s -x` ให้ระบบวาดกรอบเลือกเอง · Vision `VNRecognizeTextRequest` th-TH+en-US accurate · ทิศทางจากสัดส่วนอักษรไทย/ละติน · Apple Translation ผ่าน `.translationTask` (ที่เดียวที่มี session) `prepareTranslation()` ให้ macOS ขอโหลดแพ็กภาษาครั้งแรก · แผงลอย 560x380 บนจอที่เมาส์อยู่ มีสลับทิศทาง/คัดลอก/Esc · ภาพ PNG ชั่วคราวถูกลบทันทีหลัง OCR ไม่มีข้อความหรือภาพถูกเก็บ · diagnostics `snapLast` (ขั้นตอน+เวลา ไม่มีข้อความ), `screenRecording`
- ตรวจความเป็นไปได้ก่อนเขียน: Vision รองรับไทย (30 ภาษา), `LanguageAvailability` th↔en = supported, สคริปต์ probe ต้องรัน RunLoop ไม่ใช่ semaphore
- ต้องขอ Screen Recording เพิ่ม (TCC ใหม่อีกหนึ่งรายการ)

### ผลตรวจ
- test.sh 121 ผ่าน (TermCorrections 5, SnapText 4) typecheck สะอาด · เรนเดอร์: โลโก้, การ์ดคำอนุมัติ, การ์ด Snap, หน้าต่าง Snap (ครั้งแรกโปร่ง → เพิ่มพื้นหลัง window ให้ตัวหนังสืออ่านได้ทุกกรณี)
- ติดตั้ง build 22 ข้อความพัก 6 คืนครบ · Screen Recording ยังไม่ได้ให้ (`screenRecording: false`)
- ยังไม่ได้ทดสอบ Snap Translate จริง (ต้องให้สิทธิ์และโหลดแพ็กภาษาโดยผู้ใช้) และยังไม่ได้ทดสอบว่าคำอนุมัติทำงานตอนพิมพ์จริง

## 0.1.22 — 2026-09-10 — Snap Translate card redesign, custom shortcut (default ⇧⌘3)
- ผู้ใช้ยืนยัน 0.1.21 ทำงานครบวง ("invited" → "ได้รับเชิญ") และไอคอนในรายการ Accessibility ตรงกับไอคอนจริงแล้ว
- ⌘⇧2 ชนกับ Shottr → `SnapShortcut` (Core) รับคีย์+modifier ใดก็ได้ เก็บเป็น "cmd+shift+20" ปฏิเสธคีย์เปล่าที่ไม่มี modifier · ค่าเริ่มต้น ⇧⌘3 ตามคำขอ (ซ้ำกับแคปทั้งจอของ macOS — Veda กลืนใน CGEvent tap ก่อน; ยังไม่ได้พิสูจน์ว่าระบบไม่แคปซ้อน ถ้าซ้อนให้ผู้ใช้ปิดใน System Settings) · ปุ่ม "เปลี่ยนปุ่มลัด" บันทึกคอร์ดถัดไปผ่าน local monitor ขณะหน้าตั้งค่าเป็น key, Esc ยกเลิก · 7 เทสต์ รวม 128
- การ์ดผลลัพธ์ออกแบบใหม่: borderless 440pt มุมมน 16 วัสดุ ultra-thin + ขอบ 1px + เงา · ป้ายทิศทาง "TH → EN" แบบ pill · ต้นฉบับ 13pt สีรอง จำกัด 4 บรรทัด · คำแปล 17pt medium เป็นจุดเด่นเดียว · ปุ่ม filled "คัดลอกคำแปล" โผล่เมื่อแปลเสร็จ กดแล้วเป็น "คัดลอกแล้ว" สีเขียว 1.6 s · สลับทิศทาง/ปิดเป็นไอคอน ghost · โผล่ล่างขวาของเคอร์เซอร์ตรงจุดที่ลากเสร็จ ไม่หลุดขอบจอ · สูงตามเนื้อหา (150–520) เกินนั้นเลื่อนใน card
- ปิดเอง: คลิกที่ใดก็ได้นอก card (global mouse monitor ที่มีอยู่แล้ว) หรือ Esc
- เรนเดอร์ snap.png และหน้าตั้งค่าตรวจแล้ว · ติดตั้ง build 23 ข้อความพัก 6 คืนครบ · ต้องขอสิทธิ์ใหม่ (Microphone, Accessibility, Screen Recording)

## 0.1.23 — 2026-09-10 — HID-level tap for ⇧⌘3, relaunch for Screen Recording, spoken translation
- หลักฐานจาก 0.1.22: `snapLast = "screen recording not granted"` แม้สวิตช์เปิดแล้ว (สิทธิ์นี้มีผลเฉพาะโปรเซสใหม่) และไฟล์แคปของ macOS เกิดพร้อมกัน → tap ระดับ session ไม่ทัน symbolic hotkey ของระบบ
- `installFnTap` ลอง `.cghidEventTap` ก่อน ถ้าสร้างไม่ได้ถอยมา `.cgSessionEventTap` · diagnostics `tapLevel` = hid/session/none (ยังพิสูจน์ไม่ได้ว่า HID ถูกอนุญาตและกัน ⇧⌘3 ของระบบได้ ต้องดูหลังผู้ใช้ให้สิทธิ์ Accessibility)
- การ์ด Snap: สถานะ Screen Recording เปลี่ยนเป็น "ยังไม่มีผลในโปรเซสนี้" + ปุ่ม "เปิด Veda ใหม่" (`relaunch()`: sh -c "sleep 1; open …" แล้ว terminate → ข้อความพักถูกเก็บผ่านเส้นทางเดิม)
- อ่านออกเสียงคำแปล: Toggle `snapSpeak` (ค่าเริ่มต้นปิด) → `AVSpeechSynthesizer` เสียงตามภาษาปลายทาง (en-US / th-TH) บนเครื่อง · ปุ่มลำโพงบนการ์ดกดอ่าน/หยุดได้ · หยุดเมื่อปิดการ์ดหรือสลับทิศทาง · หมายเหตุ: TTS สำหรับการพิมพ์ด้วยเสียงยังถูกถอดตามคำสั่งเดิม อันนี้เป็น TTS ของ Snap Translate ตามคำขอใหม่
- test.sh 128 ผ่าน typecheck สะอาด เรนเดอร์แล้ว · ติดตั้ง build 24 ข้อความพัก 6 คืนครบ · ต้องขอสิทธิ์ใหม่ทั้งสาม

## 0.1.24 — 2026-09-10 — second capture in the same direction, card size, voice choice
- ผู้ใช้ยืนยัน 0.1.23: หลัง "เปิด Veda ใหม่" Screen Recording มีผล และ diagnostics ก่อนปิด 0.1.23 บันทึก `tapLevel = hid` → macOS ยอมให้สร้าง tap ระดับ HID
- บั๊กจริงที่ผู้ใช้เห็นเป็น "อ่านออกเสียงแล้วค้าง": แคปครั้งที่สองใน**ทิศทางเดิม** ค้างที่ "กำลังแปล…" เพราะ `translationTask` ไม่รันใหม่เมื่อ configuration เท่าเดิม → `invalidate()` ทุกครั้งใน `begin`
- การ์ดเล็ก/ตัดคำแปล: ความสูงเคยมาจาก `fittingSize` ของ ScrollView → วัดเนื้อหาจริงด้วย PreferenceKey แล้ว `resize()` (46 + body ≤380 + 28 + footer 62) กว้าง 560 ต้นฉบับ 14pt คำแปล 19pt
- เสียงอ่าน: เครื่องนี้มีเฉพาะเสียงระดับ default (อังกฤษหลายตัวรวมเสียงตลก, ไทยมี Kanya ตัวเดียว) กฎเลือก: enhanced/premium ถ้ามี ไม่งั้นเสียงมาตรฐานของภาษาจากระบบ (`AVSpeechSynthesisVoice(language:)`) ไม่มีทางสุ่มโดนเสียงตลก
- ติดตั้ง build 25 ข้อความพัก 6 คืนครบ · ยังไม่ได้ยืนยัน: การ์ดขนาดใหม่บนจอจริง, แคปซ้ำทิศทางเดิมผ่าน, เสียงอ่านไทยดังจริง

## 0.1.25 — 2026-09-10 — second capture really translates; watchdog; larger card
- ผู้ใช้รายงานซ้ำว่าครั้งที่สองค้าง "กำลังแปล…" บน 0.1.24 · diagnostics `snapLast = "capturing"` = ไม่เคยถึงขั้นแปล
- สาเหตุจริง: `TranslationSession.Configuration` ตัวใหม่ที่ invalidate หนึ่งครั้ง **เท่ากับ** ตัวก่อนหน้า (ภาษาเดิม version เท่ากัน) → `.translationTask` เห็นว่าไม่เปลี่ยน ไม่รัน · แก้: เก็บ configuration ตัวเดิมต่อทิศทาง แล้ว `invalidate()` บนตัวเดิมให้ version เพิ่มทุกครั้ง สร้างใหม่เฉพาะเมื่อภาษาเปลี่ยน
- กันค้างทุกกรณี: watchdog 20 วินาที → สถานะ "ตัวแปลไม่ตอบ" + ปุ่ม "ลองอีกครั้ง" · `onStage` เขียน diagnostics ทุกขั้น (ocr/translated/stalled) แทนเฉพาะตอนจบ
- การ์ด 640pt ต้นฉบับ 15pt คำแปล 22pt ตามที่ผู้ใช้บอกว่ายังเล็ก
- ติดตั้ง build 26 ข้อความพัก 6 คืนครบ · รอบก่อนหน้าติดตั้งพลาดเพราะ path สัมพัทธ์หลัง cd — สคริปต์ติดตั้งต้องเรียกด้วย path เต็มเสมอ
- ยังไม่ได้ยืนยันบนเครื่องผู้ใช้ว่าครั้งที่สองแปลออก

## 0.1.26 — 2026-09-10 — from the persona review: loose selection picker, suggested terms, counter, setup card
- **Snap picker ของ Veda เอง**: แคปจอที่เมาส์อยู่ครั้งเดียวผ่าน `SCScreenshotManager` (ไม่รวมหน้าต่างของ Veda, ไม่เขียนไฟล์) → OCR ทั้งจอใน background ระหว่างที่ overlay ขึ้นแล้ว → ลากกรอบ: บรรทัดใดที่กรอบแตะถูกเอาทั้งบรรทัด (`SnapLayout.lines`) · คลิกไม่ลาก: ย่อหน้าใต้เมาส์ (`SnapLayout.paragraph` จัดกลุ่มตามระยะแนวตั้ง+ซ้อนแนวนอน ข้ามคอลัมน์ได้) · แว่นขยาย 2× ข้างเคอร์เซอร์ · Esc ยกเลิก · `screencapture -i` ไม่ใช้แล้ว
- **แนะนำคู่คำจากตัวอย่าง**: `TermSuggestions.suggest` (LCS ระดับโทเคน, เสนอเฉพาะช่วงที่ต่าง 1–3 โทเคน, ไม่เสนอตัวเลขล้วนหรือต่างแค่ตัวพิมพ์, ไม่เสนอคู่ที่อนุมัติแล้ว) แสดงในการ์ดคำอนุมัติ กด "อนุมัติ" คลิกเดียว
- แถบลอยตอนถอดเสียงแสดงวินาทีที่ผ่านไป (0.1 s) แทน spinner · การ์ด "ตั้งค่าครั้งแรก · 3 ขั้น" โผล่เมื่อสิทธิ์ไม่ครบ พร้อมเหตุผลและปุ่มของแต่ละขั้น และหน้าตั้งค่าเปิดเองหลังเปิดแอป 1.5 s ถ้าสิทธิ์ไม่ครบ
- คำว่า "ข้อความพัก" → "ยังไม่ได้พิมพ์" ในทุกจุดที่ผู้ใช้เห็น · ตัดสวิตช์จัดช่องว่าง (เปิดตลอด) · สลับทิศทางย้ายเข้าเมนู ⋯ บนการ์ด (มีคัดลอกต้นฉบับด้วย)
- เทสต์ 140 ผ่าน (เรขาคณิตการเลือก 7 — จับบั๊กจัดย่อหน้าข้ามคอลัมน์ได้ก่อนติดตั้ง, คำแนะนำ 5) typecheck สะอาด เรนเดอร์แล้ว
- ติดตั้ง build 27 ข้อความพัก 6 คืนครบ · ยังไม่ได้ทดสอบ picker/แว่นขยาย/คลิกย่อหน้าบนจอจริง และยังไม่ได้ทดสอบ SCScreenshotManager กับหลายจอ

## 0.1.27 — 2026-09-10 — Snap capture back to the system picker
- ผู้ใช้ลอง picker ของ Veda (0.1.26) แล้วชอบแบบเดิมมากกว่า → กลับไปใช้ `screencapture -i -s` แล้ว OCR เฉพาะส่วนที่เลือก ภาพชั่วคราวลบทันทีหลัง OCR เหมือน 0.1.21–0.1.25
- ถอดโค้ด SnapPicker/SnapPickerView, ScreenCaptureKit, `SnapLayout.lines/paragraphs/paragraph(at:)` และเทสต์ของมันออกทั้งหมด (อยู่ใน git 7e16e72 ถ้าจะกลับมาใช้) เหลือ `SnapLayout.readingOrder` ที่เส้นทาง OCR ใช้จริง
- คงไว้จากรอบก่อน: แนะนำคู่คำ, ตัวนับวินาที, การ์ดตั้งค่า 3 ขั้น, ชื่อ "ยังไม่ได้พิมพ์", เมนู ⋯ บนการ์ด
- เทสต์ 134 ผ่าน typecheck สะอาดหลังแก้ warning captured var · ติดตั้ง build 28 ข้อความพัก 6 คืนครบ

## 0.1.28 — 2026-09-10 — slang: polite vs real-chat modes
- ตัวอย่างจากผู้ใช้: "เดือดสัส สร้าง tools" → Apple Translation ให้ "Boiling, creating tools." (ตามตัวอักษร ผิดความหมาย)
- `Slang` (Core): อภิธานตั้งต้น 46 คำ ไทย/อังกฤษ แต่ละคำมีรูปมาตรฐานสองภาษา ระดับภาษา (ปกติ/ไม่สุภาพ/หยาบ) และความหมาย · `prepare` แทนสำนวนที่รู้จักด้วยภาษามาตรฐานของภาษาต้นทางก่อนส่งแปล (ไทย: substring ยาวก่อน; อังกฤษ: ทั้งคำ ไม่สนตัวพิมพ์) · `finish` โหมดแชท: แทนคำแปลมาตรฐานกลับเป็นสแลงของภาษาปลายทาง (best effort) · ทุกการจับคู่กลายเป็นหมายเหตุใต้คำแปลพร้อมป้ายระดับภาษา ไม่มีการแทนเงียบ ๆ
- โหมด **สุภาพ** = ทุกอย่างเป็นภาษามาตรฐาน · **แชทจริง** = สแลง→สแลง คำหยาบยังหยาบและติดป้าย "หยาบ" · สลับบนการ์ดได้ทันที (แปลใหม่) · ค่าเริ่มต้น + เปิด/ปิดหมายเหตุ + อภิธานเพิ่มเอง (ของผู้ใช้ทับตั้งต้น) ในหน้าตั้งค่า
- ยังไม่ครอบคลุมพิมพ์ด้วยเสียงโหมด EN (whisper แปลตรงจากเสียง ไม่มีข้อความไทยให้แปลงก่อน) — บันทึกไว้เป็นงานถัดไปถ้าต้องการ
- เทสต์ 145 ผ่าน (สแลง 11) typecheck สะอาด เรนเดอร์การ์ดพร้อมหมายเหตุ · ติดตั้ง build 29 ข้อความพัก 6 คืนครบ · ยังไม่ได้ทดสอบกับข้อความจริงในแชตของผู้ใช้

## 0.1.29 — 2026-09-10 — the "เพิ่ม" button could never be enabled
- ผู้ใช้ถามวิธีใช้การ์ดสแลง ภาพหน้าจอแสดงปุ่ม "เพิ่ม" เป็นสีเทา · ตรวจแล้วเป็นบั๊ก: `SlangEntry.init?(_:)` ใช้ `guard let thPlain = d["thPlain"]` ซึ่งต้องการให้ **คีย์มีอยู่จริง** แต่ `newSlang` เริ่มต้นเป็น `["register": "casual"]` และ binding เขียนคีย์ต่อเมื่อผู้ใช้พิมพ์ในช่องนั้น → ถ้าไม่แตะช่อง "ไทยแบบสุภาพ"/"อังกฤษสุภาพ"/"ความหมาย" คีย์เป็น nil ปุ่มจึงเทาตลอด ทั้งที่โค้ดข้างในมี fallback `thPlain.isEmpty ? th : thPlain` อยู่แล้ว = ตั้งใจให้เป็นตัวเลือกมาตั้งแต่แรก
- แก้: บังคับเฉพาะ `th` กับ `en` (ตัดช่องว่างก่อน) ที่เหลือมีค่าเริ่มต้น (plain = คำเดิม, register = ปกติ, meaning = ว่างได้) · ป้ายช่องบอก `*` สำหรับช่องบังคับ และ "(ไม่ใส่ก็ได้)" สำหรับที่เหลือ พร้อมคำอธิบายหนึ่งบรรทัด · หมายเหตุใต้คำแปลไม่แสดงช่องว่างเมื่อไม่มีความหมาย
- เทสต์เพิ่ม 5 ข้อ รวม 150 ผ่าน (ครอบคลุมกรอกครบ/กรอกน้อยสุด/ช่องว่างล้วน/กรอกครึ่งเดียว/ตัดช่องว่าง) typecheck สะอาด
- ติดตั้ง build 30 ข้อความพัก 6 คืนครบ

## 0.1.30 — 2026-09-12 — ทำไมต้องรอ 5 วินาที และแก้อย่างไร

### สิ่งที่ตัวเลขบอก (latency.csv ของผู้ใช้ 50 ครั้ง, q5_0)
มัธยฐาน 1810 ms แต่ p90 = 5213 ms และ max 6437 ms · ดูเวลาแล้วเป็นรูปแบบชัด: **ครั้งแรกหลังทิ้งไว้หลายชั่วโมงใช้ 5–6.4 วิ ครั้งถัดไปในไม่กี่นาทีใช้ 1.7 วิ** (เช่น 12:59 = 5142 ms → 13:00 = 1725 ms → 13:03 = 1674 ms) ไม่ได้ขึ้นกับความยาวเสียง

### ทางที่วัดแล้วใช้ไม่ได้ (บันทึกไว้กันทำซ้ำ)
| ทาง | ผล |
|---|---|
| เพิ่มเธรด 4 → 6/8/10 | 1325/1318/1366/1327 ms ไม่ต่าง (Metal ทำงาน ไม่ใช่ CPU) |
| `audio_ctx` ลดขนาดหน้าต่าง | **อันตราย** ค่า 384 และ 640 ให้ข้อความขยะและช้า 6–12 วินาที; ค่าที่เร็วส่วนใหญ่ให้ข้อความ**ต่างจากเต็ม**; สูตรตามความยาว (417) ให้ขยะและช้า 9 เท่า — ยืนยันสิ่งที่เจอตอน 0.1.20 อีกครั้ง **ห้ามใช้** |
| อุ่นเครื่องด้วยคลิปเงียบ 0.2 วิ | **12699 ms** — whisper วนซ้ำกับความเงียบ |
| สตาร์ตเซิร์ฟเวอร์ใหม่แล้วยิงทันที | 1249 ms — โปรเซสที่เพิ่งเกิดไม่ช้า ปัญหาอยู่ที่โปรเซสที่รันค้างแล้วไม่ถูกใช้นาน |

### สิ่งที่ทำ
- `LocalBackend.warmUp()` ถอดเสียง **1 วินาทีแรกของ test-jfk.wav ที่มากับแอป** (เสียงพูดจริง ไม่ใช่ความเงียบ) วัดได้ ~1.0 วินาที คงที่ · `WAVClip` ใน Core ตัดคลิปและประกอบ header เอง (8 เทสต์)
- ยิงตอน **กด Fn ลง** ไม่ใช่ตอนปล่อย จึงทับกับช่วงที่ผู้ใช้กำลังพูด (ปกติ 2–5 วินาที) และยิงเฉพาะเมื่อ backend ว่างมาแล้ว ≥ 90 วินาที — ใช้งานรัว ๆ จะไม่อุ่นเลย ไม่มีต้นทุน
- คำขอจริงรอ warm-up ที่ยังค้างอยู่ให้จบก่อน (เซิร์ฟเวอร์ทำทีละคำขอ) จึงไม่แย่งคิวกันเอง
- diagnostics `warmUpMS`, `idleBeforeSec` และ latency.csv เพิ่มคอลัมน์ `idle_before_s`, `warm_up_ms`

### ยังพิสูจน์ไม่ได้ — ระบุให้ชัด
**ยังไม่ได้พิสูจน์ว่าแก้เคส 5 วินาทีจริง** เพราะจำลอง "ทิ้งไว้หลายชั่วโมง" ในห้องทดลองไม่ได้ (ทิ้งไว้ 90 วินาทีเพิ่มแค่ 1347 → 1614 ms) สิ่งที่พิสูจน์แล้วคือ: ต้นทุนอุ่นเครื่อง ~1.0 วิ สั้นกว่าเวลาพูดปกติ และเกิดก่อนปล่อย Fn · คอลัมน์ใหม่ใน latency.csv จะบอกได้เองภายในไม่กี่วันว่าค่า p90 ลดลงจริงหรือไม่ ถ้าไม่ลด แปลว่าสมมติฐานเรื่องหน่วยความจำถูกเขี่ยออกผิด และต้องหาสาเหตุใหม่
- ความเร็วกรณีปกติ (1.7 วิ) **ไม่ได้ลดลง** ในรุ่นนี้ ทางที่เหลือคือโมเดลเล็กลงหรือ engine อื่น ซึ่งแลกความแม่น

## 0.1.31 — 2026-09-17 — เทียบกับ openai/whisper ต้นทาง แล้ววัดบนเสียงผู้ใช้

### สิ่งที่เอกสารต้นทางบอก vs สิ่งที่ Veda ทำ
| หัวข้อ | openai/whisper | Veda (whisper.cpp) | วัดแล้ว |
|---|---|---|---|
| โมเดล | large = 1550M ดีสุด; turbo แปลไม่ได้ ("will return the original language even if --task translate") | large-v3 q5_0 ✓ | ตรงกับที่ Veda เจอเอง (turbo ตกรอบ) |
| การถอดรหัส | ค่าเริ่มต้น CLI beam_size 5 / best_of 5 | greedy (bs −1, bo 2) | **beam 5 แย่ลง**: README 11.3→12.8%, งานจริง 10.7→12.4% และช้าขึ้น 20–25% → คงเดิม |
| temperature fallback / thresholds | (0,0.2,…,1.0), compression 2.4, logprob −1.0, no-speech 0.6 | เหมือนกันทุกค่า (entropy 2.4 = compression 2.4) | — |
| suppress non-speech tokens | ค่าเริ่มต้นเปิด (suppress_tokens "-1") | ปิด | `-sns` ไม่เปลี่ยนผลเลย → ไม่ต้องแตะ |
| initial_prompt | กลไกที่เอกสารระบุสำหรับชื่อ/คำเฉพาะ ต่อหน้าเป็นบริบทก่อนหน้า (จำกัดครึ่ง context) | ส่ง `prompt` = คำศัพท์ + คำที่อนุมัติ | **ตัวเดียวที่ได้ผล**: รายการคำ 10.7→**8.0%** (digits-ok 7.1→4.4%); prompt แบบประโยค**หลอนชื่อ** ("ฉันใช้ Claude"→"ฉันใช้ Codex") ห้ามใช้ |
| หน้าต่าง 30 วิ, 16 kHz mono | ✓ | ✓ (ถอด -nt แล้วตั้งแต่ 0.1.20) | — |
| ภาษาไทย | กราฟทางการวัดเป็น CER (ตัวเอียง) ไม่ใช่ WER; model card: ภาษาที่ข้อมูลน้อยแม่นน้อยกว่า, hallucination/repetition เป็นข้อจำกัดที่รู้อยู่ | วัด CER เหมือนกัน | ข้อผิดที่เหลือเกือบทั้งหมดคือคำอังกฤษในประโยคไทย (code-switching) ซึ่ง prompt คือทางเดียวที่เอกสารให้ |

### ข้อความเต็ม (q5_0, งานจริง 37.4 s)
- ไม่มี prompt: Main Swift · คลอส · Codec · Voice2Tech · Keycon · folder
- รายการคำ: main.swift ✓ · Codex ✓ · Voice to Text ✓ · Keychron ✓ · ยังผิด: คลอส (Claude), folder (โฟลเดอร์), และเกิด "แอบค้าง" 1 จุด
- "Claude" **ไม่เคยถูกได้ยินตรง ๆ ในทุกค่า** (ออกมาเป็น คอร์ด/คลอส) — คำอนุมัติของผู้ใช้มี คอส/คอด แต่ไม่มี คอร์ด/คลอส จึงไม่โดน

### ที่แก้ใน build นี้
- `VocabularyHarvest` (Core, 5 เทสต์ รวม 163): ดึงคำละติน/ชื่อไฟล์/รหัส (main.swift, F18, Codex) จาก "คุณพูด" ในตัวอย่างที่บันทึก ที่ยังไม่อยู่ใน prompt → การ์ดคำศัพท์แสดง "จากตัวอย่างที่คุณบันทึก ยังไม่อยู่ในรายการ" + ปุ่ม "เพิ่มทั้งหมด" · prompt ของผู้ใช้วันนี้ไม่มี main.swift และ F18 ทั้งที่สองคำนี้ผิดในชุดทดสอบ
- **toolchain เปลี่ยน**: เครื่องอัปเป็น macOS 27.0 และ swiftc ตั้ง target เริ่มต้นเป็น macosx28.0 → ไบนารีที่ build ได้ `minos 28.0` เปิดไม่ได้ (LaunchServices −10825) ทั้งที่ plist บอก 26.0 · แก้: `-target arm64-apple-macos26.0` ใน build.sh/test.sh · ไบนารีตอนนี้ `minos 26.0`
- ติดตั้ง build 32 · ก่อนปิด 0.1.30 **ไม่มีไฟล์เก็บข้อความค้าง** = ถาดว่างตอนปิด (นับล่าสุดที่เห็นคือ 8 เมื่อ 12 ก.ย. ผู้ใช้อาจคัดลอก/ลบไปแล้ว ยืนยันไม่ได้) · ต้องขอสิทธิ์ใหม่ทั้งสาม

## 0.1.32 — 2026-09-17 — ready to share: macOS 15 floor, in-app model download, public repo prep
- **ขั้นต่ำ macOS 26 → 15**: typecheck ที่ target 15.0/16.0/26.0 ได้ 0 error ทั้งสาม (API ที่ใหม่สุดที่ใช้คือ Translation framework = 15) · ไบนารี `minos 15.0`, plist `LSMinimumSystemVersion 15.0` · ยังไม่ได้ทดสอบรันจริงบน macOS 15/16 (เครื่องนี้ 27) — OCR ไทยใน Vision บน 15 ยังไม่ยืนยัน
- **ดาวน์โหลดโมเดลในแอป**: `ModelDownload.largeV3Q5` (Core: url/ขนาด 1,081,140,203/sha256 d75795ec…) → `Model.downloadAccurateModel()` ใช้ URLSession download task + delegate แสดง % · หลังโหลด ตรวจขนาดและ sha256 (CryptoKit อ่านทีละ 4 MB) ก่อนย้ายเข้า `~/Library/Application Support/Veda/models/` ไฟล์ที่ไม่ผ่านถูกลบ · ขั้นที่ 4 ในการ์ดตั้งค่า + ปุ่มในหน้าตรวจระบบ + หน้าตั้งค่าเด้งเองเมื่อยังไม่มีโมเดล · diagnostics `accurateModel` · 5 เทสต์ รวม 168 · ยังไม่ได้ทดสอบดาวน์โหลดจริงครบ 1 GB ในแอป (เครื่องนี้มีโมเดลอยู่แล้ว) ต้องทดสอบบนเครื่องเพื่อน
- **ล้างข้อมูลส่วนตัวก่อนเผยแพร่**: path `/Users/<user>` → `~`, path ไฟล์อัดเสียงส่วนตัว → ตัดออก, ชื่อในตัวอย่างเรนเดอร์/เทสต์ → "สมชาย", PDF งานอื่น 2 ไฟล์และ AGENTS.md ออกจาก index (+ .gitignore)
- **ประวัติ git เดิมมี blob ใหญ่ที่เข้าถึงไม่ได้จาก HEAD** (ggml-medium 1.5 GB, Veda.zip ×2, ollama) รวม 7.7 GB → repo public สร้างจาก export ของ tree ปัจจุบันเป็น commit เดียว ไม่ push ประวัติเดิม
- README.md (ไทย + English) + LICENSE MIT · gh 2.101.0 ติดตั้งใน ~/.local/bin (checksum ตรง) · login ผ่าน device flow — ผู้ใช้กรอกรหัสเองในเบราว์เซอร์ Claude ไม่เห็น token
- ที่แก้ด้วยโค้ดไม่ได้และบอกผู้ใช้แล้ว: Gatekeeper เตือนทุกเครื่อง (ต้อง Open Anyway) และขอสิทธิ์ใหม่ทุกอัปเดต — ต้อง Apple Developer Program + notarization

## เผยแพร่ 2026-09-17 — github.com/gnantawat-coder/whisper-with-veda (public)
- repo สร้างจาก `git archive HEAD` ของ tree ปัจจุบัน → git init ใหม่ → commit เดียว 33 ไฟล์ 1.7 MB · **ไม่ push ประวัติ 7.7 GB ของ repo พัฒนา** (มี blob ที่เข้าถึงไม่ได้: ggml-medium 1.5 GB, Veda.zip ×2, ollama)
- สแกนก่อน push: ไม่พบชื่อบัญชีเครื่อง, อีเมล, ชื่อจริงในซอร์ส, หรือ path ไฟล์อัดเสียงส่วนตัว · PDF งาน 2 ไฟล์และ AGENTS.md ไม่อยู่ใน index
- Release **v0.1.32** แนบ `Veda-0.1.32.zip` 448,977,158 ไบต์ sha256 `bbefa971…` · ตรวจแล้วว่าโหลดจากภายนอกได้ (HTTP 200 ที่ `/releases/latest/download/`)
- gh CLI 2.101.0 ใน ~/.local/bin · login ผ่าน device flow โดยผู้ใช้เอง บัญชี gnantawat-coder · Claude ไม่เคยเห็น token (เก็บใน keyring)
- **ยังไม่ได้ทดสอบบนเครื่องอื่น**: ขั้นตอน Open Anyway, การดาวน์โหลดโมเดล 1.08 GB ในแอปจริง, และการรันบน macOS 15/16 ล้วนยังไม่มีใครยืนยัน — เครื่องที่พัฒนาเป็น macOS 27 และมีโมเดลอยู่แล้ว

## 0.1.33–0.1.34 — 2026-09-20 — ตัวละครมุมจอ (gluu bot) และเปลี่ยนชื่อแอป

### ตัวละคร
- ออกแบบผ่านตัวอย่างในแชต 7 รอบ (ผู้ใช้ตัดสินทีละเรื่อง: ตาเท่ากันตามภาพ Canva, ไม่มีเส้นลูกบาส, กรอบ 260×170 มุมขวาล่างไม่มีพื้นหลัง, จุดพักกลางกรอบ, หันหน้าตรงเฉพาะอารมณ์ที่อ่านจากความสมมาตร, กลิ้งลึกเข้าไปนาน ๆ ครั้งพร้อมสีหน้าบอกลาไม่มีมือ, เอฟเฟกต์ประกอบเล็ก ๆ 3 อย่าง)
- **Core (`Critter`)**: ฟิสิกส์ (แรงโน้มถ่วง 1500·unit, คืนแรงพื้น 55% ผนัง 60% เพดาน 70%, บีบ-ยืดผ่านสปริง, หดตัว 110 ms ก่อนกระโดด, ท่า roll/hop/dribble/throw/pinball/wallClimb/zigzag/deep), 20 อารมณ์พร้อมค่า `front` (0 = ท่าอ้างอิงเอียง, 1 = หันตรง), `Face.approach` ไหลเข้าหาท่าใหม่, `Scheduler` สุ่มตามความขี้เล่น 3 ระดับ, กลิ้งลึกน้ำหนัก 2/104 และห่างกัน ≥ 10 นาที · ทุกค่าสัมพัทธ์กับรัศมี (จูนที่ 44 ใช้จริงที่ 24) · **22 เทสต์** (ตกถึงพื้น, ชนผนังไม่หลุดกรอบ, ซิกแซก 4 ครั้งจบด้วยตกใจ, ดริบเบิล ≥ 5, ทริปลึกไปถึง z>0.9 และกลับ, หน้าลู่เข้าท่าเป้าหมาย, สมมาตรของ anchor, การสุ่มถ่วงน้ำหนัก, ช่วงห่างทริปลึก)
- **Critter.swift**: `CritterEngine` (Timer 60 fps บน main runloop, ปิดเมื่อสลับไปแถบเดิม), `CritterView` วาดด้วย `Canvas` (ตัว, ตาแคปซูลหมุน, ยิ้มโค้ง, แก้ม, น้ำตา, ประกาย 3 ดวง, เส้นว้าว, เส้นสั่น, วงคลื่นตอนฟัง, เงาพื้นตามความลึก, ขอบขาว 16% กันหายบนหน้าต่างดำ), กล่องข้อความและป้าย TH/EN เป็น SwiftUI · `CritterPanel` = NSPanel โปร่ง ไม่รับโฟกัส `ignoresMouseEvents` สลับทุกเฟรมตามว่าเมาส์อยู่บนตัวหรือไม่ (คลิกทะลุทุกที่ยกเว้นตัว) วางที่มุมขวาล่างของจอที่เมาส์อยู่ เหนือ Dock
- **เชื่อมกับแอป**: phase → ฟัง/คิด · `critterCues`: สลับภาษา (ป้าย TH/EN + กระโดด), พิมพ์แล้ว (done + กระโดด), พิมพ์ไม่ได้ (เศร้า), ผิดพลาด (หงุดหงิด), คัดลอก (ดีใจ), notice → กล่องข้อความ · คลิกตัว → ตั้งค่า (ตัวหยุดนิ่งระหว่างเปิดตั้งค่า) · ตั้งค่า "การแสดงผล": ตัวละคร/แถบเดิม (ค่าเริ่มต้นตัวละคร), ความขี้เล่น, ลดการเคลื่อนไหว (รวม `accessibilityDisplayShouldReduceMotion` ของระบบเสมอ) · แถบเดิมยังอยู่ครบเมื่อเลือก classic
- เรนเดอร์ offscreen 7 สถานะ (ui-check/critter-*.png) ตรวจแล้ว: ท่าพักตรงต้นแบบ, ดีใจมีประกาย, เศร้ามีน้ำตาและหันตรง, ฟังมีวงคลื่น, ทริปลึกตัวเล็ก+เงา
- **ยังไม่ได้พิสูจน์บนจอจริง**: ความรู้สึกของ timing ที่ 24 px, การคลิกทะลุ, ตำแหน่งเมื่อ Dock อยู่ด้านข้าง/หลายจอ, การมองตามเมาส์เมื่อเมาส์อยู่นอกกรอบ (ออกแบบให้กวาดตาเองแทน)

### เปลี่ยนชื่อ Veda → gluu bot (0.1.34)
- แทนที่ 21 บรรทัดของข้อความที่ผู้ใช้เห็น + `CFBundleName`/`CFBundleDisplayName` + ชื่อไฟล์ `gluu bot.app` ในซิป · **คงไว้**: bundle id `local.veda.dictation` (สิทธิ์และ UserDefaults ต่อเนื่อง), ชื่อไบนารี `Veda`, โฟลเดอร์ `Application Support/Veda` (โมเดล 1 GB ไม่ต้องโหลดใหม่), ชื่อไฟล์ diagnostics/lock/archive, ชื่อ repo
- install-update.py ติดตั้งไปที่ `~/Applications/gluu bot.app` และย้าย `Veda.app` เดิมไป `work/build-artifacts.noindex/Veda-renamed.bundle-backup` (ไม่ลบ) · LaunchServices ถอนทะเบียนตัวเก่า
- ติดตั้ง build 35: ข้อความค้าง 3 รายการคืนครบ, diagnostics `bundlePath …/gluu bot.app`, โมเดลใหญ่โหลดได้ · ต้องขอสิทธิ์ใหม่ 3 อย่าง (ad-hoc)

## 0.1.35–0.1.36 — 2026-09-20 — ตัวละครไม่ขยับเอง: สาเหตุและแก้
- อาการ: กะพริบตาอย่างเดียว ขยับเฉพาะตอนกด Fn · สาเหตุ: `engine.paused = true` ตั้งตอนเปิดหน้าตั้งค่า และรีเซ็ตเฉพาะเมื่อหน้าต่าง**ปิด** (willClose) แต่ `hideSettingsForDictation` ใช้ `orderOut` ตอนกด Fn ซึ่งไม่ยิง willClose → ธงค้างตลอด ฟิสิกส์ยังเดิน (จึงขยับตอน Fn) แต่ตัวสุ่มท่า/อารมณ์ถูกล็อก
- แก้: ถามสด ๆ ทุกเฟรมว่าหน้าตั้งค่า `isVisible && isKeyWindow` แทนธง · ป้าย TH/EN ตอนสลับภาษาไม่ส่งกล่อง "เปลี่ยนภาษาเป็น…" ซ้ำ · จุดพัก 0.68 ของความกว้างกรอบ (ผู้ใช้ขอขยับขวา) · โยกตัวช้า ๆ ±2° ต่อเนื่องตอนว่างไม่ให้มีจังหวะนิ่งสนิท
- ติดตั้ง build 37 ข้อความค้าง 3 คืนครบ · ยังไม่ได้ยืนยันบนจอผู้ใช้ว่าสุ่มท่าทำงาน (ต้องรอผู้ใช้ให้สิทธิ์และปล่อยไว้)

## 0.1.37 — 2026-09-20 — Fn+Option, หน้าต่างดูท่าทาง, ปล่อยเป็น gluu bot
- ผู้ใช้ยืนยันบนจอจริง: ตัวละครสุ่มท่า/อารมณ์เองแล้ว (0.1.36) · ขอเพิ่ม Fn+Option วนความขี้เล่น และหน้าต่างทดลองท่าทาง
- `DictationShortcut.option(down:)`: ตอบ `.playfulness` เมื่อกด Option ขณะ Fn/F18 ค้าง และตั้ง `switched` ให้การปล่อย Fn ไม่ถอดเสียง (เหมือน Fn+Space) · ไม่กลืน flagsChanged ของ Option (กันสถานะ modifier เพี้ยน) · 4 เทสต์ รวม 194 · ป้าย "ความขี้เล่น: …" ขึ้นเป็นกล่องข้อความของตัวละคร
- หน้าต่าง "ดูท่าทางและอารมณ์" (ตั้งค่า › การแสดงผล): `CritterEngine` ตัวที่สอง รัศมี 44 ในกรอบ 416×272 พร้อมปุ่มทุกท่า (11) และทุกอารมณ์ (20 พร้อมตัวเลขระดับหันหน้า), จำลองกด Fn ค้าง (ระดับเสียงสังเคราะห์) → คิด → เสร็จ, สลับ TH/EN, วนความขี้เล่น · engine หยุดเมื่อปิดหน้าต่าง
- ติดตั้ง build 38 ข้อความค้าง 4 คืนครบ · ปล่อย GitHub release v0.1.37 (asset `gluu-bot-0.1.37.zip`) จาก export ของ tree นี้
