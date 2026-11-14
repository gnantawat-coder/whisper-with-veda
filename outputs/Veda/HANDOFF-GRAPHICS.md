# gluu bot — ชุดข้อมูลส่งต่องานกราฟิก (2026-09-20, แอปเวอร์ชัน 0.1.54)

## อัปเดตงานตาและแอนิเมชัน — 0.1.54 / build 55
- ตา LED มีขอบบนที่หรี่และเอียงได้ (`Eye.lid/lidSlope`) แยกเศร้า กังวล หงุดหงิด เบื่อ ง่วง; รูปทรงผสมต่อเนื่องด้วย `Eye.lerp` ส่วนตาหลับ/สงบเป็นแนวนอน
- `Critter.acting` ทำจังหวะตานำตัว เตรียม–คลาย–พัก ผ่าน gaze/tilt/scale ขนาดเล็ก โดยไม่เปลี่ยนตำแหน่งฟิสิกส์; `blinkClosure` ปิดเร็ว พัก แล้วเปิดช้า; ลดการโคลงตลอดเวลาและหยุดสั่นหลังตกใจ
- ตัวหลัก/โคลน/สาวใช้ `drawShell` ร่วมกัน (radial fill ชั้นเดียว ไม่มี blur) ตา LED มีแกนสว่างเล็กและยังเห็น silhouette ระหว่าง refresh; วงฟังเสียงเป็นฟ้าบาง
- ดูสีหน้าทั้ง 29 แบบใน `ui-check/acting/expressions-24.png` และ `expressions-44.png`; ดูจังหวะใน `acting.gif`. สร้างใหม่ด้วย `work/tests/veda-render --render-acting <directory>` หลัง build harness จาก source ล่าสุด
- เปลี่ยนไฟล์ `Core.swift`, `Critter.swift`, `Visuals.swift`, `main.swift`, `Tests/main.swift`, `scripts/build.sh`. 329 checks ผ่านและ build ผ่าน; ติดตั้งแล้ว ข้อความพัก 8 รายการคืนครบ ต้องให้สิทธิ์ Accessibility ใหม่ตามปกติ ดูรายละเอียด/ข้อจำกัดใน VALIDATION.md

เอกสารนี้สำหรับคนหรือ AI ที่จะมาช่วย "ทำกราฟิกให้สวยขึ้น" โดยไม่ต้องรู้จักโค้ดทั้งโปรเจกต์ อ่านจบแล้วจะรู้ว่าตอนนี้ตัวละครวาดอย่างไร ส่งงานกลับมาในรูปแบบไหนถึงจะเอาเข้าแอปได้จริง และอะไรห้ามเปลี่ยน

