import AppKit
import ApplicationServices

// 出字、按回车之前先看一眼目标。思路来自 MicVibe 原型：只往能打字、不是密码的输入框贴字、按回车；
// 按下说话键那一刻记下目标（前台 App + 焦点所在的输入框），转写完目标变了就不贴，字留在剪贴板里。

/// 没贴字、没按回车的原因。
public enum DeliveryBlock: Equatable, Sendable {
    /// 没有辅助功能权限：读不了输入框，按键也发不出去
    case noPermission
    /// 光标在密码框里
    case secureField
    /// 光标不在能打字的输入框里（或者读不到）
    case notEditable
    /// 按下说话键以后换了 App 或输入框
    case targetChanged
    /// 输入框是空的（只用于回车，免得误发）
    case emptyField

    /// 字没贴、放进剪贴板时的说明（说话浮窗的副标题）
    public var pasteMessage: String {
        switch self {
        case .noPermission: return "缺「辅助功能」权限，贴不到光标处"
        case .secureField: return "光标在密码框里，不往里贴"
        case .notEditable: return "光标不在输入框里"
        case .targetChanged: return "说话时换了窗口或输入框"
        case .emptyField: return "输入框是空的"
        }
    }

    /// 没按回车时的说明
    public var returnMessage: String {
        switch self {
        case .noPermission: return "发送回车要辅助功能权限"
        case .secureField: return "光标在密码框里，没有按回车"
        case .notEditable: return "光标不在输入框里，没有按回车"
        case .targetChanged: return "说话时换了窗口或输入框，没有按回车"
        case .emptyField: return "输入框是空的，没有按回车"
        }
    }
}

/// 焦点所在元素的辅助功能属性。
public struct FieldFacts: Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    /// AXValue 能不能写：一般的输入框能写
    public var valueSettable: Bool
    /// AXProtectedContent：有的 App 这样标密码框
    public var protected: Bool
    /// 输入框里现在的字；没读或读不到为 nil
    public var text: String?

    public init(role: String?, subrole: String? = nil, valueSettable: Bool, protected: Bool = false, text: String? = nil) {
        self.role = role
        self.subrole = subrole
        self.valueSettable = valueSettable
        self.protected = protected
        self.text = text
    }
}

public enum FieldKind: Equatable, Sendable {
    case editable
    case secure
    case notEditable
}

/// 贴字和按回车的规则，全是纯函数，单元测试覆盖。
public enum DeliveryRule {
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// 焦点所在的元素算哪一类；读不到（nil）当成不能打字。
    public static func kind(_ field: FieldFacts?) -> FieldKind {
        guard let field else { return .notEditable }
        if field.protected || field.subrole == "AXSecureTextField" || field.role == "AXSecureTextField" { return .secure }
        guard let role = field.role, textRoles.contains(role) else { return .notEditable }
        // 文字区域的值不可写也算能打字：系统「终端」的输入区就是这样（2026-10-19 本机读到），命令行里的 Claude Code、Codex 都在这里面。
        return field.valueSettable || role == "AXTextArea" ? .editable : .notEditable
    }

    /// 现在的目标和按键那一刻记下的比，算不算变了：换了 App 算；两次都读到了输入框、却不是同一个也算。
    /// 没记下目标（capturedPID 为 nil，比如直接按的「发送」键）不比；按键那一刻没读到输入框的只比 App。
    public static func targetChanged(capturedPID: Int32?, currentPID: Int32?, sameElement: Bool?) -> Bool {
        guard let capturedPID else { return false }
        guard capturedPID == currentPID else { return true }
        return sameElement == false
    }

    /// 能不能贴字；返回 nil 表示可以。密码框排在最前：不管别的条件，密码框绝不贴。
    public static func paste(trusted: Bool, field: FieldFacts?, changed: Bool) -> DeliveryBlock? {
        guard trusted else { return .noPermission }
        let kind = kind(field)
        if kind == .secure { return .secureField }
        if changed { return .targetChanged }
        return kind == .editable ? nil : .notEditable
    }

    /// 能不能按回车：在贴字的条件上再加一条，输入框里得有字（读不到字的不拦）。
    public static func sendReturn(trusted: Bool, field: FieldFacts?, changed: Bool) -> DeliveryBlock? {
        if let block = paste(trusted: trusted, field: field, changed: changed) { return block }
        if let text = field?.text, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyField }
        return nil
    }
}

/// 某一刻的出字目标：前台 App 和它焦点所在的元素。
public struct TextTarget {
    public let pid: Int32
    public let appName: String?
    /// 焦点所在元素的属性；读不到为 nil
    public let field: FieldFacts?
    /// 判断是不是同一个输入框用：别的 App 是辅助功能元素，掌声自己的窗口是输入框本身
    private let element: AnyObject?

