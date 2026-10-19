import AppKit
import SwiftUI
import VoxPalmVoice

@main
struct VoxPalmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(model)
        } label: {
            MenuBarLabel(state: model.voiceState)
        }
        .menuBarExtraStyle(.window)

        Window("掌声设置", id: "settings") {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)
    }
}

/// 退出前等控制设备收尾：接管了设备按键的来源要先让设备恢复普通按键。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { DiagramPreview.renderIfRequested() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.engine.shutdown {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// 菜单栏图标：平时是品牌图标（模板图，自动适配深浅色），说话时换成声波，转写时换成省略号。
struct MenuBarLabel: View {
    let state: VoiceSession.State

    var body: some View {
        switch state {
        case .listening, .armed:
            Image(systemName: "waveform.circle.fill")
        case .transcribing:
            Image(systemName: "ellipsis.circle")
        case .idle:
            if let image = Self.brandIcon {
                Image(nsImage: image)
            } else {
                Image(systemName: "record.circle")
            }
        }
    }

    static let brandIcon: NSImage? = {
        guard let image = NSImage(named: "MenuBarIconTemplate") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
