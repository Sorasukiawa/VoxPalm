import AppKit
import Foundation
import ProbeKit
import VoxPalmDevices

/// 同一台物理设备的几个 HID 接口合成一项，方便选。
struct PhysicalHID {
    let key: String
    let interfaces: [HIDDeviceInfo]

    var name: String { interfaces[0].displayName }
    var line: String {
        let first = interfaces[0]
        let kinds = Array(Set(interfaces.flatMap(\.kinds))).sorted().joined(separator: "、")
        return "\(name)  \(first.vendorProduct)  \(first.transport ?? "未知传输")  \(kinds)"
    }

    static func group(_ devices: [HIDDeviceInfo]) -> [PhysicalHID] {
        var order: [String] = []
        var map: [String: [HIDDeviceInfo]] = [:]
        for device in devices {
            if map[device.physicalKey] == nil { order.append(device.physicalKey) }
            map[device.physicalKey, default: []].append(device)
        }
        return order.map { PhysicalHID(key: $0, interfaces: map[$0]!) }
    }
}

final class ProbeCLI {
    private let arguments: [String]
    private var redact = true

    init(arguments: [String]) {
        self.arguments = arguments
    }

    func run() -> Int32 {
        var args = arguments
        if let index = args.firstIndex(of: "--no-redact") {
            redact = false
            args.remove(at: index)
        }
        let command = args.first ?? "help"
        let rest = Array(args.dropFirst())
        // 在开麦或登记系统监听前拒绝无效时长，避免 NaN / 无穷大转整数时崩溃。
        if command == "audio" || command == "watch", rest.contains("--seconds") {
            // 音频测量会按采样率预留内存；它只用于测电平/频宽，不是长时间录音工具。
            let limit: Double = command == "audio" ? 60 : 86_400
            guard let raw = option("--seconds", in: rest), let seconds = Double(raw),
                  seconds.isFinite, seconds > 0, seconds <= limit else {
                Console.say("\(command) 的 --seconds 需要大于 0、且不超过 \(Int(limit)) 秒。")
                return 1
            }
        }
        switch command {
        case "list": return list(all: rest.contains("--all"))
        case "permissions": return permissions()
        case "audio": return audio(rest)
        case "watch": return watch(rest)
        case "wizard": return wizard(rest)
        default:
            usage()
            return command == "help" || command == "--help" || command == "-h" ? 0 : 1
        }
    }

    private func usage() {
        Console.say("""
        掌声 VoxPalm 设备探针 \(ProbeVersion.string)
        只监听、不拦截：探针运行时设备照常工作，不改任何系统设置。

        用法：voxpalm-probe <命令> [选项]

        命令：
          list [--all]          列出外接 HID 设备和音频设备（--all 连内置键盘、触控板一起列），检查权限
          permissions           检查并申请「输入监控」和「麦克风」权限
          audio [--measure <序号或名称>] [--seconds 5]
                                列出收音设备；--measure 真的录几秒，量实际采样率和频宽
          watch [--hid <序号,…|all>] [--raw] [--seconds N] [--out 目录]
                                实时打印所有通道的事件，按回车结束
          wizard [--out 目录]   手势向导：逐个键测单击、双击、长按 1 秒、长按 3 秒，生成 JSON 和 Markdown 报告

        选项：
          --no-redact           报告里保留完整蓝牙地址和 USB 序列号（默认蓝牙地址只留前 3 段，序列号重算）
        """)
    }

