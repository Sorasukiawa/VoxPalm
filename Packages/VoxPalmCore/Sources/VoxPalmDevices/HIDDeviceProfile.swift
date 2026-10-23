import Foundation

/// 已有公开输入协议的设备。只按明确的厂商/产品编号识别，不把其他 Apple 或 Sony 设备当成遥控器/手柄。
public enum HIDDeviceProfile: String, Codable, Sendable {
    case siriRemote1, siriRemote2, siriRemote3, dualSense, dualSenseEdge

    public static func identify(vendor: Int?, product: Int?) -> Self? {
        switch (vendor, product) {
        case (0x004C, 0x0266), (0x004C, 0x026D): return .siriRemote1
        case (0x004C, 0x0314): return .siriRemote2
        case (0x004C, 0x0315): return .siriRemote3
        case (0x054C, 0x0CE6): return .dualSense
        case (0x054C, 0x0DF2): return .dualSenseEdge
        default: return nil
        }
    }

    public var isGamepad: Bool { self == .dualSense || self == .dualSenseEdge }

    public var name: String {
        switch self {
        case .siriRemote1: return "Siri Remote（第一代）"
        case .siriRemote2: return "Siri Remote（第二代）"
        case .siriRemote3: return "Siri Remote（第三代）"
        case .dualSense: return "DualSense（DS5）"
        case .dualSenseEdge: return "DualSense Edge（DSE）"
        }
    }
}

public extension HIDDeviceInfo {
    var profile: HIDDeviceProfile? { HIDDeviceProfile.identify(vendor: vendorID, product: productID) }

    /// 新适配的设备按硬件身份区分；普通 HID 沿用旧配置中的编号。
    var controlKey: String {
        guard profile != nil else { return physicalKey }
        return "\(vendorProduct)|\(instanceToken ?? "registry-\(id)")|\(transport ?? "")"
    }
}
