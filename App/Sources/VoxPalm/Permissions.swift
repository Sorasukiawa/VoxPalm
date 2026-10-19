import AppKit
import AVFoundation
import SwiftUI
import VoxPalmDevices
import VoxPalmEngine

/// 掌声要的三个系统权限。都只能用户自己在系统设置里打开。
enum Permission: String, CaseIterable, Identifiable {
    case inputMonitoring
    case accessibility
    case microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inputMonitoring: return "输入监控"
        case .accessibility: return "辅助功能"
        case .microphone: return "麦克风"
        }
    }

    var purpose: String {
        switch self {
        case .inputMonitoring: return "读遥控器、翻页笔的按键和系统媒体键"
        case .accessibility: return "模拟快捷键、把文字贴到光标处、拦下映射过的键"
        case .microphone: return "内置转写时录音（只在本机处理）"
        }
    }

    /// 缺这个权限会怎样（面板提示条用）
    var consequence: String {
        switch self {
        case .inputMonitoring: return "没有它，读不到遥控器的按键。"
        case .accessibility: return "没有它，字贴不到光标处。"
        case .microphone: return "没有它，内置转写录不到声音。"
        }
    }

    var symbol: String {
        switch self {
        case .inputMonitoring: return "keyboard"
        case .accessibility: return "accessibility"
        case .microphone: return "mic.fill"
        }
    }

    var tileColor: Color {
        switch self {
        case .inputMonitoring: return .tileIndigo
        case .accessibility: return .tileBlue
        case .microphone: return .tileOrange
        }
    }

    /// 系统设置里这一页的列表能不能把 App 拖进去（麦克风只能由系统弹框加进列表）。
    var supportsDrag: Bool { self != .microphone }

    var isGranted: Bool {
        switch self {
        case .inputMonitoring: return HIDAccess.isGranted && SystemEventMonitor.hasListenAccess
        case .accessibility: return KeyPoster.canPost
        case .microphone: return MicrophoneAccess.status == .authorized
        }
    }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .microphone: anchor = "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// 打开权限。打包好的 App：打开系统设置对应的页面，旁边浮出可以拖进列表的掌声图标（见 `PermissionGuide`）。
    /// 麦克风没问过时直接弹系统授权框。直接跑可执行文件（不在 App 包里）时拖不了，退回系统授权框。
    @MainActor
    func request() {
        switch self {
        case .microphone where MicrophoneAccess.status == .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { AppModel.shared.refreshPermissions() }
            }
            return
        case .inputMonitoring where !Self.isAppBundle:
            HIDAccess.request()
            SystemEventMonitor.requestListenAccess()
        case .accessibility where !Self.isAppBundle:
            KeyPoster.promptForAccessibility()
        default:
            break
        }
        PermissionGuide.shared.start(self)
    }

    private static var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }
}
