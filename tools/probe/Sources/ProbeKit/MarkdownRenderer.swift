import Foundation
import VoxPalmDevices

/// 把报告排成给人看的 Markdown（中文）。
public enum MarkdownRenderer {
    public static func render(_ report: ProbeReport, maxEventsPerGesture: Int = 40) -> String {
        var out: [String] = []
        let title = [report.device.name, report.device.model.map { "（\($0)）" }].compactMap { $0 }.joined()
        out.append("# 设备探针报告：\(title)")
        out.append("")
        let date = ISO8601DateFormatter.string(from: report.generatedAt, timeZone: .current, formatOptions: [.withInternetDateTime])
        out.append("- 生成时间：\(date)")
        out.append("- Mac：\(report.mac.model)，\(report.mac.macOS)")
        out.append("- 工具：\(report.tool)")
        if let connection = report.device.connection { out.append("- 连接方式：\(connection)") }
        if let notes = report.device.notes { out.append("- 备注：\(notes)") }
        if !report.permissions.isEmpty {
            out.append("- 权限：" + report.permissions.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "，"))
        }
        if let channels = report.channels {
            out.append("- 通道：HID \(channels.hid)；系统事件 \(channels.systemEvents)；正在播放 \(channels.remoteCommands)；音频 \(channels.audio)")
        }
        out.append("")

        if !report.keys.isEmpty {
            out.append("## 结论")
            out.append("")
            out.append("| 键 | " + Gesture.allCases.map(\.title).joined(separator: " | ") + " |")
            out.append("|---|" + Gesture.allCases.map { _ in "---" }.joined(separator: "|") + "|")
            for key in report.keys {
                let cells = Gesture.allCases.map { gesture -> String in
                    guard let result = key.gestures.first(where: { $0.gesture == gesture }) else { return "未测" }
                    return cell(result)
                }
                out.append("| \(escape(key.name)) | " + cells.joined(separator: " | ") + " |")
            }
            out.append("")
            out.append("图例：✅ 能读到按下和松开；⚡ 只有一次性触发、没有松开；⏱ 能读到按住时长；🔁 按住时自动连发；🔀 固件改写成别的键；⛔ 被固件占用；❓ 疑似被固件占用；✖️ 没有事件。")
            out.append("")
            out.append("## 按键详情")
            out.append("")
            for key in report.keys {
                out.append("### \(key.name)")
                out.append("")
                out.append("| 手势 | 读到的键 | 松开 | 最长按住 | 固件 | 结论 |")
                out.append("|---|---|---|---|---|---|")
                for result in key.gestures {
                    let controls = result.controls.filter { $0.channel != .audio || $0.control.hasPrefix("音量") || $0.control.hasPrefix("静音") }
                    let names = controls.isEmpty ? "—" : controls.map { "\($0.label) ×\(max($0.presses, $0.changes))" }.joined(separator: "<br>")
                    let hold = result.longestHold.map { String(format: "%.2f 秒", $0) } ?? "—"
                    out.append("| \(result.gesture.title)\(result.skipped ? "（跳过）" : "") | \(escape(names)) | \(result.hasRelease ? "有" : "没有") | \(hold) | \(result.firmwareTitle) | \(escape(result.verdict)) |")
                }
                out.append("")
            }
        }

        if !report.hidDevices.isEmpty {
            out.append("## HID 设备")
            out.append("")
            out.append("| 名称 | 厂商 ID:产品 ID | 传输 | 类型 | 用途 |")
            out.append("|---|---|---|---|---|")
            for device in report.hidDevices {
                let usages = device.usagePairs.map(\.label).joined(separator: "<br>")
                out.append("| \(escape(device.displayName)) | \(device.vendorProduct) | \(device.transport ?? "—") | \(device.kinds.joined(separator: "、")) | \(escape(usages)) |")
            }
            out.append("")
        }

        let inputs = report.audioDevices.filter(\.hasInput)
        if !inputs.isEmpty {
            out.append("## 收音设备")
            out.append("")
            out.append("| 名称 | 传输 | 当前采样率 | 可选采样率 | 输入声道 | 蓝牙协议判断 | 默认输入 |")
            out.append("|---|---|---|---|---|---|---|")
            for device in inputs {
                let rates = device.availableSampleRates.map { $0[0] == $0[1] ? hz($0[0]) : "\(hz($0[0]))–\(hz($0[1]))" }.joined(separator: "、")
                let profile = device.bluetoothProfileGuess.map { device.isLowRateBluetoothInput ? "⚠️ \($0)" : $0 } ?? "—"
                out.append("| \(escape(device.name)) | \(device.transport) | \(hz(device.nominalSampleRate)) | \(rates) | \(device.inputChannels) | \(profile) | \(device.isDefaultInput ? "是" : "") |")
            }
            out.append("")
            let outputs = report.audioDevices.filter { $0.isDefaultOutput }
            if let output = outputs.first {
                out.append("当前系统默认输出：\(output.name)（\(output.transport)，\(hz(output.nominalSampleRate))）")
                out.append("")
            }
        }

