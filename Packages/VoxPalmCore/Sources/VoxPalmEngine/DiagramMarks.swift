import CoreGraphics
import Foundation

/// 示意图上印的品牌标志图形。开源仓库不带任何厂商的标志：没登记时示意图照旧用普通字体印品牌名；
/// 官方版由私有包在启动时登记真的标志图形（第三方标志不放进 GPL 仓库）。
public struct MarkShape: Sendable {
    public let width: Double
    public let height: Double
    /// 只用绝对坐标的 M / L / C / Z 命令，坐标范围 0…width、0…height
    public let paths: [String]

    public init(width: Double, height: Double, paths: [String]) {
        self.width = width
        self.height = height
        self.paths = paths
    }

    /// 缩放到 `rect` 里、保持比例、居中。
    public func path(in rect: CGRect) -> CGPath {
        let scale = min(rect.width / width, rect.height / height)
        let dx = rect.midX - width * scale / 2
        let dy = rect.midY - height * scale / 2
        let result = CGMutablePath()
        for d in paths {
            let numbers = d.split(separator: " ")
            var index = 0
            func point() -> CGPoint {
                let x = Double(numbers[index]) ?? 0
                let y = Double(numbers[index + 1]) ?? 0
                index += 2
                return CGPoint(x: dx + x * scale, y: dy + y * scale)
            }
            while index < numbers.count {
                let command = numbers[index]
                index += 1
                switch command {
                case "M": result.move(to: point())
                case "L": result.addLine(to: point())
                case "C":
                    let c1 = point(), c2 = point(), end = point()
                    result.addCurve(to: end, control1: c1, control2: c2)
                case "Z": result.closeSubpath()
                default: break
                }
            }
        }
        return result
    }
}

public enum DiagramMarks {
    nonisolated(unsafe) private static var shapes: [String: MarkShape] = [:]

    /// 登记一个品牌标志，`name` 和示意图里印字部件的文字一致（比如 "dji"、"xiaomi"）。启动时在主线程调。
    public static func register(_ name: String, _ shape: MarkShape) {
        shapes[name] = shape
    }

    public static func shape(_ name: String) -> MarkShape? { shapes[name] }
}
