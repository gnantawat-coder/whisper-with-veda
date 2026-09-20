import Foundation
import AVFoundation

struct CapturedAudio { let wav: Data; let duration: Double; let peakDB: Float }
final class AudioCapture {
    private let queue = DispatchQueue(label: "local.veda.capture", qos: .userInitiated)
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var peakDB: Float = -160
    private var startTime: TimeInterval = 0
    func start(id: UUID, latch: HoldLatch, completion: @escaping (Result<Bool, Error>) -> Void) {
        queue.async {
            guard latch.isHeld(id) else { DispatchQueue.main.async { completion(.success(false)) }; return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("veda-\(id).wav")
            do {
                let r = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
                r.isMeteringEnabled = true
                guard r.prepareToRecord() else { throw NSError(domain: "Veda", code: 2, userInfo: [NSLocalizedDescriptionKey: "ไม่สามารถเตรียมไมโครโฟนได้"]) }
                guard latch.whileHeld(id, { r.record() }) else {
                    r.stop(); try? FileManager.default.removeItem(at: url)
                    if latch.isHeld(id) { throw NSError(domain: "Veda", code: 3, userInfo: [NSLocalizedDescriptionKey: "ไมโครโฟนเตรียมพร้อมแต่เริ่มบันทึกไม่สำเร็จ"]) }
                    DispatchQueue.main.async { completion(.success(false)) }; return
                }
                self.recorder = r; self.url = url; self.peakDB = -160
                self.startTime = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async { completion(.success(true)) }
            } catch { try? FileManager.default.removeItem(at: url); DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    func meter(completion: @escaping (Float, Float) -> Void) {
        queue.async {
            self.recorder?.updateMeters()
            let average = self.recorder?.averagePower(forChannel: 0) ?? -160
            self.peakDB = max(self.peakDB, self.recorder?.peakPower(forChannel: 0) ?? -160)
            let peak = self.peakDB
            DispatchQueue.main.async { completion(average, peak) }
        }
    }
    func finish(completion: @escaping (CapturedAudio?) -> Void) {
        queue.async {
            self.recorder?.updateMeters()
            self.peakDB = max(self.peakDB, self.recorder?.peakPower(forChannel: 0) ?? -160)
            let duration = self.recorder?.currentTime ?? 0
            self.recorder?.stop(); self.recorder = nil
            var result: CapturedAudio?
            if let url = self.url {
                if let data = try? Data(contentsOf: url) { result = CapturedAudio(wav: data, duration: duration, peakDB: self.peakDB) }
                try? FileManager.default.removeItem(at: url)
            }
            self.url = nil
            DispatchQueue.main.async { completion(result) }
        }
    }
    func cancel() { finish { _ in } }
    func shutdown() {
        queue.sync {
            recorder?.stop(); recorder = nil
            if let url { try? FileManager.default.removeItem(at: url) }; url = nil
        }
    }
}

// Ordinary phone recordings (m4a, mp3, caf, aiff) are converted on this Mac to the
// 16 kHz mono WAV the local model expects. The converted copy exists in the
// temporary directory only for the length of one request and is removed after.
enum CalibrationAudio {
    struct Converted { let wav: Data; let seconds: Double }
    enum Failure: LocalizedError {
        case unreadable, empty, tooLong(seconds: Int), conversion
        var errorDescription: String? {
            switch self {
            case .unreadable: return "อ่านไฟล์เสียงนี้ไม่ได้ ลองไฟล์ m4a, mp3, wav หรือ caf"
            case .empty: return "ไฟล์นี้ไม่มีเสียง"
            case .tooLong(let seconds): return "เสียงยาว \(seconds) วินาที · รับไม่เกิน \(Int(AudioImport.maxSeconds)) วินาที"
            case .conversion: return "แปลงเสียงเป็น 16 kHz mono ไม่สำเร็จ"
            }
        }
    }
    static func wav16kMono(from url: URL) throws -> Converted {
        guard let input = try? AVAudioFile(forReading: url) else { throw Failure.unreadable }
        let inputFormat = input.processingFormat
        switch AudioImport.verdict(frames: input.length, sampleRate: inputFormat.sampleRate) {
        case .empty: throw Failure.empty
        case .tooLong(let seconds): throw Failure.tooLong(seconds: seconds)
        case .accept: break
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioImport.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target),
              let whole = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(input.length)),
              let chunk = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(AudioImport.sampleRate)) else { throw Failure.conversion }
        guard (try? input.read(into: whole)) != nil, whole.frameLength > 0 else { throw Failure.unreadable }

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("veda-calibration-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var frames: AVAudioFrameCount = 0
        do {
            // Scoped so the file is closed and flushed before the bytes are read back.
            guard let output = try? AVAudioFile(forWriting: scratch, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioImport.sampleRate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]) else { throw Failure.conversion }
            var delivered = false
            let feed: AVAudioConverterInputBlock = { _, status in
                if delivered { status.pointee = .endOfStream; return nil }
                delivered = true; status.pointee = .haveData; return whole
            }
            while true {
                chunk.frameLength = 0
                var failure: NSError?
                let status = converter.convert(to: chunk, error: &failure, withInputFrom: feed)
                if status == .error { throw Failure.conversion }
                if chunk.frameLength > 0 {
                    frames += chunk.frameLength
                    guard (try? output.write(from: chunk)) != nil else { throw Failure.conversion }
                }
                if status == .endOfStream || status == .inputRanDry || chunk.frameLength == 0 { break }
            }
        }
        guard frames > 0, let wav = try? Data(contentsOf: scratch) else { throw Failure.conversion }
        return Converted(wav: wav, seconds: Double(frames) / AudioImport.sampleRate)
    }
}
