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

    /// 焦点不在输入框上时，焦点所在那一块里的输入框（按树的顺序）：正好只有一个能打字的、而且没有密码框，才返回它的位置；
    /// 一个都没有、不止一个、或者有密码框（像登录表单）都不猜，返回 nil。
    public static func soleEditable(_ candidates: [FieldFacts], searchComplete: Bool = true) -> Int? {
        // 没读完整的区域里还可能有第二个输入框或密码框，不能把已读到的一个当作唯一。
        guard searchComplete else { return nil }
        let kinds = candidates.map(kind)
        guard !kinds.contains(.secure) else { return nil }
        let editable = kinds.indices.filter { kinds[$0] == .editable }
        return editable.count == 1 ? editable[0] : nil
    }

    static func confirmsRefocus(expectedPID: Int32, currentPID: Int32?, sameElement: Bool?, field: FieldFacts?) -> Bool {
        expectedPID == currentPID && sameElement == true && kind(field) == .editable
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
    public var bundleID: String?
    /// 读焦点失败时辅助功能接口的错误码（-25204 是对方没在限时内回话，-25212 是没有焦点元素）
    public var readError: Int32?
    /// 焦点本来不在输入框上，是掌声把光标放进了那一块里唯一的输入框
    public var refocused = false

    init(pid: Int32, appName: String?, field: FieldFacts?, element: AnyObject?, bundleID: String? = nil, readError: Int32? = nil) {
        self.pid = pid
        self.appName = appName
        self.field = field
        self.element = element
        self.bundleID = bundleID
        self.readError = readError
    }

    /// 写进诊断日志的一句：哪个 App、焦点是什么元素、读失败的错误码（不含输入框里的字）
    public var diagnostics: String {
        var parts = ["\(appName ?? "?")（\(bundleID ?? "?")）"]
        if let field { parts.append("焦点 \(field.role ?? "?")/\(field.subrole ?? "-") 可写=\(field.valueSettable)") } else { parts.append("没读到焦点") }
        if let readError { parts.append("错误 \(readError)") }
        if refocused { parts.append("已把光标放进那一块里唯一的输入框") }
        return parts.joined(separator: "，")
    }

    /// 和另一刻的目标是不是同一个元素；有一边没读到就是 nil（说不准）。
    public func sameElement(as other: TextTarget) -> Bool? {
        guard let element, let otherElement = other.element else { return nil }
        return CFEqual(element, otherElement)
    }

    /// 读现在的前台 App 和焦点。readText：要不要读输入框里的字（只有按回车前要，终端的整屏内容可能很长）。
    /// patient：对方半秒内没回话时再等久一点重读一次（贴字、按回车前用；按键那一刻不等，免得卡住）。
    @MainActor
    public static func current(readText: Bool = false, patient: Bool = false) -> TextTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        if pid == ProcessInfo.processInfo.processIdentifier {
            // 掌声自己在前台（比如引导里的试写区）：直接看自己的窗口，不走辅助功能接口问自己。
            let (element, field) = ownFocus(readText: readText)
            return TextTarget(pid: pid, appName: app.localizedName, field: field, element: element, bundleID: app.bundleIdentifier)
        }
        guard KeyPoster.canPost else { return TextTarget(pid: pid, appName: app.localizedName, field: nil, element: nil, bundleID: app.bundleIdentifier) }
        let root = AXUIElementCreateApplication(pid)
        // 目标 App 卡住时最多等半秒，免得按键那一下把掌声也卡住。电脑很忙时（比如刚开机）半秒不够，贴字前再等 1.5 秒读一次。
        AXUIElementSetMessagingTimeout(root, 0.5)
        var focused: CFTypeRef?
        var status = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused)
        if status == .cannotComplete, patient {
            AXUIElementSetMessagingTimeout(root, 1.5)
            status = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused)
        }
        guard status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return TextTarget(pid: pid, appName: app.localizedName, field: nil, element: nil, bundleID: app.bundleIdentifier,
                              readError: status == .success ? nil : status.rawValue)
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, patient ? 1.5 : 0.5)
        return TextTarget(pid: pid, appName: app.localizedName, field: facts(of: element, readText: readText), element: element,
                          bundleID: app.bundleIdentifier)
    }

    private static func facts(of element: AXUIElement, readText: Bool) -> FieldFacts {
        func attribute(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        var settable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return FieldFacts(
            role: attribute(kAXRoleAttribute) as? String,
            subrole: attribute(kAXSubroleAttribute) as? String,
            valueSettable: settableStatus == .success && settable.boolValue,
            protected: (attribute("AXProtectedContent") as? NSNumber)?.boolValue ?? false,
            text: readText ? attribute(kAXValueAttribute) as? String : nil
        )
    }

    /// 焦点停在一块区域上、不在输入框里（聊天 App 点了对话区以后常这样：焦点在对话区，输入框在它里面，打字时 App 才把光标挪回输入框）：
    /// 在焦点那一块里找输入框，正好只有一个能打字的、而且没有密码框，就把光标放进去，返回放好以后的目标；不然返回 nil，不猜。
    @MainActor
    public func focusSoleInput(readText: Bool = false) -> TextTarget? {
        guard let element, CFGetTypeID(element) == AXUIElementGetTypeID(), DeliveryRule.kind(field) == .notEditable else { return nil }
        let container = element as! AXUIElement
        let textRoles = DeliveryRule.textRoles.union(["AXSecureTextField"])
        // 一层层往下找，最多看 800 个元素、20 层，免得在大页面里找太久
        var queue: [(AXUIElement, Int)] = [(container, 0)]
        var visited = 0
        var searchComplete = true
        var candidates: [(AXUIElement, FieldFacts)] = []
        while !queue.isEmpty, visited < 800 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(node, 0.5)
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role) == .success else {
                searchComplete = false
                break
            }
            if let role = role as? String, textRoles.contains(role) {
                candidates.append((node, Self.facts(of: node, readText: false)))
                continue
            }
            var children: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children)
            if status == .success, let children = children as? [AXUIElement] {
                if depth >= 20, !children.isEmpty {
                    searchComplete = false
                    break
                }
                queue += children.map { ($0, depth + 1) }
            } else if status != .noValue, status != .attributeUnsupported {
                searchComplete = false
                break
            }
        }
        guard let index = DeliveryRule.soleEditable(candidates.map(\.1), searchComplete: searchComplete && queue.isEmpty) else { return nil }
        let input = candidates[index].0
        guard AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { return nil }
        // 等 App 把光标挪过去再贴
        Thread.sleep(forTimeInterval: 0.15)
        guard var now = Self.current(readText: readText, patient: true),
              DeliveryRule.confirmsRefocus(expectedPID: pid, currentPID: now.pid,
                                          sameElement: now.element.map { CFEqual(input, $0) }, field: now.field) else { return nil }
        now.refocused = true
        return now
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
    /// 焦点还在按键时那一块、只是不在输入框上时，会把光标放进那一块里唯一的输入框（见 focusSoleInput）。
    /// refocus 为 false 时只看不动（调试用，不碰前台 App）。
    @MainActor
    public static func checkPaste(since captured: TextTarget?, refocus: Bool = true) -> (block: DeliveryBlock?, target: TextTarget?) {
        let now = TextTarget.current(patient: true)
        let block = DeliveryRule.paste(trusted: KeyPoster.canPost, field: now?.field, changed: changed(from: captured, to: now))
        if block == .notEditable, refocus, let refocused = now?.focusSoleInput() { return (nil, refocused) }
        return (block, now)
    }

    /// 能贴就贴；贴不了就把字留在剪贴板里，交给用户按 ⌘V。返回结果和贴字时的目标（之后按回车拿它比）。
    @MainActor
    public static func insert(_ text: String, method: TextInserter.Method, since captured: TextTarget?) -> (result: Result, target: TextTarget?) {
        let (block, now) = checkPaste(since: captured)
        if let block {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return (.copied(block), now)
        }
        TextInserter.insert(text, method: method)
        return (.inserted(appName: now?.appName), now)
    }

    /// 确认能按再按回车，返回给用户看的结果。焦点不在输入框上时和贴字一样，先放进那一块里唯一的输入框。
    @MainActor
    @discardableResult
    public static func sendReturn(since captured: TextTarget? = nil) -> String {
        var now = TextTarget.current(readText: true, patient: true)
        var block = DeliveryRule.sendReturn(trusted: KeyPoster.canPost, field: now?.field, changed: changed(from: captured, to: now))
        if block == .notEditable, let refocused = now?.focusSoleInput(readText: true) {
            now = refocused
            block = DeliveryRule.sendReturn(trusted: KeyPoster.canPost, field: refocused.field, changed: false)
        }
        if let block { return block.returnMessage }
        KeyPoster.post(.returnKey)
        return "已在「\(now?.appName ?? "前台 App")」按了回车"
    }

    private static func changed(from captured: TextTarget?, to now: TextTarget?) -> Bool {
        let same: Bool? = if let captured, let now { captured.sameElement(as: now) } else { nil }
        return DeliveryRule.targetChanged(capturedPID: captured?.pid, currentPID: now?.pid, sameElement: same)
    }
}
