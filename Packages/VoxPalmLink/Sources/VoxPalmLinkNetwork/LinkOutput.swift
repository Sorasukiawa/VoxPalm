import Foundation
import VoxPalmLink

/// 只跟踪已经交给调用方的按住状态；协议状态可能已处理完整批次，不能替代实际投递状态。
@MainActor final class LinkOutput {
    private var active = true
    private var buttons: Set<String> = []
    private var pointer: Set<PointerButton> = []
    private var audio: UUID?
    let onMessage: (LinkMessage) -> Void
    let onClose: () -> Void
    init(onMessage: @escaping (LinkMessage) -> Void, onClose: @escaping () -> Void) {
        self.onMessage = onMessage; self.onClose = onClose
    }
    func apply(_ effects: [LinkEffect]) {
        for effect in effects {
            guard active else { return }
            switch effect {
            case let .deliver(message):
                switch message {
                case let .button(button):
                    if button.phase == .down { buttons.insert(button.id) }
                    else if buttons.remove(button.id) == nil { continue }
                case let .pointer(.button(button, phase)):
                    if phase == .down { pointer.insert(button) }
                    else if pointer.remove(button) == nil { continue }
                case let .audioStart(id, _): audio = id
                case let .audioEnd(id, _), let .audioCancel(id):
                    guard audio == id else { continue }; audio = nil
                default: break
                }
                onMessage(message)
            case .closeTransport: cancel(); onClose()
            }
        }
    }
    func cancel() {
        guard active else { return }; active = false
        var messages = buttons.sorted().map { LinkMessage.button(RemoteButton(id: $0, phase: .cancel)) }
        messages += pointer.sorted { $0.rawValue < $1.rawValue }.map { .pointer(.button($0, .cancel)) }
        if let audio { messages.append(.audioCancel(id: audio)) }
        buttons.removeAll(); pointer.removeAll(); audio = nil
        for message in messages { onMessage(message) }
    }
}
