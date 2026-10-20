import Foundation
import VoxPalmDevices

/// 录音实际用哪支麦。控制设备接管按键时，有的麦会被它静音（比如有的无线麦，收按键的控制通道一开，它自己的麦就没声音）：
/// 选的就是这支、或者跟随系统默认而默认输入正好是它，就换一支——先用 Mac 自带的麦，没有再找别的能用的麦。
public enum MicRouting {
    public struct Route: Equatable, Sendable {
        /// 这次录音用的麦；nil = 交给系统默认输入（没有要避开的麦时，跟随系统默认就是 nil）
        public var device: AudioDeviceInfo?
        /// 本来要用、但会被静音所以避开了的那支
        public var avoided: AudioDeviceInfo?

        public init(device: AudioDeviceInfo?, avoided: AudioDeviceInfo?) {
            self.device = device
            self.avoided = avoided
        }
    }

    /// - Parameters:
    ///   - selectedUID: 选的收音设备；nil = 跟随系统默认输入
    ///   - inputs: 现在连着的收音设备
    ///   - muted: 会被控制设备静音的收音设备 UID
    public static func resolve(selectedUID: String?, inputs: [AudioDeviceInfo], muted: Set<String>) -> Route {
        let selected = selectedUID.flatMap { uid in inputs.first { $0.uid == uid } }
        // 选的麦没连上时，录音会落到系统默认输入上，一样要看它会不会被静音
        guard let intended = selected ?? inputs.first(where: \.isDefaultInput), muted.contains(intended.uid) else {
            return Route(device: selected, avoided: nil)
        }
        let usable = inputs.filter { !muted.contains($0.uid) && $0.transport != "Virtual" && $0.transport != "Aggregate" }
        let fallback = usable.first { $0.transport == "Built-in" } ?? usable.first(where: \.isDefaultInput) ?? usable.first
        return Route(device: fallback, avoided: intended)
    }
}
