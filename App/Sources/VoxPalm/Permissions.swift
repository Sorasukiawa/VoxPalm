import AppKit
import AVFoundation
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

    var isGranted: Bool {
        switch self {
        case .inputMonitoring: return HIDAccess.isGranted && SystemEventMonitor.hasListenAccess
        case .accessibility: return KeyPoster.canPost
        case .microphone: return MicrophoneAccess.status == .authorized
        }
    }

    private var settingsURL: URL {
        let anchor: String
        switch self {
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .microphone: anchor = "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// 先让系统弹授权框（第一次时会弹），再打开系统设置对应的页面。
    func request() {
        switch self {
        case .inputMonitoring:
            HIDAccess.request()
            SystemEventMonitor.requestListenAccess()
        case .accessibility:
            KeyPoster.promptForAccessibility()
        case .microphone:
            if MicrophoneAccess.status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                return
            }
        }
        NSWorkspace.shared.open(settingsURL)
    }
}
