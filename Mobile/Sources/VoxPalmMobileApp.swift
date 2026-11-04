import SwiftUI
import VoxPalmLinkNetwork
import VoxPalmLinkUI

@main struct VoxPalmMobileApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-preview") { MobilePairingPreview() }
            else { MobileRoot() }
            #else
            MobileRoot()
            #endif
        }
    }
}

@MainActor private final class MobileStore: ObservableObject {
    let model: ClientPairingModel?
    init() {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: false)
            let store = try LinkDeviceStore(url: directory.appendingPathComponent("phone-devices.json"),
                                            credentials: KeychainLinkCredentialStore())
            model = ClientPairingModel(store: store)
        } catch { model = nil }
    }
}

private struct MobileRoot: View {
    @StateObject private var store = MobileStore()
    var body: some View {
        if let model = store.model { MobilePairingView(model: model) }
        else {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text("设备记录无法读取").font(.headline)
                Text("原文件未改动。请先备份记录并排查存储访问问题，再重新打开掌声。")
            }.padding()
        }
    }
}
