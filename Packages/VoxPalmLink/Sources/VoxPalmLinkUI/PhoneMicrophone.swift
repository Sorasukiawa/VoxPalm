#if os(iOS)
import AudioToolbox
import AVFoundation
import Foundation

/// 使用返回 OSStatus 的 AudioQueue 输入接口；不安装会抛 Objective-C 异常的音频 tap。
@MainActor final class PhoneMicrophone: MobileAudioSource {
    private enum Failure: Error { case unavailable }
    private var current: Input?
    private var finishTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var ownsSession = false
    private var inputUID: String?
    private var onPCM: ((Data) -> Void)?
    private var onFailure: (() -> Void)?
    var permissionGranted: Bool {
        if #available(iOS 17, *) { return AVAudioApplication.shared.recordPermission == .granted }
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }
    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        let reply: @Sendable (Bool) -> Void = { granted in DispatchQueue.main.async { completion(granted) } }
        if #available(iOS 17, *) { AVAudioApplication.requestRecordPermission(completionHandler: reply) }
        else { AVAudioSession.sharedInstance().requestRecordPermission(reply) }
    }
    func start(onPCM: @escaping (Data) -> Void, onFailure: @escaping () -> Void) throws {
        guard current == nil, permissionGranted else { throw Failure.unavailable }
        self.onPCM = onPCM; self.onFailure = onFailure
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: [])
            try audio.setPreferredSampleRate(16_000)
            try audio.setPreferredIOBufferDuration(0.02)
            try audio.setActive(true); ownsSession = true
            guard let builtIn = audio.availableInputs?.first(where: { $0.portType == .builtInMic }) else { throw Failure.unavailable }
            try audio.setPreferredInput(builtIn); inputUID = builtIn.uid
            let input = Input { [weak self] in
                DispatchQueue.main.async { self?.drain() }
            }
            current = input
            try input.start()
            let center = NotificationCenter.default
            for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.routeChangeNotification] {
                observers.append(center.addObserver(forName: name, object: audio, queue: .main) { [weak self, weak input] note in
                    MainActor.assumeIsolated {
                        guard let self, let input, self.current === input else { return }
                        if note.name == AVAudioSession.routeChangeNotification,
                           audio.currentRoute.inputs.first?.uid == self.inputUID { return }
                        let callback = self.onFailure; self.cancel(); callback?()
                    }
                })
            }
        } catch { cancel(); throw Failure.unavailable }
    }
    private func drain() {
        guard let input = current else { return }
        let batch = input.mailbox.drain()
        if batch.failed { let callback = onFailure; cancel(); callback?(); return }
        for data in batch.buffers {
            guard current === input else { return }; onPCM?(data)
        }
    }
    func finish(_ completion: @escaping (Bool) -> Void) {
        guard let input = current, finishTask == nil else { completion(false); return }
        guard input.beginFinish() else { cancel(); completion(false); return }
        finishTask = Task { @MainActor [weak self, weak input] in
            let deadline = ContinuousClock.now + .seconds(2)
            while let self, let input, self.current === input, input.isRunning, ContinuousClock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
            guard let self, let input, self.current === input else { return }
            guard !input.isRunning else { self.cancel(); completion(false); return }
            input.dispose()
            self.drain()
            guard self.current === input else { return }
            self.cancel(); completion(true)
        }
    }
    func cancel() {
        finishTask?.cancel(); finishTask = nil
        let old = current; current = nil
        old?.mailbox.close(); old?.dispose()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        onPCM = nil; onFailure = nil; inputUID = nil
        if ownsSession {
            ownsSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    deinit {
        finishTask?.cancel(); current?.mailbox.close(); current?.dispose()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if ownsSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    private final class Input: @unchecked Sendable {
        let mailbox: PCMDeliveryQueue
        private var queue: AudioQueueRef?
        private let lock = NSLock()
        private var accepts = true
        private var reenqueue = true
        init(notify: @escaping @Sendable () -> Void) { mailbox = PCMDeliveryQueue(notify: notify) }
        func start() throws {
            var format = AudioStreamBasicDescription(mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            let context = Unmanaged.passUnretained(self).toOpaque()
            let status = AudioQueueNewInput(&format, { context, queue, buffer, _, _, _ in
                guard let context else { return }
                let input = Unmanaged<Input>.fromOpaque(context).takeUnretainedValue()
                input.lock.lock(); let accepts = input.accepts; let reenqueue = input.reenqueue; input.lock.unlock()
                guard accepts else { return }
                let size = Int(buffer.pointee.mAudioDataByteSize)
                if size > 0, size <= 1280, size.isMultiple(of: 2) {
                    input.mailbox.append(Data(bytes: buffer.pointee.mAudioData, count: size))
                } else if size != 0 { input.mailbox.fail() }
                if reenqueue, AudioQueueEnqueueBuffer(queue, buffer, 0, nil) != noErr { input.mailbox.fail() }
            }, context, nil, nil, 0, &queue)
            guard status == noErr, let queue else { throw Failure.unavailable }
            for _ in 0..<3 {
                var buffer: AudioQueueBufferRef?
                guard AudioQueueAllocateBuffer(queue, 1280, &buffer) == noErr, let buffer,
                      AudioQueueEnqueueBuffer(queue, buffer, 0, nil) == noErr else { throw Failure.unavailable }
            }
            guard AudioQueueStart(queue, nil) == noErr else { throw Failure.unavailable }
        }
        func beginFinish() -> Bool {
            lock.lock(); reenqueue = false; lock.unlock()
            guard let queue else { return false }
            return AudioQueueStop(queue, false) == noErr
        }
        var isRunning: Bool {
            guard let queue else { return false }
            var running: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            return AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size) != noErr || running != 0
        }
        func dispose() {
            lock.lock(); accepts = false; reenqueue = false; lock.unlock()
            guard let old = queue else { return }; queue = nil
            AudioQueueStop(old, true); AudioQueueDispose(old, true)
        }
    }
}
#endif
