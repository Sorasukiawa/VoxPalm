import Accelerate
import AVFoundation
import CoreAudio
import Foundation

public enum MicrophoneAccess {
    public static var status: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    public static var statusText: String {
        switch status {
        case .authorized: return "已允许"
        case .denied: return "已拒绝"
        case .restricted: return "受限制"
        case .notDetermined: return "还没问过"
        @unknown default: return "未知"
        }
    }

    /// 没决定过时弹系统授权框，阻塞到用户选完（不要在主线程调）。
    public static func requestBlocking() -> Bool {
        if status == .authorized { return true }
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            granted = ok
            semaphore.signal()
        }
        semaphore.wait()
        return granted
    }
}

/// 真的从某个收音设备录几秒，量出实际采样率、音量和有效频宽。
public struct CaptureMeasurement: Codable, Sendable {
    public let deviceName: String
    public let deviceUID: String
    public let transport: String
    public let seconds: Double
    public let nominalSampleRateBefore: Double
    public let nominalSampleRateDuring: Double
    /// CoreAudio 报告的实际运行采样率（只在设备运行时有）。
    public let actualSampleRate: Double?
    /// 用收到的采样数除以经过的时间算出来的采样率。
    public let measuredSampleRate: Double?
    public let channels: Int
    public let framesCaptured: Int
    public let peakDBFS: Double?
    public let rmsDBFS: Double?
    /// 95% / 99% 的声音能量落在这个频率以下（估算，要对着麦说话才有意义）。
    public let bandwidth95Hz: Double?
    public let bandwidth99Hz: Double?
    /// 4 kHz 以上的能量占比；16 kHz 的流里这个值接近 0，说明其实是 8 kHz 窄带升上来的。
    public let energyAbove4kHzRatio: Double?
    public let defaultOutputName: String?
    public let defaultOutputRateBefore: Double?
    public let defaultOutputRateDuring: Double?
    public let notes: [String]
}

public enum AudioCaptureMeter {
    public enum MeterError: Error, CustomStringConvertible {
        case deviceNotFound
        case noInput
        case coreAudio(String, OSStatus)

        public var description: String {
            switch self {
            case .deviceNotFound: return "找不到这个收音设备"
            case .noInput: return "这个设备没有输入声道"
            case let .coreAudio(step, status): return "CoreAudio \(step) 失败（\(status)）"
            }
        }
    }

    /// 阻塞录 `seconds` 秒，不要在主线程调。
    public static func measure(deviceID: AudioObjectID, seconds: Double) -> Result<CaptureMeasurement, MeterError> {
        guard let before = AudioDevices.device(id: deviceID) else { return .failure(.deviceNotFound) }
        guard before.hasInput else { return .failure(.noInput) }
        let outputID = AudioDevices.defaultOutputID
        let outputBefore = AudioDevices.device(id: outputID)

        // HAL 回调给的是设备的「虚拟格式」，一般是 32 位浮点；不是的话只数帧数、不做分析。
        let streams = CoreAudioProperty.array(deviceID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioStreamID.self)
        let virtualFormat: AudioStreamBasicDescription? = streams.first.map {
            CoreAudioProperty.value($0, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
        }
        let isFloat = virtualFormat.map {
            $0.mFormatID == kAudioFormatLinearPCM && $0.mFormatFlags & kAudioFormatFlagIsFloat != 0 && $0.mBitsPerChannel == 32
        } ?? true
        let collector = Collector(maxSamples: Int(max(before.nominalSampleRate, 48_000) * (seconds + 1)), isFloat: isFloat)
        var procID: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "voxpalm.capture-meter")
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, inputTime, _, _ in
            collector.consume(input, time: inputTime.pointee)
        }
        guard status == noErr, let procID else { return .failure(.coreAudio("创建录音回调", status)) }
        defer { AudioDeviceDestroyIOProcID(deviceID, procID) }
        status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else { return .failure(.coreAudio("开始录音", status)) }

        // 开麦后蓝牙耳机会切协议，等 1 秒再读运行中的采样率。
        Thread.sleep(forTimeInterval: min(1, seconds / 2))
        let during = AudioDevices.device(id: deviceID)
        let actual: Float64 = CoreAudioProperty.value(deviceID, kAudioDevicePropertyActualSampleRate, default: 0)
        let outputDuring = AudioDevices.device(id: outputID)
        Thread.sleep(forTimeInterval: max(0, seconds - min(1, seconds / 2)))
        AudioDeviceStop(deviceID, procID)
        queue.sync {}

        let snapshot = collector.snapshot()
        let rateForAnalysis = snapshot.measuredRate ?? during?.nominalSampleRate ?? before.nominalSampleRate
        let spectrum = Spectrum.analyze(snapshot.samples, sampleRate: rateForAnalysis)
        var notes: [String] = []
        if !snapshot.isFloat { notes.append("录音格式不是浮点，没做音量和频宽分析") }
        if snapshot.frames == 0 { notes.append("一帧都没收到：设备可能没在工作，或者没有麦克风权限") }
        if let peak = snapshot.peak, peak == 0, snapshot.frames > 0 { notes.append("收到的全是静音：多半是没有麦克风权限") }
        if let after = during, after.nominalSampleRate != before.nominalSampleRate {
            notes.append("开麦后采样率从 \(Int(before.nominalSampleRate)) 变成 \(Int(after.nominalSampleRate)) Hz")
        }
        if let a = outputBefore?.nominalSampleRate, let b = outputDuring?.nominalSampleRate, a != b {
            notes.append("开麦期间系统默认输出「\(outputBefore?.name ?? "")」的采样率从 \(Int(a)) 变成 \(Int(b)) Hz")
        }

