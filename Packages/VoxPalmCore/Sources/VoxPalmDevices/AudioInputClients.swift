import AppKit
import CoreAudio
import Foundation

/// 正开着某个收音设备的程序（CoreAudio 的进程对象，macOS 14 起有）。
public struct AudioInputClient: Hashable, Sendable {
    public let pid: pid_t
    public let bundleID: String?
    /// 给人看的名字：App 名；系统设置的面板写成「系统设置 › 声音」
    public let name: String
}

public extension AudioDevices {
    /// 正在从这个设备收音的其他程序（不含掌声自己）。系统设置的「声音」页开着时也算：它一直在量输入音量。
    static func inputClients(of deviceID: AudioObjectID) -> [AudioInputClient] {
        let me = ProcessInfo.processInfo.processIdentifier
        let processes = CoreAudioProperty.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        return processes.compactMap { process in
            let pid: pid_t = CoreAudioProperty.value(process, kAudioProcessPropertyPID, default: pid_t(0))
            guard pid > 0, pid != me else { return nil }
            let devices = CoreAudioProperty.array(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput, of: AudioObjectID.self)
            guard devices.contains(deviceID) else { return nil }
            let bundleID = CoreAudioProperty.string(process, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
            var buffer = [CChar](repeating: 0, count: 4096)
            let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
            let name = clientName(path: path, appName: NSRunningApplication(processIdentifier: pid)?.localizedName, bundleID: bundleID, pid: pid)
            return AudioInputClient(pid: pid, bundleID: bundleID, name: name)
        }
    }

    /// 系统设置面板的中文名（扩展本身的名字是英文的）
    private static let settingsPanes = ["Sound": "声音", "Bluetooth": "蓝牙", "Privacy": "隐私与安全性"]

    /// - Parameters:
    ///   - path: 程序文件的路径
    ///   - appName: 系统认得的 App 名（NSRunningApplication），辅助程序、扩展通常没有
    internal static func clientName(path: String, appName: String?, bundleID: String?, pid: pid_t) -> String {
        // 系统设置的面板是单独的扩展进程（例如 /System/Library/ExtensionKit/Extensions/Sound.appex）
        let extensions = "/System/Library/ExtensionKit/Extensions/"
        if path.hasPrefix(extensions), let appex = path.dropFirst(extensions.count).split(separator: "/").first {
            let pane = appex.replacingOccurrences(of: ".appex", with: "")
            return "系统设置 › \(settingsPanes[pane] ?? pane)"
        }
        if let appName, !appName.isEmpty { return appName }
        // App 里带的辅助程序、扩展：用最外层 App 的名字
        if let range = path.range(of: ".app/") {
            let appPath = String(path[..<range.lowerBound]) + ".app"
            return URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        }
        if !path.isEmpty { return URL(fileURLWithPath: path).lastPathComponent }
        return bundleID ?? "进程 \(pid)"
    }
}
