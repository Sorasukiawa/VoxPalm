import Foundation
import CryptoKit

/// 导出报告和设置前去掉能定位到具体某台设备的信息：蓝牙地址只留前 3 段（厂商段），序列号不导出。
public enum Redaction {
    private static let macPattern = try! NSRegularExpression(
        pattern: "([0-9A-Fa-f]{2})([-:])([0-9A-Fa-f]{2})\\2([0-9A-Fa-f]{2})\\2[0-9A-Fa-f]{2}\\2[0-9A-Fa-f]{2}\\2[0-9A-Fa-f]{2}"
    )
    private static let digestPattern = try! NSRegularExpression(pattern: "^(?:[0-9a-f]{64}|registry-[0-9]+)$")

    public static func maskBluetoothAddresses(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return macPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "$1$2$3$2$4$2xx$2xx$2xx")
    }

    /// `instanceToken` 是不加盐的摘要，蓝牙设备的序列号又常是蓝牙地址，知道厂商段就能穷举还原。
    /// 分享出去的报告用一次性密钥重算：同一份报告里同一台设备的几个接口仍对得上，不同报告之间对不上。
    public static func anonymizeInstanceTokens(_ devices: [HIDDeviceInfo], key: SymmetricKey = SymmetricKey(size: .bits256)) -> [HIDDeviceInfo] {
        devices.map { device in
            var copy = device
            copy.instanceToken = device.instanceToken.map { token in
                HMAC<SHA256>.authenticationCode(for: Data(token.utf8), using: key).prefix(8).map { String(format: "%02x", $0) }.joined()
            }
            return copy
        }
    }

    /// 设备标识里身份部分换成的占位。
    public static let identityPlaceholder = "<redacted>"

    /// 设置里的设备标识去掉身份：完整蓝牙地址、已适配 HID 设备的序列号摘要或连接编号、
    /// USB 声卡 UID 里的序列号（没有序列号时是端口位置）换成占位，型号和连接方式留着，导入后靠 `identity(_:matches:)` 认回同型号设备。
    public static func maskDeviceIdentity(_ id: String) -> String {
        var segments = id.split(separator: "|", omittingEmptySubsequences: false).map { segment -> String in
            let text = String(segment)
            let range = NSRange(text.startIndex..., in: text)
            return digestPattern.firstMatch(in: text, range: range) == nil ? text : identityPlaceholder
        }
        // USB 声卡的 UID：AppleUSBAudioEngine:厂商:型号:序列号或位置:接口
        if segments.count == 1, id.hasPrefix("AppleUSBAudioEngine:") {
            var parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 5 {
                parts[parts.count - 2] = identityPlaceholder
                segments = [parts.joined(separator: ":")]
            }
        }
        let joined = segments.joined(separator: "|")
        let range = NSRange(joined.startIndex..., in: joined)
        return macPattern.stringByReplacingMatches(in: joined, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: identityPlaceholder))
    }

    /// 去掉身份的标识能不能对上这台设备：占位处是任意一段不含 `|` 的非空内容，其余部分一字不差。
    public static func identity(_ masked: String, matches id: String) -> Bool {
        let parts = masked.components(separatedBy: identityPlaceholder)
        guard parts.count > 1 else { return masked == id }
        let pattern = "^" + parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[^|]+") + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
    }
}
