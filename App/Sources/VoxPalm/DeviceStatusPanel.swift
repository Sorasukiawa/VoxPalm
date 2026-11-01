import AppKit
import SwiftUI
import VoxPalmDevices

struct DeviceStatusPanel: View {
    @Environment(AppModel.self) private var model
    let id: String?
    let name: String
    private var value: DeviceHardwareStatus? { id.flatMap { model.hardwareStatus(for: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("设备状态", systemImage: "info.circle").font(.headline)
                Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.deviceStatus.isRefreshing { ProgressView().controlSize(.small) }
                Button("刷新", systemImage: "arrow.clockwise") { model.refreshHardwareStatus(deviceID: id, force: true) }
                    .buttonStyle(.borderless).disabled(id == nil || model.deviceStatus.isBusy || model.firmwareUpdates.busyID != nil || model.voiceState != .idle)
            }
            if let value {
                HStack(alignment: .top, spacing: 14) {
                    field("电量", value.battery?.title ?? "未提供", detail: value.battery?.detail ?? "设备没有提供可用电量", symbol: batterySymbol(value.battery))
                    field("信号", value.signalTitle, detail: value.signalDetail, symbol: "antenna.radiowaves.left.and.right")
                    field("固件", value.firmware ?? "未提供", detail: value.firmwareNote ?? "未读取到设备固件版本", symbol: "cpu")
                }
                Divider()
                DeviceFirmwarePanel(id: id, guide: value.updateGuide)
                if let problem = value.problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
                if let at = value.observedAt {
                    Text("最近读取 \(at.formatted(date: .omitted, time: .standard)) · \(value.transport)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                Text(id.map { model.hardwareDeviceConnected($0) ? "等待读取设备信息…" : "设备未连接，重连后显示状态。" } ?? "选一台已连接的设备查看状态。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let problem = model.deviceStatus.problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
            if model.voiceState != .idle { Text("说话结束后可以刷新设备信息。").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        .task(id: id) {
            model.deviceStatusPageSelection = id
            model.refreshHardwareStatus(deviceID: id, force: true)
        }
        .onDisappear { model.deviceStatusPageSelection = nil }
    }

    private func field(_ title: String, _ text: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

func batterySymbol(_ battery: DeviceBattery?) -> String {
    if battery?.state == .charging { return "battery.100percent.bolt" }
    switch battery?.percent ?? 0 {
    case 75...: return "battery.100percent"
    case 45...: return "battery.50percent"
    case 15...: return "battery.25percent"
    default: return "battery.0percent"
    }
}

struct DeviceBatteryBadge: View {
    let battery: DeviceBattery
    var body: some View {
        Label(battery.title, systemImage: batterySymbol(battery))
            .font(.system(size: 10, weight: .medium)).monospacedDigit()
            .foregroundStyle(battery.state == .error || (battery.percent ?? 100) <= 15 ? Color.orange : .secondary)
            .accessibilityLabel("电量 \(battery.title)，\(battery.detail)")
    }
}