    private func option(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    // MARK: - 权限

    private var permissionSummary: [String: String] {
        [
            "输入监控（HID）": HIDAccess.isGranted ? "已允许" : (HIDAccess.isDenied ? "已拒绝" : "还没问过"),
            "输入监控（系统事件）": SystemEventMonitor.hasListenAccess ? "已允许" : "未允许",
            "麦克风": MicrophoneAccess.statusText,
        ]
    }

    private func printPermissions() {
        let host = Console.hostAppName() ?? "你运行探针的终端 App"
        Console.say("权限（授给「\(host)」）：")
        for (name, state) in permissionSummary.sorted(by: { $0.key < $1.key }) {
            Console.say("  \(state == "已允许" ? "✅" : "❌") \(name)：\(state)")
        }
    }

    private func permissionHelp() {
        let host = Console.hostAppName() ?? "你运行探针的终端 App"
        Console.say("""
          没有输入监控权限时，键盘类设备的按键和系统媒体键都读不到。打开方法：
          系统设置 → 隐私与安全性 → 输入监控 → 打开「\(host)」的开关（没有就点 + 加进去），然后完全退出「\(host)」再打开。
          麦克风同理：系统设置 → 隐私与安全性 → 麦克风 → 打开「\(host)」。
        """)
    }

    private func permissions() -> Int32 {
        printPermissions()
        if !HIDAccess.isGranted { HIDAccess.request() }
        if !SystemEventMonitor.hasListenAccess { SystemEventMonitor.requestListenAccess() }
        if MicrophoneAccess.status == .notDetermined { _ = MicrophoneAccess.requestBlocking() }
        Console.say()
        Console.say("申请之后：")
        printPermissions()
        if !HIDAccess.isGranted || MicrophoneAccess.status != .authorized { permissionHelp() }
        return 0
    }

    // MARK: - list

    private func list(all: Bool) -> Int32 {
        printPermissions()
        Console.say()
        let devices = HIDMonitor.snapshot().filter { all || !$0.isBuiltIn }
        Console.say(all ? "HID 设备（全部）：" : "外接 HID 设备（同一台设备的多个接口合成一行）：")
        let groups = PhysicalHID.group(devices)
        if groups.isEmpty { Console.say("  （没有）") }
        for (index, group) in groups.enumerated() {
            Console.say("  [\(index + 1)] \(group.line)")
            for interface in group.interfaces {
                let usages = interface.usagePairs.map(\.label).joined(separator: "，")
                Console.say("       · \(usages)")
            }
        }
        Console.say()
        printAudioDevices()
        return 0
    }

    private func printAudioDevices() {
        let devices = AudioDevices.all()
        Console.say("收音设备：")
        let inputs = devices.filter(\.hasInput)
        for (index, device) in inputs.enumerated() {
            Console.say("  [\(index + 1)] \(audioLine(device))")
        }
        if let output = devices.first(where: \.isDefaultOutput) {
            Console.say("系统默认输出：\(output.name)（\(output.transport)，\(Int(output.nominalSampleRate)) Hz）")
        }
    }

    private func audioLine(_ device: AudioDeviceInfo) -> String {
        var line = "\(device.name)  \(device.transport)  \(Int(device.nominalSampleRate)) Hz  \(device.inputChannels) 声道"
        if let profile = device.bluetoothProfileGuess { line += "  \(device.isLowRateBluetoothInput ? "⚠️ " : "")\(profile)" }
        if device.isDefaultInput { line += "  （系统默认输入）" }
        return line
    }

    // MARK: - audio

    private func audio(_ args: [String]) -> Int32 {
        printAudioDevices()
        guard let target = option("--measure", in: args) else { return 0 }
        let seconds = option("--seconds", in: args).flatMap(Double.init) ?? 5
        let inputs = AudioDevices.inputs()
        let device: AudioDeviceInfo?
        if let index = Int(target), index >= 1, index <= inputs.count {
            device = inputs[index - 1]
        } else {
            device = inputs.first { $0.name.localizedCaseInsensitiveContains(target) || $0.uid == target }
        }
        guard let device else {
            Console.say("找不到收音设备「\(target)」")
            return 1
        }
        guard let measurement = measure(device, seconds: seconds, interactive: false) else { return 1 }
        if let out = option("--out", in: args) {
            var report = ProbeReport(device: .init(name: device.name))
            report.permissions = permissionSummary
            report.audioDevices = AudioDevices.all()
            report.captures = [measurement]
            if !write(report, to: URL(fileURLWithPath: out)) { return 1 }
        }
        return 0
    }

    private func measure(_ device: AudioDeviceInfo, seconds: Double, interactive: Bool) -> CaptureMeasurement? {
        if MicrophoneAccess.status == .notDetermined { _ = MicrophoneAccess.requestBlocking() }
        if MicrophoneAccess.status != .authorized {
            Console.say("⚠️ 没有麦克风权限，录到的会是静音，采样率照样能量。")
        }
        if interactive {
            _ = Console.ask("准备好后按回车，然后对着「\(device.name)」正常说话 \(Int(seconds)) 秒：")
        }
        Console.say("录音中（\(Int(seconds)) 秒），请对着「\(device.name)」说话……")
        switch AudioCaptureMeter.measure(deviceID: device.id, seconds: seconds) {
        case let .failure(error):
            Console.say("❌ 录音失败：\(error)")
            return nil
        case let .success(m):
            Console.say("结果：")
            Console.say("  标称采样率：开麦前 \(Int(m.nominalSampleRateBefore)) Hz，开麦后 \(Int(m.nominalSampleRateDuring)) Hz")
            if let actual = m.actualSampleRate { Console.say("  系统报告的实际采样率：\(String(format: "%.1f", actual)) Hz") }
            if let rate = m.measuredSampleRate { Console.say("  按收到的采样数算：\(Int(rate)) Hz（\(m.framesCaptured) 帧，\(m.channels) 声道）") }
            if let peak = m.peakDBFS, let rms = m.rmsDBFS { Console.say("  音量：峰值 \(peak) dBFS，平均 \(rms) dBFS") }
            if let f95 = m.bandwidth95Hz, let f99 = m.bandwidth99Hz { Console.say("  有效频宽（估算）：95% 能量在 \(Int(f95)) Hz 以下，99% 在 \(Int(f99)) Hz 以下") }
            if let ratio = m.energyAbove4kHzRatio { Console.say("  4 kHz 以上能量占比：\(String(format: "%.1f", ratio * 100))%") }
            for note in m.notes { Console.say("  ⚠️ \(note)") }
            return m
        }
    }

    // MARK: - watch

    private func watch(_ args: [String]) -> Int32 {
        printPermissions()
        let recorder = ProbeRecorder()
        let showRaw = args.contains("--raw")
        let groups = PhysicalHID.group(HIDMonitor.snapshot().filter { !$0.isBuiltIn })
        if let selection = option("--hid", in: args), selection != "all" {
            let keys = Set(Console.indices(selection, count: groups.count).map { groups[$0].key })
            recorder.hidFilter = { keys.contains($0.physicalKey) }
        }
        recorder.onLive = { event in
            if event.channel == .hidReport && !showRaw { return }
            if event.channel == .hid && event.phase == .value { return }
            Console.say(event.line)
        }
        DispatchQueue.main.sync { recorder.startMonitors() }
        Console.say("通道：HID \(recorder.status.hid)；系统事件 \(recorder.status.systemEvents)；正在播放 \(recorder.status.remoteCommands)；音频 \(recorder.status.audio)")
        recorder.beginCapture()
        if let seconds = option("--seconds", in: args).flatMap(Double.init) {
            Console.say("记录 \(Int(seconds)) 秒……")
            Thread.sleep(forTimeInterval: seconds)
        } else {
            _ = Console.ask("开始记录，按设备上的键看看；按回车结束。\n")
        }
        let events = recorder.endCapture()
        DispatchQueue.main.sync { recorder.stopMonitors() }
        Console.say("共 \(events.count) 条事件。")
        if let out = option("--out", in: args) {
            let directory = URL(fileURLWithPath: out)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                var text = String(decoding: try encoder.encode(events), as: UTF8.self)
                if redact { text = Redaction.redactReport(text) }
                let file = directory.appendingPathComponent("watch.json")
                try text.write(to: file, atomically: true, encoding: .utf8)
                Console.say("已写入 \(file.path)")
            } catch {
                Console.say("❌ 写文件失败：\(error)")
                return 1
            }
        }
        return 0
    }