        return .success(CaptureMeasurement(
            deviceName: before.name,
            deviceUID: before.uid,
            transport: before.transport,
            seconds: seconds,
            nominalSampleRateBefore: before.nominalSampleRate,
            nominalSampleRateDuring: during?.nominalSampleRate ?? before.nominalSampleRate,
            actualSampleRate: actual > 0 ? actual : nil,
            measuredSampleRate: snapshot.measuredRate,
            channels: snapshot.channels,
            framesCaptured: snapshot.frames,
            peakDBFS: snapshot.peak.map(dbfs),
            rmsDBFS: snapshot.rms.map(dbfs),
            bandwidth95Hz: spectrum?.f95,
            bandwidth99Hz: spectrum?.f99,
            energyAbove4kHzRatio: spectrum?.above4k,
            defaultOutputName: outputBefore?.name,
            defaultOutputRateBefore: outputBefore?.nominalSampleRate,
            defaultOutputRateDuring: outputDuring?.nominalSampleRate,
            notes: notes
        ))
    }

    static func dbfs(_ value: Float) -> Double {
        value > 0 ? (20 * log10(Double(value)) * 10).rounded() / 10 : -120
    }

    /// 在录音线程里攒数据；只留第一个声道做分析。
    final class Collector: @unchecked Sendable {
        struct Snapshot {
            let samples: [Float]
            let frames: Int
            let channels: Int
            let isFloat: Bool
            let measuredRate: Double?
            let peak: Float?
            let rms: Float?
        }

        private let lock = NSLock()
        private let maxSamples: Int
        private var samples: [Float] = []
        private var frames = 0
        private var channels = 0
        private let isFloat: Bool
        private var first: (sample: Double, host: UInt64)?
        private var last: (sample: Double, host: UInt64)?

        init(maxSamples: Int, isFloat: Bool) {
            self.maxSamples = maxSamples
            self.isFloat = isFloat
            samples.reserveCapacity(maxSamples)
        }

        func consume(_ list: UnsafePointer<AudioBufferList>, time: AudioTimeStamp) {
            lock.lock()
            defer { lock.unlock() }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            guard let buffer = buffers.first, let data = buffer.mData else { return }
            let channelCount = max(Int(buffer.mNumberChannels), 1)
            channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
            let count = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            frames += count
            if isFloat {
                let floats = data.assumingMemoryBound(to: Float.self)
                for i in 0..<count where samples.count < maxSamples {
                    samples.append(floats[i * channelCount])
                }
            }
            let valid = time.mFlags.contains(.sampleTimeValid) && time.mFlags.contains(.hostTimeValid)
            if valid {
                if first == nil { first = (time.mSampleTime, time.mHostTime) }
                last = (time.mSampleTime, time.mHostTime)
            }
        }

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            var rate: Double?
            if let first, let last, last.host > first.host {
                let elapsed = MonotonicClock.seconds(machTime: last.host) - MonotonicClock.seconds(machTime: first.host)
                if elapsed > 0.5 { rate = ((last.sample - first.sample) / elapsed).rounded() }
            }
            var peak: Float?
            var rms: Float?
            if !samples.isEmpty {
                var p: Float = 0
                var r: Float = 0
                vDSP_maxmgv(samples, 1, &p, vDSP_Length(samples.count))
                vDSP_rmsqv(samples, 1, &r, vDSP_Length(samples.count))
                peak = p
                rms = r
            }
            return Snapshot(samples: samples, frames: frames, channels: channels, isFloat: isFloat, measuredRate: rate, peak: peak, rms: rms)
        }
    }
}

enum Spectrum {
    struct Result {
        let f95: Double
        let f99: Double
        let above4k: Double
    }

    /// 平均功率谱，算 95% / 99% 能量所在的频率上限。
    static func analyze(_ samples: [Float], sampleRate: Double) -> Result? {
        let n = 1024
        let log2n = vDSP_Length(10)
        guard samples.count >= n * 2, sampleRate > 0, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var power = [Double](repeating: 0, count: n / 2)
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var frame = [Float](repeating: 0, count: n)
        for start in stride(from: 0, through: samples.count - n, by: n / 2) {
            samples.withUnsafeBufferPointer { src in
                vDSP_vmul(src.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    for k in 1..<(n / 2) {
                        power[k] += Double(rp[k] * rp[k] + ip[k] * ip[k])
                    }
                }
            }
        }
        let total = power.reduce(0, +)
        guard total > 0 else { return nil }
        let binHz = sampleRate / Double(n)
        var cumulative = 0.0
        var f95: Double?
        var f99: Double?
        var above4k = 0.0
        for k in 1..<(n / 2) {
            cumulative += power[k]
            let freq = Double(k) * binHz
            if f95 == nil, cumulative >= total * 0.95 { f95 = freq }
            if f99 == nil, cumulative >= total * 0.99 { f99 = freq }
            if freq >= 4_000 { above4k += power[k] }
        }
        return Result(f95: (f95 ?? 0).rounded(), f99: (f99 ?? 0).rounded(), above4k: (above4k / total * 1000).rounded() / 1000)
    }
}