    /// 和另一刻的目标是不是同一个元素；有一边没读到就是 nil（说不准）。
    public func sameElement(as other: TextTarget) -> Bool? {
        guard let element, let otherElement = other.element else { return nil }
        return CFEqual(element, otherElement)
    }

    /// 读现在的前台 App 和焦点。readText：要不要读输入框里的字（只有按回车前要，终端的整屏内容可能很长）。
    @MainActor
    public static func current(readText: Bool = false) -> TextTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        if pid == ProcessInfo.processInfo.processIdentifier {
            // 掌声自己在前台（比如引导里的试写区）：直接看自己的窗口，不走辅助功能接口问自己。
            let (element, field) = ownFocus(readText: readText)
            return TextTarget(pid: pid, appName: app.localizedName, field: field, element: element)
        }
        guard KeyPoster.canPost else { return TextTarget(pid: pid, appName: app.localizedName, field: nil, element: nil) }
        let root = AXUIElementCreateApplication(pid)
        // 目标 App 卡住时最多等半秒，免得按键那一下把掌声也卡住。
        AXUIElementSetMessagingTimeout(root, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return TextTarget(pid: pid, appName: app.localizedName, field: nil, element: nil)
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)
        func attribute(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        var settable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let field = FieldFacts(
            role: attribute(kAXRoleAttribute) as? String,
            subrole: attribute(kAXSubroleAttribute) as? String,
            valueSettable: settableStatus == .success && settable.boolValue,
            protected: (attribute("AXProtectedContent") as? NSNumber)?.boolValue ?? false,
            text: readText ? attribute(kAXValueAttribute) as? String : nil
        )
        return TextTarget(pid: pid, appName: app.localizedName, field: field, element: element)
    }

    @MainActor
    private static func ownFocus(readText: Bool) -> (AnyObject?, FieldFacts?) {
        guard let responder = NSApp.keyWindow?.firstResponder else { return (nil, nil) }
        let textView = responder as? NSTextView
        // 输入框正在编辑时，第一响应者是窗口共用的编辑器，真正的输入框是它的 delegate。
        let owner = (textView?.isFieldEditor == true ? textView?.delegate as? NSResponder : nil) ?? responder
        if owner is NSSecureTextField {
            return (owner, FieldFacts(role: "AXTextField", subrole: "AXSecureTextField", valueSettable: true))
        }
        guard let textView else { return (owner, FieldFacts(role: nil, valueSettable: false)) }
        return (owner, FieldFacts(role: textView.isFieldEditor ? "AXTextField" : "AXTextArea", valueSettable: textView.isEditable,
                                  text: readText ? textView.string : nil))
    }
}

/// 按规则贴字、按回车。
public enum TextDelivery {
    public enum Result: Equatable, Sendable {
        /// 贴进了这个 App
        case inserted(appName: String?)
        /// 没贴，字放进了剪贴板
        case copied(DeliveryBlock)
    }

    /// 看现在能不能贴字（不贴）。captured：按键那一刻记下的目标，nil 表示不比。
    @MainActor
    public static func checkPaste(since captured: TextTarget?) -> (block: DeliveryBlock?, target: TextTarget?) {
        let now = TextTarget.current()
        return (DeliveryRule.paste(trusted: KeyPoster.canPost, field: now?.field, changed: changed(from: captured, to: now)), now)
    }

    /// 能贴就贴；贴不了就把字留在剪贴板里，交给用户按 ⌘V。
    @MainActor
    public static func insert(_ text: String, method: TextInserter.Method, since captured: TextTarget?) -> Result {
        let (block, now) = checkPaste(since: captured)
        if let block {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .copied(block)
        }
        TextInserter.insert(text, method: method)
        return .inserted(appName: now?.appName)
    }

    /// 确认能按再按回车，返回给用户看的结果。
    @MainActor
    @discardableResult
    public static func sendReturn(since captured: TextTarget? = nil) -> String {
        let now = TextTarget.current(readText: true)
        if let block = DeliveryRule.sendReturn(trusted: KeyPoster.canPost, field: now?.field, changed: changed(from: captured, to: now)) {
            return block.returnMessage
        }
        KeyPoster.post(.returnKey)
        return "已在「\(now?.appName ?? "前台 App")」按了回车"
    }

    private static func changed(from captured: TextTarget?, to now: TextTarget?) -> Bool {
        let same: Bool? = if let captured, let now { captured.sameElement(as: now) } else { nil }
        return DeliveryRule.targetChanged(capturedPID: captured?.pid, currentPID: now?.pid, sameElement: same)
    }
}