    // MARK: - wizard

    private func wizard(_ args: [String]) -> Int32 {
        Console.say("掌声 VoxPalm 设备探针 · 手势向导")
        Console.say("只监听、不拦截：测试时设备照常工作。测试的那几秒里请别碰键盘，免得混进别的按键。")
        Console.say()
        printPermissions()
        if !HIDAccess.isGranted || !SystemEventMonitor.hasListenAccess {
            HIDAccess.request()
            SystemEventMonitor.requestListenAccess()
            permissionHelp()
            if !Console.confirm("没有输入监控权限，很多按键会读不到。仍然继续吗？[y/N] ") { return 1 }
        }
        Console.say()

        var name = ""
        while name.isEmpty { name = Console.ask("设备名称（如「小米蓝牙遥控器 2」）：") }
        let model = Console.ask("型号（可留空）：")
        let connection = Console.ask("连接方式（蓝牙 / USB / 2.4G 接收器，可留空）：")
        let notes = Console.ask("备注（可留空）：")
        var report = ProbeReport(device: .init(
            name: name,
            model: model.isEmpty ? nil : model,
            connection: connection.isEmpty ? nil : connection,
            notes: notes.isEmpty ? nil : notes
        ))
        let outDirectory = URL(fileURLWithPath: option("--out", in: args) ?? defaultOutPath(for: name))

        let recorder = ProbeRecorder()
        recorder.onLive = { event in
            guard event.isSignal else { return }
            Console.say("    " + event.line)
        }
        DispatchQueue.main.sync { recorder.startMonitors() }
        report.channels = recorder.status

        // HID 设备
        Console.say()
        let groups = PhysicalHID.group(HIDMonitor.snapshot().filter { !$0.isBuiltIn })
        if groups.isEmpty {
            Console.say("没找到外接 HID 设备（无线麦这类只走音频的设备是正常的）。")
        } else {
            Console.say("外接 HID 设备：")
            for (index, group) in groups.enumerated() { Console.say("  [\(index + 1)] \(group.line)") }
            let answer = Console.ask("记录哪台的输入？输入序号，多个用逗号；回车 = 全部外接设备；0 = 不记录 HID：")
            var chosen = groups
            if answer == "0" {
                chosen = []
            } else if !answer.isEmpty {
                chosen = Console.indices(answer, count: groups.count).map { groups[$0] }
            }
            let keys = Set(chosen.map(\.key))
            recorder.hidFilter = { keys.contains($0.physicalKey) }
            report.hidDevices = chosen.flatMap(\.interfaces)
        }

        // 收音
        Console.say()
        let inputs = AudioDevices.inputs()
        Console.say("收音设备：")
        for (index, device) in inputs.enumerated() { Console.say("  [\(index + 1)] \(audioLine(device))") }
        let micAnswer = Console.ask("要实测哪个收音设备的采样率？输入序号；回车 = 跳过：")
        if let index = Console.indices(micAnswer, count: inputs.count).first,
           let measurement = measure(inputs[index], seconds: 5, interactive: true) {
            report.captures.append(measurement)
        }
        report.audioDevices = AudioDevices.all()
        report.permissions = permissionSummary

        // 连接测试
        Console.say()
        if Console.confirm("要做连接测试吗？断开设备再连上，看系统默认输出会不会被它抢走。[y/N] ") {
            _ = Console.ask("先把设备断开或关机，完成后按回车：")
            recorder.beginCapture()
            _ = Console.ask("现在把设备重新连上或开机，连上后再等 5 秒，然后按回车：")
            let test = ProbeReport.ConnectionTest.analyze(recorder.endCapture())
            Console.say("→ \(test.summary)")
            report.connectionTest = test
            report.audioDevices = AudioDevices.all()
        }

        // 按键
        Console.say()
        Console.say("开始测按键。每个键依次测：" + Gesture.allCases.map(\.title).joined(separator: "、") + "。")
        Console.say("如果你知道某个手势会让设备关机、切模式或进配对，提示时输入 s 跳过，它会被标成「被固件占用」。")
        while true {
            Console.say()
            let keyName = Console.ask("键的名字（如「录制键」「音量 +」；直接回车 = 测完了）：")
            if keyName.isEmpty { break }
            var keyReport = ProbeReport.KeyReport(name: keyName)
            var reference: GestureResult?
            for gesture in Gesture.allCases {
                let answer = Console.ask("【\(keyName)】\(gesture.title)：\(gesture.instruction)。按回车开始（s = 跳过）：")
                if answer.lowercased() == "s" {
                    let reason = Console.ask("  跳过原因（如「会切模式」；回车 = 只是不测）：")
                    var skipped = GestureResult(gesture: gesture)
                    skipped.skipped = true
                    if !reason.isEmpty {
                        skipped.firmware = .occupied
                        skipped.firmwareReaction = reason
                    }
                    skipped.verdict = reason.isEmpty ? "跳过" : "跳过：\(reason)"
                    keyReport.gestures.append(skipped)
                    continue
                }
                let events = capture(gesture, recorder: recorder)
                let reaction = Console.ask("  设备自己有没有做别的事（指示灯变了、切模式、关机、进配对）？回车 = 没有，有就简单描述：")
                let result = GestureAnalyzer.analyze(gesture, events: events, reference: reference, firmwareReaction: reaction)
                if gesture == .single { reference = result }
                Console.say("  → \(result.verdict)")
                keyReport.gestures.append(result)
            }
            report.keys.append(keyReport)
            // 每测完一个键就存一次，中途退出也不丢。
            write(report, to: outDirectory, quiet: true)
        }

        DispatchQueue.main.sync { recorder.stopMonitors() }
        return write(report, to: outDirectory) ? 0 : 1
    }

