#if os(iOS)
import SwiftUI
import VoxPalmLinkNetwork

@MainActor public struct MobilePairingView: View {
    @ObservedObject private var model: ClientPairingModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var scanning = false
    @State private var manual = false
    @State private var code = ""
    public init(model: ClientPairingModel) { self.model = model }
    public var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 40)).foregroundStyle(.tint)
                        Text("连接你的 Mac").font(.title2.bold())
                        Text(model.message).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                    Button { scanning = true } label: { Label("扫描 Mac 上的二维码", systemImage: "qrcode.viewfinder") }
                        .disabled(model.busy || model.connectedID != nil)
                    Button("使用一次性长码") { manual = true }
                        .disabled(model.busy || model.connectedID != nil)
                    if model.busy { ProgressView(); Button("取消") { model.stop() } }
                }
                Section("我的 Mac") {
                    if model.devices.isEmpty { Text("还没有配对的 Mac").foregroundStyle(.secondary) }
                    ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Mac \(index + 1)", systemImage: "laptopcomputer")
                            if device.state == .paired {
                                if model.connectedID == device.id {
                                    Text("已连接").foregroundStyle(.green)
                                    Button("发送连接测试") { model.sendTest() }.buttonStyle(.borderedProminent)
                                    Text("在 Mac「手机」页查看次数。此按钮不会录音或操作其他 App。")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button("断开连接") { model.stop() }
                                } else { Button("连接") { model.connect(device.id) }.disabled(model.busy) }
                            } else { Text("上次配对未完成或仍需清理").font(.caption).foregroundStyle(.secondary) }
                            Button(device.state == .paired ? "移除配对" : "重试清理", role: .destructive) { model.revoke(device.id) }
                        }.padding(.vertical, 6)
                    }
                }
                Section {
                    Text("两端需要在同一网络。若连接失败，请在系统设置中允许掌声访问本地网络；Mac 也要打开「接收手机连接」。")
                    Text("本版先提供配对和连接测试；按住说话与触控板正在开发。离开前台会断开连接，回来后请手动连接。")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("掌声")
            .sheet(isPresented: $scanning) {
                ScannerSheet { result in
                    scanning = false
                    if let result { model.pair(code: result) }
                }
            }
            .sheet(isPresented: $manual, onDismiss: { code = "" }) {
                NavigationStack {
                    Form {
                        Section("粘贴 Mac 显示的完整长码") {
                            TextEditor(text: $code).frame(minHeight: 160).font(.system(.caption, design: .monospaced))
                                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                                .onChange(of: code) { value in
                                    if value.utf8.count > 2048 { code = String(value.prefix(2048)) }
                                }
                            Text("一次性长码五分钟有效，请勿分享。").font(.footnote)
                        }
                        Button("开始配对") { let submitted = code; code = ""; manual = false; model.pair(code: submitted) }
                            .disabled(code.isEmpty)
                    }
                    .navigationTitle("长码配对").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { manual = false; code = "" } } }
                }
            }
        }
        .tint(Color(red: 0.9, green: 0.31, blue: 0.28))
        .onChange(of: scenePhase) { phase in
            if phase != .active { model.stop() }
            if phase == .background { scanning = false; manual = false; code = "" }
        }
    }
}

#if DEBUG
/// 本地界面检查入口：只读空的临时目录，不实例化钥匙串，不开启网络或相机。
public struct MobilePairingPreview: View {
    public init() {}
    public var body: some View {
        if let store = try? LinkDeviceStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                            credentials: PreviewCredentials()) {
            MobilePairingView(model: ClientPairingModel(store: store)).disabled(true)
        } else { Text("预览初始化失败") }
    }
}
@MainActor private final class PreviewCredentials: LinkCredentialStore {
    func save(_ credential: LinkCredential) throws { throw SecureLinkError.storage }
    func load(id: UUID) throws -> LinkCredential? { nil }
    func remove(id: UUID) throws { throw SecureLinkError.storage }
}
#endif
#endif
