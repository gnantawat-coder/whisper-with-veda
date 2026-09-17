# Personal Thai calibration — optional paired recordings

This is an evaluation set, not a trained speaker model. No microphone recording is started automatically. Record only when you choose, using your normal microphone, distance and speaking pace. Keep each utterance in a separate audio file; include what you actually said verbatim. Do not send passwords or customer information.

Start with these 6 utterances:
1. สวัสดี ฉันอยากให้นายตรวจสอบข้อมูลให้หน่อย
2. ฉันตั้งค่าคีย์บอร์ด Keychron เรียบร้อยแล้ว ช่วยเขียนโค้ดต่อได้เลย
3. โปรแกรมนี้ต้องแปลงเสียงภาษาไทยเป็นข้อความภาษาอังกฤษ
4. แก้ไขโปรแกรมได้ แต่ห้ามลบข้อมูลผู้ใช้
5. ฉันใช้ Claude เขียน Swift และเรียก API จาก TypeScript
6. ทดสอบหนึ่ง สอง สาม สี่ ห้า วันที่เก้ากันยายน

Also record 3 spontaneous sentences that you would normally dictate, and type their intended verbatim transcripts separately. Keep those 3 as held-out tests, not vocabulary prompts.

Evaluation: compare small and medium on exactly the same audio; record Thai character edit distance (normalize whitespace consistently), omissions, negation/number/name errors, and latency after warm-up. For EN score meaning, not exact wording. Do not replace every phonetic error using a global text substitution. Add only user-confirmed names/terms to vocabulary. Re-test held-out utterances before claiming improvement.

No recordings are included in this folder. Store private recordings outside the published source tree.