    private func capture(_ gesture: Gesture, recorder: ProbeRecorder) -> [ProbeEvent] {
        // 等回车键松开，免得把它记进去。
        Thread.sleep(forTimeInterval: 0.35)
        recorder.beginCapture()
        Console.say("  记录中：现在\(gesture.instruction)（停手 \(Int(gesture.quietSeconds)) 秒后自动结束，最多等 \(Int(gesture.timeoutSeconds)) 秒）")
        let start = recorder.now()
        while true {
            Thread.sleep(forTimeInterval: 0.05)
            let now = recorder.now()
            if let last = recorder.lastSignalTime, now - last >= gesture.quietSeconds { break }
            if now - start >= gesture.timeoutSeconds { break }
        }
        return recorder.endCapture()
    }

    private func defaultOutPath(for name: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let slug = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
        return "probe-reports/\(formatter.string(from: Date()))-\(slug)"
    }

    @discardableResult
    private func write(_ report: ProbeReport, to directory: URL, quiet: Bool = false) -> Bool {
        do {
            let files = try report.write(to: directory, redact: redact)
            if !quiet {
                Console.say()
                Console.say("报告已写入：")
                for file in files { Console.say("  \(file.path)") }
            }
            return true
        } catch {
            Console.say("❌ 写报告失败：\(error)")
            return false
        }
    }
}
