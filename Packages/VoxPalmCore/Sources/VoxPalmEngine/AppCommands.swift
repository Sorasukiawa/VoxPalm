import AppKit
import ApplicationServices

/// 某个 App 的菜单命令。执行时先把 App 切到前台，再按菜单路径点菜单项；菜单找不到（比如 App 换了语言）时按备用快捷键。
public struct MenuCommand: Codable, Hashable, Sendable {
    public var bundleID: String
    public var appName: String
    /// 菜单路径，例如 ["Go", "Next Session"]；空数组表示只把 App 切到前台
    public var path: [String]
    public var shortcut: KeyCombo?
    public var title: String

    public init(bundleID: String, appName: String, path: [String], shortcut: KeyCombo? = nil, title: String) {
        self.bundleID = bundleID
        self.appName = appName
        self.path = path
        self.shortcut = shortcut
        self.title = title
    }
}

public enum ChatDirection: String, Codable, CaseIterable, Sendable {
    case previous
    case next

    public var title: String { self == .previous ? "上一个对话" : "下一个对话" }
}

/// 掌声认识的 AI 编程工具，以及切换对话用的菜单。菜单路径是 2026-10-19 在本机 App 上读出来的。
public struct AIToolProfile: Sendable, Identifiable {
    public let bundleID: String
    public let name: String
    public let open: MenuCommand
    public let previousChat: MenuCommand
    public let nextChat: MenuCommand
    public let newChat: MenuCommand

    public var id: String { bundleID }

    public func chat(_ direction: ChatDirection) -> MenuCommand { direction == .previous ? previousChat : nextChat }

    // 虚拟键码：[ 是 33，] 是 30，N 是 45
    private static let cmd = CGEventFlags.maskCommand.rawValue
    private static let shift = CGEventFlags.maskShift.rawValue
    private static let option = CGEventFlags.maskAlternate.rawValue

    public static let claude = AIToolProfile(
        bundleID: "com.anthropic.claudefordesktop",
        name: "Claude Code",
        open: MenuCommand(bundleID: "com.anthropic.claudefordesktop", appName: "Claude", path: ["Go", "Code"], title: "打开 Claude Code"),
        previousChat: MenuCommand(bundleID: "com.anthropic.claudefordesktop", appName: "Claude", path: ["Go", "Previous Session"],
                                  shortcut: KeyCombo(keyCode: 33, modifiers: shift | cmd, display: "⇧⌘["), title: "Claude：上一个会话"),
        nextChat: MenuCommand(bundleID: "com.anthropic.claudefordesktop", appName: "Claude", path: ["Go", "Next Session"],
                              shortcut: KeyCombo(keyCode: 30, modifiers: shift | cmd, display: "⇧⌘]"), title: "Claude：下一个会话"),
        newChat: MenuCommand(bundleID: "com.anthropic.claudefordesktop", appName: "Claude", path: ["File", "New Session"],
                             shortcut: KeyCombo(keyCode: 45, modifiers: cmd, display: "⌘N"), title: "Claude：新会话")
    )

    public static let codex = AIToolProfile(
        bundleID: "com.openai.codex",
        name: "Codex",
        open: MenuCommand(bundleID: "com.openai.codex", appName: "Codex", path: [], title: "打开 Codex"),
        previousChat: MenuCommand(bundleID: "com.openai.codex", appName: "Codex", path: ["View", "Previous Sidebar Item"],
                                  shortcut: KeyCombo(keyCode: 33, modifiers: option | cmd, display: "⌥⌘["), title: "Codex：上一个对话"),
        nextChat: MenuCommand(bundleID: "com.openai.codex", appName: "Codex", path: ["View", "Next Sidebar Item"],
                              shortcut: KeyCombo(keyCode: 30, modifiers: option | cmd, display: "⌥⌘]"), title: "Codex：下一个对话"),
        newChat: MenuCommand(bundleID: "com.openai.codex", appName: "Codex", path: ["File", "New Chat"],
                             shortcut: KeyCombo(keyCode: 45, modifiers: cmd, display: "⌘N"), title: "Codex：新对话")
    )

    public static let all: [AIToolProfile] = [claude, codex]

    public static func profile(bundleID: String?) -> AIToolProfile? {
        all.first { $0.bundleID == bundleID }
    }

    public var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
}

/// 执行菜单命令：切 App、点菜单、找输入框。都要辅助功能权限。
public enum AppCommander {
    public enum Outcome: Equatable, Sendable {
        case done
        case failed(String)
    }

    /// 把 App 切到前台（没开就打开），最多等 3 秒。
    @MainActor
    public static func activate(bundleID: String) async -> NSRunningApplication? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            if !running.isActive { running.activate() }
            return await waitFrontmost(bundleID) ? running : nil
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return await waitFrontmost(bundleID) ? app : nil
    }

    @MainActor
    private static func waitFrontmost(_ bundleID: String) async -> Bool {
        for _ in 0..<30 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    @MainActor
    public static func run(_ command: MenuCommand) async -> Outcome {
        guard let app = await activate(bundleID: command.bundleID) else {
            return .failed("打不开「\(command.appName)」：没装或者切不到前台")
        }
        guard !command.path.isEmpty else { return .done }
        guard KeyPoster.canPost else { return .failed("没有辅助功能权限，点不了「\(command.appName)」的菜单") }
        if let item = findMenuItem(pid: app.processIdentifier, path: command.path),
           AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
            return .done
        }
        if let shortcut = command.shortcut {
            KeyPoster.post(shortcut)
            return .done
        }
        return .failed("在「\(command.appName)」里找不到菜单「\(command.path.joined(separator: " → "))」")
    }

    /// 前台是 Claude 或 Codex 时，切到上一个 / 下一个对话。
    @MainActor
    public static func switchChat(_ direction: ChatDirection) async -> Outcome {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let profile = AIToolProfile.profile(bundleID: front) else {
            return .failed("前台不是 Claude 或 Codex，没有切换对话")
        }
        return await run(profile.chat(direction))
    }

    /// 按菜单路径找菜单项（不打开菜单）。
    public static func findMenuItem(pid: pid_t, path: [String]) -> AXUIElement? {
        guard let first = path.first else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let bar = element(app, kAXMenuBarAttribute) else { return nil }
        var current = children(bar).first { title($0) == first }
        for name in path.dropFirst() {
            // 菜单栏项和子菜单项下面先是一个 AXMenu，再是菜单项。
            guard let parent = current, let menu = children(parent).first(where: { role($0) == kAXMenuRole }) else { return nil }
            current = children(menu).first { title($0) == name }
        }
        return current
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func title(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        return value as? String
    }

    private static func role(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return value as? String
    }
}
