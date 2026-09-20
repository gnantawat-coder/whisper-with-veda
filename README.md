# gluu bot (เดิมชื่อ Veda) — พิมพ์ด้วยเสียงภาษาไทยบน Mac ทั้งหมดบนเครื่อง

Veda คือแอป macOS สำหรับ**พูดแล้วพิมพ์** (ไทย → ข้อความไทย หรือ ไทย → อังกฤษ) และ **Snap Translate** (ลากเลือกข้อความบนจอ → แปล ไทย ↔ อังกฤษ ทันที) ทุกอย่างประมวลผลบนเครื่องด้วย [whisper.cpp](https://github.com/ggerganov/whisper.cpp) และ Apple Translation — **ไม่มีเสียง ข้อความ หรือภาพหน้าจอถูกส่งออกจากเครื่อง**

> gluu bot (formerly Veda) is a local-only Thai dictation and screen-translation app for Apple Silicon Macs. Hold **Fn** to speak, release to type. **⇧⌘3** to select on-screen text and translate TH↔EN. Nothing leaves the machine. English notes are at the bottom.

## ต้องมี
- Mac **Apple Silicon** (M1 ขึ้นไป) · **macOS 15 (Sequoia)** ขึ้นไป
- พื้นที่ว่างประมาณ 2 GB (แอป 450 MB + โมเดลความแม่นสูง 1.08 GB ที่ดาวน์โหลดครั้งแรก)

## ติดตั้ง (5 นาที)
1. ไปที่ **Releases** ทางขวาของหน้านี้ ดาวน์โหลด `gluu-bot-<เวอร์ชัน>.zip` แล้วแตกไฟล์ **ลาก `gluu bot.app` ไปไว้ใน Applications ก่อนเปิด** — ถ้าเปิดจากโฟลเดอร์ Downloads ตรง ๆ macOS จะรันแอปจากที่ชั่วคราว (`/private/var/folders/…/AppTranslocation/…`) ทำให้สิทธิ์ Accessibility ไม่ติดและ **ปุ่ม Fn ไม่ทำงาน** (หน้าตรวจระบบจะขึ้น "ยังไม่ได้รับ Fn" พร้อม path แบบนั้น) — ย้ายไป Applications แล้วเปิดใหม่ ขอสิทธิ์ใหม่
2. **เปิดครั้งแรก** — macOS จะบอกว่า "ไม่สามารถเปิดได้ เพราะมาจากนักพัฒนาที่ไม่ระบุตัวตน" (แอปยังไม่ได้ผ่าน notarization ของ Apple) ทำตามนี้ครั้งเดียว:
   - ลองเปิดแอปหนึ่งครั้งให้มันเตือน → ไปที่ **System Settings › Privacy & Security** → เลื่อนลงจะเห็น *"gluu bot" was blocked* → กด **Open Anyway** → ยืนยันด้วยรหัสผ่านเครื่อง
   - (macOS 14 หรือเก่ากว่า: คลิกขวาที่ gluu bot.app → Open → Open ก็ได้)
3. เมื่อเปิดแล้ว หน้าต่าง **ตั้งค่าครั้งแรก · 4 ขั้น** จะเด้งขึ้นเอง ทำตามทีละขั้น:
   1. **ไมโครโฟน** — กด "อนุญาต"
   2. **Accessibility** — เปิดสวิตช์ Veda ใน System Settings (ใช้พิมพ์ข้อความลงช่องที่คุณกำลังใช้ และรับปุ่ม Fn)
   3. **Screen Recording** — เปิดสวิตช์ Veda แล้วกด "เปิด Veda ใหม่" (ใช้เฉพาะ Snap Translate)
   4. **โมเดลภาษาไทยความแม่นสูง** — กด "ดาวน์โหลด" (1.08 GB ครั้งเดียว ตรวจ checksum ให้) แล้วกด "เปิด Veda ใหม่"

   ถ้าไม่ทำข้อ 4 แอปจะใช้โมเดลรุ่นเล็กที่มากับแอป ซึ่งภาษาไทยผิดเยอะมาก

## ใช้งาน
| ทำอะไร | กดอะไร |
|---|---|
| พูดแล้วพิมพ์ | **กด Fn ค้าง** พูด แล้ว**ปล่อย** — ข้อความจะพิมพ์ลงช่องที่เคอร์เซอร์อยู่ |
| สลับ ไทย / อังกฤษ ระหว่างพูด | **Fn + Space** — ป้าย TH/EN เด้งขึ้นเหนือตัวละคร |
| ตัวละครมุมจอ (gluu bot) | อยู่มุมขวาล่าง กลิ้ง เด้ง เปลี่ยนสีหน้าเอง ตา LED หันตามเมาส์ · **คลิกที่ตัว** เปิดตั้งค่า · **ลากบนตัว** = ลูบ · **ดับเบิลคลิก** = เล่นหัว · **คลิกขวา** = ให้อาหาร/อ่านหนังสือ/เล่น · **Fn + Option** วนโหมดความขี้เล่น · เลือก "แถบดำแบบเดิม" ได้ในตั้งค่า |
| เพื่อน gluu bot | หน้าตั้งค่า "เพื่อน gluu bot": ความสนิท 5 ระดับ อิ่ม/สนุก/พลัง/ความรู้ ฉากพิเศษ 30 แบบ (ลูกโป่ง ฟ้าผ่า ฝน น้ำท่วม เครื่องบิน นินจา …) มุกการ์ตูน อากาศสุ่ม หลับเมื่อปล่อยเครื่องแล้วมีนกมาเกาะ · ไม่มีวันตาย |
| ยกเลิกที่กำลังพูด | **Esc** |
| Snap Translate | **⇧⌘3** → ลากครอบข้อความ → คำแปลโผล่ข้างเคอร์เซอร์ · คลิกที่อื่นเพื่อปิด · เปลี่ยนปุ่มได้ในตั้งค่า |
| คีย์บอร์ดภายนอก | ตั้งปุ่มบนคีย์บอร์ดให้ส่ง **F18** แล้วเปิด "กด F18 ค้างเพื่อพูด" ในตั้งค่า |

ถ้าพิมพ์ลงช่องนั้นไม่ได้ (บางแอปไม่รองรับ) ข้อความจะถูกเก็บไว้ที่ **"ยังไม่ได้พิมพ์"** ในหน้าตั้งค่า พร้อมปุ่มคัดลอก ไม่หายแม้ปิดแอป

## ทำให้แม่นขึ้นสำหรับเสียงคุณ
เปิด **ตั้งค่า › โปรไฟล์ของฉัน**
- **คำศัพท์เฉพาะของคุณ** — ชื่อคน โปรเจกต์ ศัพท์เทคนิค คั่นด้วยจุลภาค ส่งเป็นคำใบ้ให้โมเดลทุกครั้ง (บนเสียงผู้พัฒนา รายการนี้ลดอักขระผิดจาก 10.7% เหลือ 8.0%)
- **คำที่คุณอนุมัติให้แก้** — เมื่อโมเดลได้ยินชื่อผิดซ้ำ ๆ (เช่น "คลอส" แทน "Claude") อนุมัติคู่คำนั้น จะถูกแก้เฉพาะตัวสะกดนั้นตอนพิมพ์
- **ทดสอบเสียงของฉัน** — ลากไฟล์เสียงที่คุณอัด + พิมพ์สิ่งที่พูดจริง แอปจะบอก % อักขระที่ผิด และเสนอคำที่ควรเพิ่มให้

## ความเป็นส่วนตัว
- เสียง ข้อความ และภาพหน้าจอ **ไม่ถูกส่งออกจากเครื่อง** และไม่ถูกเก็บเป็นไฟล์ (ยกเว้นข้อความที่คุณเลือกบันทึกเป็นตัวอย่างในโปรไฟล์ ซึ่งอยู่ในเครื่องคุณ)
- การดาวน์โหลดโมเดลติดต่อ huggingface.co ครั้งเดียวและตรวจ checksum
- แอปไม่มีการวิเคราะห์การใช้งานหรือติดต่ออินเทอร์เน็ตอื่นใด

## ข้อจำกัดที่ควรรู้
- คำภาษาอังกฤษในประโยคไทย (ชื่อโปรแกรม ชื่อไฟล์) ยังเป็นจุดอ่อนของ Whisper — ใช้คำศัพท์และคำอนุมัติช่วย
- รอประมาณ 1.5–2 วินาทีหลังปล่อย Fn (โมเดลใหญ่บนเครื่อง) ครั้งแรกหลังทิ้งไว้นานอาจนานกว่านั้น
- ทุกครั้งที่อัปเดตแอป macOS จะให้ขอสิทธิ์ 3 อย่างใหม่ (แอปเซ็นแบบ ad-hoc ไม่มี Developer ID)
- Intel Mac ใช้ไม่ได้

## Build จากซอร์ส
```bash
bash outputs/Veda/scripts/test.sh    # 259 checks
bash outputs/Veda/scripts/build.sh   # -> outputs/Veda/Veda.zip
```
ต้องมี Xcode Command Line Tools · whisper-server และโมเดล small อยู่ใน `outputs/Veda/runtime/` (ดู `outputs/Veda/runtime/WHISPER-LICENSE`) · บันทึกการทดสอบและการตัดสินใจทั้งหมดอยู่ใน `outputs/Veda/VALIDATION.md`

---

### English
**gluu bot** (formerly Veda) is a local-only Thai dictation app for Apple Silicon Macs (macOS 15+). Hold **Fn** to speak and release to type Thai (or English translation) into whatever field has focus; **⇧⌘3** captures on-screen text and translates TH↔EN with on-device Apple Translation. Speech runs through whisper.cpp with `large-v3-q5_0`; nothing is sent off the machine.

Install: download `gluu-bot-<version>.zip` from Releases, move to Applications, allow it once in *System Settings › Privacy & Security › Open Anyway* (the app is ad-hoc signed, not notarized), then follow the 4-step setup card: Microphone, Accessibility, Screen Recording, and the 1.08 GB accurate-model download. Personal vocabulary and approved term corrections live in *Settings › My profile*. MIT licensed; whisper.cpp is MIT.
