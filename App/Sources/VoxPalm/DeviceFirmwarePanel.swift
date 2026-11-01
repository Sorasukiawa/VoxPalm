import AppKit
import SwiftUI
import VoxPalmDevices

struct DeviceFirmwarePanel: View {
    @Environment(AppModel.self) private var model
    let id: String?
    let guide: DeviceFirmwareGuide?
    @State private var confirmsInstallation = false
    private var result: FirmwareUpdateStore.Result? { id.flatMap { model.firmwareUpdates.results[$0] } }
    private var target: HIDDeviceInfo? {
        guard let id, case .hid(let info) = model.deviceStatus.target(for: id) else { return nil }
        return info
    }
    private var busy: Bool { model.firmwareUpdates.busyID != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("固件更新").font(.subheadline.weight(.medium))
                Spacer()
                if model.firmwareUpdates.supports(target) {
                    Button("检查更新", systemImage: "arrow.triangle.2.circlepath") {
                        guard let id, let target, model.voiceState == .idle, !model.isDeviceStatusPreview else { return }
                        model.firmwareUpdates.check(id: id, device: target)
                    }.disabled(busy || model.deviceStatus.isBusy || model.voiceState != .idle)
                }
                if let guide {
                    Button("官方说明", systemImage: "arrow.up.right") { NSWorkspace.shared.open(guide.url) }
                }
            }.buttonStyle(.borderless).font(.caption)
            if busy, model.firmwareUpdates.busyID == id {
                HStack { ProgressView().controlSize(.small); Text(model.firmwareUpdates.isInstalling ? "正在更新手柄固件…" : model.firmwareUpdates.preparing ? "正在下载并校验官方固件…" : "正在读取手柄与官方版本…") }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let version = result?.installedVersion {
                Text("更新已完成，设备已读回 \(version)").font(.subheadline.weight(.medium))
            } else if let check = result?.check {
                let title = check.comparison == .current ? "已是本次查询的最新版本" : check.comparison == .available ? "发现新版本" : "设备版本高于官方目录"
                Text(title).font(.subheadline.weight(.medium))
                Text("当前 \(check.installed) · 官方 \(check.latest)").font(.caption).monospacedDigit()
                Text(check.explanation).font(.caption).foregroundStyle(.secondary)
                if check.canPrepare, result?.package == nil {
                    Button("下载并校验固件包") {
                        guard let id, model.voiceState == .idle, !model.isDeviceStatusPreview else { return }
                        model.firmwareUpdates.prepare(id: id)
                    }.disabled(busy || model.deviceStatus.isBusy || model.voiceState != .idle)
                }
                if let package = result?.package {
                    Text(package.explanation).font(.caption).foregroundStyle(.secondary)
                    if package.experimentalInstallation, let id, model.devices.contains(where: { $0.id == id }) {
                        Button("开始实验性升级") { confirmsInstallation = true }
                            .disabled(!model.firmwareInstallationReady || (model.hardwareStatus(for: id)?.battery?.percent ?? 0) < 20)
                        Text(model.config.voice.keepMicWarm ? "升级前请先在语音设置关闭麦克风预热。" : "请保持 USB 连接，电量至少 20%。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("查询时间 \(check.checkedAt.formatted(date: .numeric, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text(guide?.summary ?? "当前设备暂不支持在掌声内直接升级固件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem = result?.problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("确认实验性固件升级", isPresented: $confirmsInstallation) {
            Button("确认升级并保持 USB 连接") { if let id { model.installFirmware(for: id) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将当前手柄从 \(result?.check?.installed ?? "未知") 升至 \(result?.package?.version ?? "未知")。这是实验性固件升级，可能需要数分钟；中断可能导致设备无法正常使用。开始后不要拔线、关机或强制退出。")
        }
    }
}
