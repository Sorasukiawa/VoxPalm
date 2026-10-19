import Foundation

/// 导出报告前去掉能定位到具体某台设备的信息：蓝牙地址只留前 3 段（厂商段），序列号不导出。
public enum Redaction {
    private static let macPattern = try! NSRegularExpression(
        pattern: "([0-9A-Fa-f]{2})([-:])([0-9A-Fa-f]{2})\\2([0-9A-Fa-f]{2})\\2[0-9A-Fa-f]{2}\\2[0-9A-Fa-f]{2}\\2[0-9A-Fa-f]{2}"
    )

    public static func maskBluetoothAddresses(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return macPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "$1$2$3$2$4$2xx$2xx$2xx")
    }
}