        if !report.captures.isEmpty {
            out.append("## 实测录音")
            out.append("")
            for capture in report.captures {
                out.append("### \(capture.deviceName)（\(capture.transport)）")
                out.append("")
                out.append("- 标称采样率：开麦前 \(hz(capture.nominalSampleRateBefore))，开麦后 \(hz(capture.nominalSampleRateDuring))")
                if let actual = capture.actualSampleRate { out.append("- 系统报告的实际采样率：\(String(format: "%.1f", actual)) Hz") }
                if let measured = capture.measuredSampleRate { out.append("- 按收到的采样数算：\(String(format: "%.0f", measured)) Hz（录了 \(String(format: "%.1f", capture.seconds)) 秒，\(capture.framesCaptured) 帧，\(capture.channels) 声道）") }
                if let peak = capture.peakDBFS, let rms = capture.rmsDBFS { out.append("- 音量：峰值 \(peak) dBFS，平均 \(rms) dBFS") }
                if let f95 = capture.bandwidth95Hz, let f99 = capture.bandwidth99Hz {
                    out.append("- 有效频宽（估算）：95% 能量在 \(hz(f95)) 以下，99% 在 \(hz(f99)) 以下")
                }
                if let ratio = capture.energyAbove4kHzRatio { out.append("- 4 kHz 以上能量占比：\(String(format: "%.1f", ratio * 100))%") }
                if let name = capture.defaultOutputName, let a = capture.defaultOutputRateBefore, let b = capture.defaultOutputRateDuring {
                    out.append("- 系统默认输出「\(name)」：开麦前 \(hz(a))，开麦期间 \(hz(b))")
                }
                for note in capture.notes { out.append("- ⚠️ \(note)") }
                out.append("")
            }
        }

        if let test = report.connectionTest {
            out.append("## 连接测试")
            out.append("")
            out.append(test.summary)
            out.append("")
            appendEvents(test.events, limit: maxEventsPerGesture, to: &out)
        }

        if !report.notes.isEmpty {
            out.append("## 备注")
            out.append("")
            for note in report.notes { out.append("- \(note)") }
            out.append("")
        }

        if !report.keys.isEmpty {
            out.append("## 原始事件")
            out.append("")
            out.append("时间是相对探针启动的秒数。每个手势最多列 \(maxEventsPerGesture) 条，完整记录在 report.json。")
            out.append("")
            for key in report.keys {
                for result in key.gestures where !result.events.isEmpty {
                    out.append("### \(key.name) · \(result.gesture.title)")
                    out.append("")
                    appendEvents(result.events, limit: maxEventsPerGesture, to: &out)
                }
            }
        }
        return out.joined(separator: "\n")
    }

    static func cell(_ result: GestureResult) -> String {
        if result.skipped && result.events.isEmpty { return result.firmware == .occupied ? "⛔ 跳过（固件占用）" : "跳过" }
        if result.firmware == .occupied { return "⛔ " + (result.firmwareReaction ?? "设备断开或切模式") }
        let controls = result.controls.filter { $0.channel != .audio || $0.control.hasPrefix("音量") || $0.control.hasPrefix("静音") }
        if controls.isEmpty { return result.firmware == .suspected ? "❓ 没有事件" : "✖️ 没有事件" }
        var marks: [String] = []
        let main = controls.max { $0.presses < $1.presses } ?? controls[0]
        if let target = result.gesture.holdSeconds, let hold = result.longestHold, hold >= target * 0.6 {
            marks.append(String(format: "⏱ %.1f 秒", hold))
        } else if main.repeats > 0 {
            marks.append("🔁 连发")
        } else if result.hasRelease {
            marks.append(result.gesture == .double ? "✅ \(main.presses) 次" : "✅")
        } else {
            marks.append("⚡ 无松开")
        }
        if result.firmware == .rewritten { marks.append("🔀 改写") }
        return marks.joined(separator: " ") + "<br>" + escape(main.control)
    }

    static func appendEvents(_ events: [ProbeEvent], limit: Int, to out: inout [String]) {
        guard !events.isEmpty else { return }
        out.append("```")
        for event in events.prefix(limit) { out.append(event.line) }
        if events.count > limit { out.append("…… 还有 \(events.count - limit) 条") }
        out.append("```")
        out.append("")
    }

    static func hz(_ value: Double) -> String {
        value >= 1000 ? "\((value / 1000).formatted(.number.precision(.fractionLength(0...3)))) kHz" : "\(Int(value)) Hz"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }
}
