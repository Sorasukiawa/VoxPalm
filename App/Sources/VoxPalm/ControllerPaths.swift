import SwiftUI
import VoxPalmEngine

/// 依据产品正视图独立绘制的轮廓；正面和背面复用外壳，内侧面板分别描画。
enum ControllerPaths {
    static func path(_ shape: DeviceDiagram.Shape, in rect: CGRect, mirrored: Bool = false) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (mirrored ? 1 - x : x) * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        switch shape {
        case .gamepad:
            path.move(to: p(0.105, 0.06))
            path.addCurve(to: p(0.895, 0.06), control1: p(0.29, -0.018), control2: p(0.71, -0.018))
            path.addCurve(to: p(0.985, 0.78), control1: p(0.95, 0.22), control2: p(1.012, 0.58))
            path.addCurve(to: p(0.86, 0.96), control1: p(0.952, 1.025), control2: p(0.882, 1.0135))
            path.addLine(to: p(0.772, 0.746))
            path.addCurve(to: p(0.70, 0.655), control1: p(0.755, 0.68), control2: p(0.74, 0.65))
            path.addLine(to: p(0.30, 0.655))
            path.addCurve(to: p(0.228, 0.746), control1: p(0.26, 0.65), control2: p(0.245, 0.68))
            path.addLine(to: p(0.14, 0.96))
            path.addCurve(to: p(0.015, 0.78), control1: p(0.118, 1.0135), control2: p(0.048, 1.025))
            path.addCurve(to: p(0.105, 0.06), control1: p(-0.012, 0.58), control2: p(0.05, 0.22))
        case .gamepadPanel:
            // 曲面沿摇杆外侧收进握把，末端是一小段圆面，不收成尖三角。
            path.move(to: p(0.30, 0.01))
            path.addLine(to: p(0.70, 0.01))
            path.addCurve(to: p(0.694, 0.31), control1: p(0.695, 0.14), control2: p(0.68, 0.23))
            path.addCurve(to: p(0.75, 0.39), control1: p(0.69, 0.35), control2: p(0.73, 0.37))
            path.addCurve(to: p(0.803, 0.49), control1: p(0.775, 0.42), control2: p(0.79, 0.46))
            path.addCurve(to: p(0.852, 0.63), control1: p(0.82, 0.53), control2: p(0.835, 0.58))
            path.addCurve(to: p(0.905, 0.98), control1: p(0.885, 0.73), control2: p(0.91, 0.967))
            path.addCurve(to: p(0.86, 0.96), control1: p(0.90, 0.993), control2: p(0.873, 0.992))
            path.addLine(to: p(0.772, 0.746))
            path.addCurve(to: p(0.70, 0.655), control1: p(0.755, 0.68), control2: p(0.74, 0.65))
            path.addLine(to: p(0.30, 0.655))
            path.addCurve(to: p(0.228, 0.746), control1: p(0.26, 0.65), control2: p(0.245, 0.68))
            path.addLine(to: p(0.14, 0.96))
            path.addCurve(to: p(0.095, 0.98), control1: p(0.127, 0.992), control2: p(0.10, 0.993))
            path.addCurve(to: p(0.148, 0.63), control1: p(0.09, 0.967), control2: p(0.115, 0.73))
            path.addCurve(to: p(0.197, 0.49), control1: p(0.165, 0.58), control2: p(0.18, 0.53))
            path.addCurve(to: p(0.25, 0.39), control1: p(0.21, 0.46), control2: p(0.225, 0.42))
            path.addCurve(to: p(0.306, 0.31), control1: p(0.27, 0.37), control2: p(0.31, 0.35))
            path.addCurve(to: p(0.30, 0.01), control1: p(0.32, 0.23), control2: p(0.305, 0.14))
        case .gamepadRearPanel:
            path.move(to: p(0.26, 0.26))
            path.addCurve(to: p(0.74, 0.26), control1: p(0.36, 0.21), control2: p(0.64, 0.21))
            path.addCurve(to: p(0.82, 0.50), control1: p(0.79, 0.28), control2: p(0.80, 0.37))
            path.addCurve(to: p(0.905, 0.98), control1: p(0.86, 0.67), control2: p(0.91, 0.967))
            path.addCurve(to: p(0.86, 0.96), control1: p(0.90, 0.993), control2: p(0.873, 0.992))
            path.addLine(to: p(0.772, 0.746))
            path.addCurve(to: p(0.70, 0.655), control1: p(0.755, 0.68), control2: p(0.74, 0.65))
            path.addLine(to: p(0.30, 0.655))
            path.addCurve(to: p(0.228, 0.746), control1: p(0.26, 0.65), control2: p(0.245, 0.68))
            path.addLine(to: p(0.14, 0.96))
            path.addCurve(to: p(0.095, 0.98), control1: p(0.127, 0.992), control2: p(0.10, 0.993))
            path.addCurve(to: p(0.18, 0.50), control1: p(0.09, 0.967), control2: p(0.14, 0.67))
            path.addCurve(to: p(0.26, 0.26), control1: p(0.20, 0.37), control2: p(0.21, 0.28))
        case .touchpad:
            path.move(to: p(0.06, 0))
            path.addCurve(to: p(0.94, 0), control1: p(0.28, -0.025), control2: p(0.72, -0.025))
            path.addQuadCurve(to: p(0.995, 0.08), control: p(1.01, 0))
            path.addLine(to: p(0.91, 0.80))
            path.addQuadCurve(to: p(0.75, 1), control: p(0.89, 1))
            path.addLine(to: p(0.25, 1))
            path.addQuadCurve(to: p(0.09, 0.80), control: p(0.11, 1))
            path.addLine(to: p(0.005, 0.08))
            path.addQuadCurve(to: p(0.06, 0), control: p(-0.01, 0))
        case .functionKey:
            path.move(to: p(0, 0)); path.addLine(to: p(1, 0))
            path.addLine(to: p(0.84, 0.86)); path.addQuadCurve(to: p(0.16, 0.86), control: p(0.5, 1.1))
        case .backPaddle:
            path.move(to: p(0.70, 0.04))
            path.addCurve(to: p(0.95, 0.84), control1: p(1.08, 0.12), control2: p(1.0, 0.54))
            path.addCurve(to: p(0.08, 0.38), control1: p(0.85, 1.17), control2: p(-0.16, 0.62))
            path.addQuadCurve(to: p(0.70, 0.04), control: p(0.23, 0.07))
        case let .directional(direction):
            func rotated(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                switch direction {
                case 1: return p(1 - y, x)
                case 2: return p(1 - x, 1 - y)
                case 3: return p(y, 1 - x)
                default: return p(x, y)
                }
            }
            path.move(to: rotated(0.20, 0))
            path.addLine(to: rotated(0.80, 0))
            path.addQuadCurve(to: rotated(1, 0.18), control: rotated(1, 0))
            path.addLine(to: rotated(1, 0.65)); path.addLine(to: rotated(0.5, 1))
            path.addLine(to: rotated(0, 0.65)); path.addLine(to: rotated(0, 0.18))
            path.addQuadCurve(to: rotated(0.20, 0), control: rotated(0, 0))
        default: return Path()
        }
        path.closeSubpath()
        return path
    }
}
