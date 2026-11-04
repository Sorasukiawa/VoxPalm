import Combine

/// 取消、下滑关闭与识别结果共用一次性闸门，关闭动画不能延长本次扫描的权限。
@MainActor final class ScanLifetime: ObservableObject {
    private(set) var active = true
    var stopCamera: (() -> Void)?
    @discardableResult func finish(_ completion: () -> Void) -> Bool {
        guard active else { return false }
        active = false
        let stop = stopCamera; stopCamera = nil; stop?()
        completion(); return true
    }
    func cancel() { finish({}) }
}
