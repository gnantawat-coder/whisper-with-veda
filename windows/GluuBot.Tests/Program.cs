using System.Text;
using GluuBot.Core;

int checks = 0;
void Check(bool ok, string what) { checks++; if (!ok) { Console.Error.WriteLine("FAIL: " + what); Environment.Exit(1); } }

// Thai normalisation: same cases as the Mac suite.
Check(ThaiText.Normalized("นํา") == "นำ", "decomposed SARA AM is recomposed");
Check(ThaiText.Normalized("นํ้า") == "น้ำ", "tone mark between NIKHAHIT and SARA AA");
Check(ThaiText.Normalized("น้ํา") == "น้ำ", "tone mark before NIKHAHIT");
Check(ThaiText.Normalized("ก้ัน") == "กั้น", "tone written before the vowel is reordered");
Check(ThaiText.Normalized("ก่่า") == "ก่า", "a doubled tone mark is kept once");
Check(ThaiText.Normalized("สวัส​ดี﻿") == "สวัสดี", "zero-width characters are removed");
Check(ThaiText.Normalized("hello world") == "hello world", "plain text is untouched");
Check(ThaiText.Cleaned(" บรรทัดแรก\n บรรทัดสอง \r\n") == "บรรทัดแรก บรรทัดสอง", "segment line breaks become spaces and ends are trimmed");
Check(ThaiText.Cleaned("a   b\tc") == "a b c", "runs of spaces collapse");
Check(ThaiText.Cleaned("[BLANK_AUDIO]") == "" && ThaiText.Cleaned(" (music) ") == "" && ThaiText.Cleaned("ราคา (รวมภาษี) 100") != "", "a bracketed non-speech tag alone is dropped; brackets inside a sentence stay");

// Vocabulary hint.
Check(Vocabulary.Hint("Claude, Codex\nKeychron,,Claude ,") == "Claude, Codex, Keychron", "terms are trimmed, de-duplicated and joined");
Check(Vocabulary.Hint("") == "", "no vocabulary gives an empty prompt");

// Request body.
var body = Encoding.UTF8.GetString(WhisperRequest.Body(new byte[] { 1, 2, 3 }, true, "Claude", "B", "th"));
Check(body.Contains("name=\"language\"\r\n\r\nth\r\n") && body.Contains("name=\"translate\"\r\n\r\ntrue\r\n") && body.Contains("name=\"temperature\"\r\n\r\n0\r\n") && body.Contains("name=\"response_format\"\r\n\r\njson\r\n") && body.Contains("name=\"prompt\"\r\n\r\nClaude\r\n"), "the five fields match the Mac request");
Check(body.Contains("filename=\"audio.wav\"") && body.EndsWith("\r\n--B--\r\n") && !body.Contains("no_timestamps") && !body.Contains("audio_ctx"), "the file part closes the body; rejected options are never sent");
Check(Encoding.UTF8.GetString(WhisperRequest.Body(Array.Empty<byte>(), false, new string('x', 3000), "B")).Split("name=\"prompt\"\r\n\r\n")[1].Split("\r\n")[0].Length == 2000, "the prompt is capped at 2000 characters");

// WAV.
var pcm = new byte[32000 * 2];
var wav = Wav.FromPcm16(pcm);
Check(wav.Length == 44 + pcm.Length && Encoding.ASCII.GetString(wav, 0, 4) == "RIFF" && BitConverter.ToInt32(wav, 24) == 16000 && BitConverter.ToInt16(wav, 34) == 16 && BitConverter.ToInt32(wav, 40) == pcm.Length, "PCM is wrapped in a 16 kHz mono 16-bit header");
Check(Math.Abs(Wav.Seconds(pcm.Length) - 2.0) < 1e-9, "two seconds of PCM is two seconds");
var one = Wav.Prefix(wav, 1.0);
Check(one != null && one.Length == 44 + 32000, "the prefix is exactly one second");
Check(Wav.Prefix(wav, 10.0)!.Length == wav.Length, "a prefix longer than the clip is the whole clip");
Check(Wav.Prefix(new byte[10], 1) == null && Wav.Prefix(Encoding.ASCII.GetBytes("RIFFxxxxWAVEjunk" + new string('x', 40)), 1) == null, "non-WAV data gives null");
var stereo = (byte[])wav.Clone(); stereo[22] = 2;
Check(Wav.Prefix(stereo, 1) == null, "stereo is rejected rather than misread");

