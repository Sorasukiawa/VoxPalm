import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import VoxPalmLinkNetwork

@MainActor final class PhoneLinkStore: ObservableObject {
    let host: HostPairingModel?
    let problem: String?
    let preview: Bool
    init(preview: Bool) {
        self.preview = preview
        if preview { host = nil; problem = nil; return }
        do {
            let url = AppConfig.fileURL.deletingLastPathComponent().appendingPathComponent("phone-devices.json")
            host = HostPairingModel(store: try LinkDeviceStore(url: url, credentials: KeychainLinkCredentialStore()))
            problem = nil
        } catch { host = nil; problem = "手机设备记录无法读取，原文件未改动。请先备份记录并排查文件访问权限。" }
    }
}

struct PhonePairingPane: View {
    @ObservedObject var store: PhoneLinkStore
    var body: some View {
        PaneScaffold(title: "手机", subtitle: "让同一网络里的手机与这台 Mac 安全连接。") {
            if let host = store.host { PhonePairingContent(model: host) }
            else if let problem = store.problem { Text(problem).foregroundStyle(.orange) }
            else {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("连接你的手机", systemImage: "iphone.and.arrow.forward").font(.headline)
                        Text("在手机上打开掌声，扫描这里生成的二维码。也可以使用一次性长配对码。")
                        Toggle("接收手机连接", isOn: .constant(false)).disabled(true)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                Hint("界面预览不会生成真实配对码或开启连接。")
            }
        }
    }
}

private struct PhonePairingContent: View {
    @ObservedObject var model: HostPairingModel
    @State private var showCode = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("接收手机连接", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                    Text(model.message).font(.callout).foregroundStyle(.secondary)
                    if model.code == nil {
                        Button("配对新手机", systemImage: "qrcode") { showCode = false; model.beginPairing() }
                            .disabled(!model.enabled)
                    }
                    if let code = model.code {
                        HStack(alignment: .top, spacing: 20) {
                            PairingQRCode(code: code)
                            VStack(alignment: .leading, spacing: 12) {
                                Text("用手机里的掌声扫码").font(.headline)
                                Text("二维码只用于本次配对，请勿分享。")
                                if let expires = model.expiresAt {
                                    HStack { Text("有效期剩余"); Text(expires, style: .timer).monospacedDigit() }
                                }
                                Button(showCode ? "收起长码" : "改用一次性长码") { showCode.toggle() }
                                Button("取消配对") { model.cancelPairing(); showCode = false }
                            }.font(.callout)
                        }
                        if showCode {
                            Text(code).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .lineLimit(8).privacySensitive()
                            Text("选择并复制这段长码，到手机粘贴；五分钟后自动失效。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("已配对与待清理的设备") {
                VStack(alignment: .leading, spacing: 12) {
                    if model.devices.isEmpty { Text("还没有配对的手机。").foregroundStyle(.secondary) }
                    ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                        HStack {
                            Image(systemName: "iphone")
                            VStack(alignment: .leading) {
                                Text("手机 \(index + 1)")
                                Text(device.state == .paired ? (model.states[device.id] ?? "未连接") : "配对未完成或撤销待重试")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(device.state == .paired ? "撤销配对" : "重试清理", role: .destructive) { model.revoke(device.id) }
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("收到连接测试：\(model.testCount) 次").font(.callout).monospacedDigit()
            Hint("当前可验证配对与消息连接。手机收音、触控板与系统按键尚未接入。每次打开掌声，手机连接默认关闭。")
        }
        .onDisappear { model.cancelPairing() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in model.cancelPairing() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in model.setEnabled(false) }
    }
}

private struct PairingQRCode: View {
    let code: String
    private var image: CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 5, y: 5))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit() }
            else { Text("二维码暂时不可用，请使用长码。") }
        }
        .frame(width: 232, height: 232).padding(16).background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("一次性配对二维码").privacySensitive()
    }
}