## ตัวละครคืออะไร
- แอป macOS พิมพ์ด้วยเสียงภาษาไทย ตัวละครชื่อ **gluu bot** อยู่มุมขวาล่างของจอในกรอบโปร่งใส **260×170 px** (ไม่มีพื้นหลัง เห็นเดสก์ท็อปทะลุ) รัศมีตัวจริง **24 px** · ในหน้าตั้งค่ามีพรีวิวรัศมี 24 และหน้าต่างใหญ่รัศมี 44 (กรอบ 416×272)
- **ตัวเป็นวงกลมดำ** (#111 ขอบขาว 16%) **ไม่มีปาก ไม่มีลิ้น ไม่มีมือ** — สื่ออารมณ์ด้วย**ตา**และ**ท่าทางของทั้งตัว**เท่านั้น (บีบ ยืด เอียง หมุน กระโดด) กฎนี้ผู้ใช้ยืนยันซ้ำหลายรอบ ห้ามเพิ่ม
- **ตาเป็น LED พิกเซลสีฟ้า** (#5FE1FF มีฮาโลจาง ๆ) แบบ Astro Bot: รูปทรงตาเดิม (แคปซูล 2 อัน หันหน้า 3/4 ตามภาพต้นแบบ) ถูก "ส่องผ่านตะแกรง" ระยะเม็ด 3.2 หน่วย → ทุกอารมณ์เป็นเม็ดไฟอัตโนมัติ · เปลี่ยนสีหน้า = เม็ดค่อย ๆ ติดตามลำดับสุ่ม 0.3 วิ · โหมดตาขาวเรียบยังเลือกได้ในตั้งค่า
- 29 อารมณ์ (normal, bored, thinking, sleepy, asleep, curious, happy, done, shy, sad, wow, startled, worried, dizzy, peek, cold, listening, annoyed, bye, back, hungry, sulky, loved, laugh, full, hot, zen, pant, groove) แต่ละอารมณ์ = ตำแหน่ง/ขนาด/มุมของตา 2 ข้าง + ค่าหันหน้า 0…1 + ธงเอฟเฟกต์ (แก้มแดง ยิ้มโค้ง น้ำตา ประกาย เส้นว้าว เส้นสั่น วงคลื่น)
- **43 ฉากพิเศษ** (ไทม์ไลน์คงที่ 2–12 วิ): inflate, lightning, rainUmbrella, rain, balloon, manhole, sneeze, hiccup, eat, read, heartEyes, eyePop, tornado, pancake, rubber, dash, spinJump, levitate, ghost, shootingStar, box, melt, freeze, flood, plane, dance, ninja, roadkill, clone, beach, crush, snack, pat, chin, skateboard, kite, toilet, pingpong, meadow, bulb, catWalk, catPlay, football · แบ่ง 5 หมวดในเมนู: ร่างกาย / ธรรมชาติ / ผจญภัย / อารมณ์และเพื่อน / มุกการ์ตูน
- ระบบอื่นที่มีผลกับภาพ: อากาศสุ่ม (แดด ฝน ลม หิมะ ร้อน กลางคืนมีพระจันทร์+ดาว), นอนหลับเมื่อปล่อยเครื่อง 3 นาทีแล้วมีนกสีน้ำเงินมาเกาะ, ระบบเลี้ยง (อิ่ม/สนุก/พลัง/ความรู้/ความสนิท ไม่มีวันตาย), แมวส้มลายทางปลอกคอแดงโบว์เหลือง, สาว gluu bot (ผมบ๊อบสีทอง โบว์ชมพู แก้มแดง ขนตา)

## ตอนนี้กราฟิกทั้งหมด "วาดด้วยโค้ด" ไม่มีไฟล์รูปเลย
- ไฟล์: `outputs/Veda/Sources/Critter.swift` ส่วน `enum CritterPainter` — ฟังก์ชัน `static func draw…` 68 ตัว วาดด้วย SwiftUI `Canvas`/`Path` (วงรี สี่เหลี่ยมมน เส้นโค้ง) เท่านั้น
- **ระบบพิกัดของตัว**: หลัง translate ไปกลางตัวและ scale ตามรัศมี ตัวมีรัศมี **46 หน่วย** (เส้นผ่านศูนย์กลาง 92) จุด (0,0) กลางตัว y ลงล่าง พื้นอยู่ที่ y = +46 · อุปกรณ์ที่ "ติดตัว" (ร่ม ลูกโป่ง จุกนม ถุงมือ) วาดในพิกัดนี้ · ฉากหลัง (ทะเล ถนน กำแพง ประตูฟุตบอล) วาดในพิกัดกรอบ (world) โดยใช้ `s.area`, `s.groundY`, `s.unit` (= รัศมี/44 ใช้คูณทุกขนาดให้สเกลตามตัว)
- ลำดับชั้น: ฉากหลัง → เงาพื้น → ของหลังตัว (ลูกโป่ง ร่ม ควัน) → ตัว (บีบ/ยืด/เอียง/หมุน) → ตา/แก้ม/น้ำตา → ของหน้าตัว (จุกนม น้ำมูก ถุงมือ) → ชั้นทับสุด (น้ำท่วม ตาข่าย กระดาษสี ตู้ WC)
- เอฟเฟกต์ยิงทีเดียว (ระเบิด ป๊อป ละออง) ใช้ "อายุตั้งแต่ยิง" วาดจางลงใน 0.35–0.45 วิ

## ส่งงานกลับมาแบบไหนถึงเอาเข้าแอปได้
เรียงจากง่ายที่สุดสำหรับคนที่จะเอาเข้าโค้ด:
1. **โค้ด Swift `Path` ในพิกัด 92 หน่วย** (ดีที่สุด — เข้ากับระบบเดิม สเกลได้ทุกขนาด ไม่ต้องมี asset pipeline) เช่น ร่มที่สวยขึ้น ให้ส่งเป็นฟังก์ชัน `static func drawUmbrella(t: Double, still: Bool, in c: inout GraphicsContext)` ใช้ได้เฉพาะ `Path`, `fill`, `stroke`, `Color(red:green:blue:)`, `translateBy/rotate/scaleBy`, `clip`
2. **SVG** เส้นทางเวกเตอร์ธรรมดา (path/circle/rect/ellipse, ไม่มี gradient/filter/text) กรอบ viewBox ที่กำหนดหน่วย 92 = เส้นผ่านศูนย์กลางตัว — ผมแปลงเป็น `Path` ให้ได้
3. **PNG @2x พื้นโปร่ง** — ใช้ได้เฉพาะ "ฉากหลัง" หรืออุปกรณ์นิ่ง ๆ (ต้องเพิ่ม pipeline โหลดรูปเข้า Canvas ก่อน ยังไม่มีในแอป) ระบุขนาดเทียบตัว เช่น "ต้นมะพร้าวสูง 3 เท่าของตัว"
- ห้ามในทุกแบบ: ปาก ลิ้น มือของ gluu bot เอง, ตาแบบอื่นที่ไม่ใช่ LED ฟ้า/ขาว, พื้นหลังทึบของกรอบ (ต้องโปร่ง), gradient/blur/shadow แบบหนัก (Canvas วาด 60 fps บนจอจริง)
- สีที่ใช้อยู่: ตัว #111 · ตา #5FE1FF · แก้ม (0.83,0.33,0.49) · ประกาย (0.94,0.62,0.15) · น้ำ/ฝน (0.45,0.72,1.0) · ลูกโป่ง (0.90,0.25,0.30) · แมวส้ม (0.93,0.64,0.32) ลาย (0.78,0.45,0.18) · ทอง (0.95,0.78,0.30)

## ดูของจริงได้ที่ไหน
- ภาพเรนเดอร์ทุกฉาก: `outputs/Veda/ui-check/scenes/critter-*.png` (ขนาดจริง) และ `*-big.png` (รัศมี 44) รวมแผ่น `sheet-new*.png` · เรนเดอร์ใหม่: `work/tests/veda-render --render-overlays <โฟลเดอร์>` (ต้อง build harness ก่อน ดู VALIDATION.md)
- ฉากที่ตัวเคลื่อนที่ ภาพนิ่งพิสูจน์ไม่ได้ ใช้ `work/tests/veda-render --probe-scene <ชื่อฉาก>` พิมพ์ตำแหน่ง x ทุก 0.2 วิ
- โค้ดกฎของฉาก (ไทม์ไลน์ ไม่ใช่ภาพ): `outputs/Veda/Sources/Core.swift` → `Critter.sceneFrame` · ทดสอบ: `bash outputs/Veda/scripts/test.sh` (293 ข้อ)

## ข้อตกลงการทำงานร่วม
- อย่าให้ 2 ฝ่ายแก้ไฟล์เดียวกันพร้อมกัน (กฎเดิมของโปรเจกต์) — ให้ ChatGPT ผลิต "ชิ้นงาน" (โค้ด Path / SVG / PNG) แล้วส่งกลับมาให้ Claude ใส่เข้าแอป build ทดสอบ ติดตั้ง และปล่อย GitHub · หรือถ้าจะให้ ChatGPT แก้ไฟล์ตรง ๆ ให้ปิดฝั่ง Claude ก่อน แล้วบอกว่าเปลี่ยนไฟล์ไหน
- ห้ามส่งไฟล์ใน `work/` (บันทึกเสียงส่วนตัว) ออกไป · repo สาธารณะ: https://github.com/gnantawat-coder/whisper-with-veda

## Scene animation checkpoint — 2026-09-21 — 0.1.55 / build 56 installed

- Native preset improvements: pingpong approaches from the actual starting position, follows ballistic arcs, fires impact events across 30 fps frame boundaries, and recovers continuously from the final stroke. Manhole descent accelerates and emergence eases without negative sink. Aircraft departure uses a captured world-space horizontal anchor and fixed cruising altitude while the bot falls. The skateboard deck flips with the body. Rolling friction is time-scaled at 30/60/120 fps.
- Prop materials: shaded aircraft fuselage, metal anvil, rounded red balloon, paper canopy and wooden deck; perspective tabletop with bevel and shaded fascia. These are Canvas graphics, not a conversion of all presets to a 3D engine.
- Validation: 342 checks passed, optimized build completed, git diff --check clean. --render-scene-motion ran all 43 native scene timelines to completion with finite states, then captured 11 seconds of six scenes with 660 actual engine steps each. Reviewed sampled frames and pingpong position continuity (x 65.2–226.7 points); this is deterministic engine QA, not an installed-app screen recording or performance benchmark.
- Higgsfield: editable 3D diorama, project f9a39c77-23b0-4db8-bf87-59e848ea0028, revision 2. Blender scene and GLB in Graphics3D/. 29 facial expressions plus blink, 8-second performance; rest/anticipation/peak/landing/final poses inspected, start/end transforms match. Fixed erroneous companion shape-key weights and reviewed the final Eevee render. GLB contains 106 meshes and six animation tracks. The 3D scene is a separate deliverable; native overlay does not load it.
- Installed through normal quit/preserve/replace/open lifecycle. All 8 held transcripts restored and the one-time archive was consumed. Canonical app Info.plist reports 0.1.55 build 56. TCC readiness must be checked after the replacement; no autonomous microphone recording or shortcut was invoked.

## Weather, cat, football and drag — 2026-09-21 — 0.1.56 / build 57 installed

- Native graphics: moon uses a shaded crescent and crater detail; sun uses a soft radial halo; rain has three speed/length/opacity depths and surface ripples; snow has depth-dependent fall speeds/opacity and soft cloud layers. Reduced-motion inputs keep particle positions stable. Sunny/heat no longer draws a sun alongside the night moon.
- Cat rebuilt with a smaller skull, almond eyes/slit pupils, muzzle, separate near/far limbs, hock/elbow motion, shaded coat and tabby stripes, moving tail and matching tapered interaction paw. Football leg now has a shaded anatomical thigh, tapered sock/calf and studded boot with laces, plus corrected backswing/forward-swing direction. These remain live Canvas illustrations, not photorealistic bitmap replacements.
- Higgsfield FLUX.2 Pro generated one cat anatomy/light reference (job 96a01de6-dc00-48ee-9b51-aa7de873fda3, quoted 1 credit), inspected and saved in Graphics3D/cat-reference-higgsfield.png. No screenshot/private recordings were uploaded.
- Desktop placement: hold the bot 0.35 seconds then drag. Gesture captures global pointer movement, pauses bot simulation during relocation, keeps the panel inside the target display visibleFrame, and saves origin in gluuPanelOrigin. place() restores/clamps this origin instead of resetting to bottom-right on dictation state changes. Immediate strokes remain petting; click/double/triple-click menus remain. Settings preview has no relocation callback. The physical mouse gesture and cross-display handoff still require user validation; no end-to-end mouse test is claimed.
- Verified 346 checks, including four placement cases (secondary display with negative x, upper/lower edges, free position, undersized display). Optimized build passed. All 43 scene timelines completed with finite engine states. Rendered the overlay suite; visually reviewed cat walk/play, football wind-up, night, rain and snow. Native renderer emitted sandbox spelling-service warnings but completed successfully.
- Installed canonical ~/Applications/gluu bot.app. Info.plist = 0.1.56 / 57, fresh running diagnostics = 0.1.56. Normal quit preserved all 8 held transcripts; reopen restored all 8 and consumed the private migration archive. Microphone and Accessibility both report not granted for the new binary; user must grant them through normal settings. No autonomous recording or Fn injection performed.