// Talk key state machine.
var s = new TalkShortcut();
Check(s.Key(true) == TalkAction.Begin && s.Key(true) == null && s.Key(false) == TalkAction.End, "press begins, auto-repeat is ignored, release ends");
Check(s.Key(false) == null, "a stray release does nothing");
s = new TalkShortcut();
Check(s.Space(true, false) == (false, null) && s.Space(false, false) == (false, null), "Space alone is never touched");
s.Key(true);
var toggled = s.Space(true, false);
Check(toggled.Consume && toggled.Action == TalkAction.Toggle, "talk key + Space toggles the language and swallows the Space");
Check(s.Space(true, true) == (true, null), "Space auto-repeat is swallowed without toggling again");
Check(s.Space(false, false) == (true, null), "the Space release is swallowed too");
Check(s.Key(false) == null, "releasing the talk key after a toggle does not transcribe");
Check(s.Key(true) == TalkAction.Begin && s.Key(false) == TalkAction.End, "the next hold works normally");

// Talk key choices.
Check(TalkKeys.Name(0xA3) == "Ctrl ขวา" && TalkKeys.Name(0x78) == "F9" && TalkKeys.Name(0x87) == "F24" && TalkKeys.Name(0x41) == "A", "keys have readable names");
Check(TalkKeys.IsModifier(0xA3) && TalkKeys.IsModifier(0x5B) && !TalkKeys.IsModifier(0x78), "Ctrl/Alt/Shift/Win are modifiers; F9 is not");
Check(!TalkKeys.Allowed(0x20) && !TalkKeys.Allowed(0x1B) && !TalkKeys.Allowed(0x14) && !TalkKeys.Allowed(0x0D) && !TalkKeys.Allowed(0x01) && TalkKeys.Allowed(0xA3) && TalkKeys.Allowed(0x78), "Space, Esc, Caps Lock, Enter and mouse buttons cannot be the talk key");

// Models.
Check(ModelCatalog.All.Length == 3 && ModelCatalog.All.All(m => m.Sha256.Length == 64 && m.Url.EndsWith(m.File) && m.Bytes > 100_000_000), "every model has a URL, size and SHA-256");
Check(ModelCatalog.Find("large-v3-q5_0")!.Bytes == 1081140203 && ModelCatalog.Find("nope") == null && !ModelCatalog.All.Any(m => m.Id.Contains("turbo")), "the accurate model is the Mac one; turbo is not offered");

// Settings.
var dir = Path.Combine(Path.GetTempPath(), "gluu-tests-" + Guid.NewGuid().ToString("N"));
var file = Path.Combine(dir, "settings.json");
var fresh = AppSettings.Load(file);
Check(fresh.TalkKey == 0xA3 && fresh.Mode == "TH" && fresh.MicDevice == -1, "defaults: Right Ctrl, Thai, default microphone");
fresh.TalkKey = 0x78; fresh.Mode = "EN"; fresh.Vocabulary = "Claude, คีย์ครอน"; fresh.Save(file);
var back = AppSettings.Load(file);
Check(back.TalkKey == 0x78 && back.Mode == "EN" && back.Vocabulary == "Claude, คีย์ครอน", "settings round-trip, Thai included");
File.WriteAllText(file, "{ not json");
Check(AppSettings.Load(file).TalkKey == 0xA3, "a damaged settings file falls back to defaults");
Directory.Delete(dir, true);

Console.WriteLine($"Core checks passed; total {checks}");
