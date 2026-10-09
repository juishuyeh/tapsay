import AVFoundation
import Foundation

public struct RecorderError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// 麥克風 → 16 kHz 單聲道 16-bit WAV（只存在記憶體，送出後即消失，不落地）。
///
/// iOS 鍵盤模式需要「先把麥克風開著、之後才開始收音」：App 必須在前景時就啟動錄音，
/// 退到背景後才能靠 audio background mode 繼續活著，所以引擎（`warmUp`）與收音（`begin`/`end`）分開。
public final class AudioRecorder {
    public static let sampleRate: Double = 16_000
    /// 太短的錄音（多半是誤觸）直接當成沒錄到。
    public static let minimumDuration: Double = 0.3

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var pcm = Data()
    private var capturing = false
    private var converter: AVAudioConverter?
    public private(set) var isRunning = false

    public init() {}

    public var isCapturing: Bool {
        lock.lock(); defer { lock.unlock() }
        return capturing
    }

    /// 啟動音訊引擎但不收音。
    public func warmUp() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw RecorderError(message: "找不到可用的麥克風")
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate,
                                            channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw RecorderError(message: "無法建立音訊格式轉換") }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.consume(buffer, outFormat: outFormat)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError(message: "麥克風無法啟動：\(error.localizedDescription)")
        }
        isRunning = true
    }

    public func coolDown() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        lock.lock(); capturing = false; pcm.removeAll(); lock.unlock()
    }

    public func begin() throws {
        try warmUp()
        lock.lock(); pcm.removeAll(keepingCapacity: true); capturing = true; lock.unlock()
    }

    /// 停止收音並回傳 WAV。引擎是否繼續跑由呼叫端決定（`coolDown`）。
    public func end() throws -> Data {
        lock.lock()
        capturing = false
        let samples = pcm
        pcm.removeAll()
        lock.unlock()
        let seconds = Double(samples.count) / 2 / Self.sampleRate
        guard seconds >= Self.minimumDuration else { throw RecorderError(message: "沒有錄到聲音") }
        return WAV.encode(pcm16: samples, sampleRate: Int(Self.sampleRate))
    }

    public func cancel() {
        lock.lock(); capturing = false; pcm.removeAll(); lock.unlock()
    }

    // 音訊執行緒
    private func consume(_ buffer: AVAudioPCMBuffer, outFormat: AVAudioFormat) {
        lock.lock()
        let active = capturing
        lock.unlock()
        guard active, let converter else { return }

        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let bytes = Data(bytes: channel[0], count: Int(out.frameLength) * 2)
        lock.lock()
        if capturing { pcm.append(bytes) }
        lock.unlock()
    }
}

public enum WAV {
    public static func encode(pcm16: Data, sampleRate: Int, channels: Int = 1) -> Data {
        var d = Data(capacity: 44 + pcm16.count)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let byteRate = sampleRate * channels * 2
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm16.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(channels * 2)); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm16.count))
        d.append(pcm16)
        return d
    }
}
