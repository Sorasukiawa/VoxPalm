#if os(iOS)
import SwiftUI
import UIKit

struct HoldToTalkButton: UIViewRepresentable {
    let title: String
    let enabled: Bool
    let active: Bool
    let begin: () -> Void
    let release: () -> Void
    let cancel: () -> Void
    func makeUIView(context: Context) -> HoldControl { HoldControl() }
    func updateUIView(_ view: HoldControl, context: Context) {
        view.label.text = title; view.accessibilityLabel = title
        view.isEnabled = enabled; view.alpha = enabled ? 1 : 0.45
        view.begin = begin; view.release = release; view.cancel = cancel
        if !active { view.resetInteraction() }
    }
    static func dismantleUIView(_ view: HoldControl, coordinator: ()) { view.abort() }
}

final class HoldControl: UIControl {
    let label = UILabel()
    var begin: (() -> Void)?
    var release: (() -> Void)?
    var cancel: (() -> Void)?
    private var held = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.9, green: 0.31, blue: 0.28, alpha: 1)
        layer.cornerRadius = 24
        label.textAlignment = .center; label.font = .preferredFont(forTextStyle: .title2)
        label.textColor = .white; label.numberOfLines = 0; label.isUserInteractionEnabled = false
        addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                                     label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                                     label.centerYAnchor.constraint(equalTo: centerYAnchor)])
        isAccessibilityElement = true; accessibilityTraits = .button
        accessibilityHint = "双击开始录音，再次双击结束。也可使用取消按钮。"
        addTarget(self, action: #selector(down), for: .touchDown)
        addTarget(self, action: #selector(up), for: .touchUpInside)
        addTarget(self, action: #selector(abort), for: [.touchUpOutside, .touchCancel, .touchDragExit])
    }
    required init?(coder: NSCoder) { nil }
    @objc private func down() { guard !held else { return }; held = true; begin?() }
    @objc private func up() { guard held else { return }; held = false; release?() }
    @objc func abort() { guard held else { return }; held = false; cancel?() }
    func resetInteraction() { held = false }
    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        if held { up() } else { down() }; return true
    }
}
#endif
