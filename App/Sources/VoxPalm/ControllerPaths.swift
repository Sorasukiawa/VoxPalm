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
            path.move(to: p(0.125, 0.07))
            path.addCurve(to: p(0.875, 0.07), control1: p(0.29, -0.02), control2: p(0.71, -0.02))
            path.addCurve(to: p(0.985, 0.85), control1: p(0.94, 0.23), control2: p(1.015, 0.64))
            path.addCurve(to: p(0.855, 0.945), control1: p(0.965, 1.06), control2: p(0.905, 1.06))
            path.addLine(to: p(0.765, 0.715))
            path.addCurve(to: p(0.65, 0.655), control1: p(0.743, 0.658), control2: p(0.705, 0.642))
            path.addLine(to: p(0.35, 0.655))
            path.addCurve(to: p(0.235, 0.715), control1: p(0.295, 0.642), control2: p(0.257, 0.658))
            path.addLine(to: p(0.145, 0.945))
            path.addCurve(to: p(0.015, 0.85), control1: p(0.095, 1.06), control2: p(0.035, 1.06))
            path.addCurve(to: p(0.125, 0.07), control1: p(-0.015, 0.64), control2: p(0.06, 0.23))
        case .gamepadPanel:
            path.move(to: p(0.30, 0.025))
            path.addLine(to: p(0.70, 0.025))
            path.addCurve(to: p(0.72, 0.37), control1: p(0.695, 0.18), control2: p(0.65, 0.29))
            path.addCurve(to: p(0.845, 0.54), control1: p(0.76, 0.41), control2: p(0.80, 0.45))
            path.addLine(to: p(0.87, 0.98))
            path.addCurve(to: p(0.855, 0.945), control1: p(0.865, 0.97), control2: p(0.86, 0.96))
            path.addLine(to: p(0.765, 0.715))
            path.addCurve(to: p(0.65, 0.655), control1: p(0.743, 0.658), control2: p(0.705, 0.642))
            path.addLine(to: p(0.35, 0.655))
            path.addCurve(to: p(0.235, 0.715), control1: p(0.295, 0.642), control2: p(0.257, 0.658))
            path.addLine(to: p(0.145, 0.945))
            path.addCurve(to: p(0.13, 0.98), control1: p(0.14, 0.96), control2: p(0.135, 0.97))
            path.addLine(to: p(0.155, 0.54))
            path.addCurve(to: p(0.28, 0.37), control1: p(0.20, 0.45), control2: p(0.24, 0.41))
            path.addCurve(to: p(0.30, 0.025), control1: p(0.35, 0.29), control2: p(0.305, 0.18))
        case .gamepadRearPanel:
            path.move(to: p(0.26, 0.26))
            path.addCurve(to: p(0.74, 0.26), control1: p(0.36, 0.21), control2: p(0.64, 0.21))
            path.addCurve(to: p(0.94, 0.99), control1: p(0.86, 0.30), control2: p(0.87, 0.73))
            path.addLine(to: p(0.855, 0.945))
            path.addLine(to: p(0.765, 0.715))
            path.addCurve(to: p(0.65, 0.655), control1: p(0.743, 0.658), control2: p(0.705, 0.642))
            path.addLine(to: p(0.35, 0.655))
            path.addCurve(to: p(0.235, 0.715), control1: p(0.295, 0.642), control2: p(0.257, 0.658))
            path.addLine(to: p(0.145, 0.945))
            path.addLine(to: p(0.06, 0.99))
            path.addCurve(to: p(0.26, 0.26), control1: p(0.13, 0.73), control2: p(0.14, 0.30))
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
