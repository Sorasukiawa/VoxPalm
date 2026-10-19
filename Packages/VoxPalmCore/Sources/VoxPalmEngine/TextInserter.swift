import AppKit

/// 把文字放到光标所在的地方。默认走剪贴板粘贴（中文、表情都稳），粘贴完把剪贴板原来的内容放回去。
public enum TextInserter {
    public enum Method: String, Codable, CaseIterable, Sendable {
        case paste
        case type

        public var title: String {
            switch self {
            case .paste: return "粘贴（推荐）"
            case .type: return "逐字输入"
            }
        }
    }

    @MainActor
    public static func insert(_ text: String, method: Method = .paste) {
        guard !text.isEmpty else { return }
        switch method {
        case .paste: paste(text)
        case .type: type(text)
        }
    }

    @MainActor
    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChange = pasteboard.changeCount
        KeyPoster.post(KeyCombo(keyCode: 9, modifiers: CGEventFlags.maskCommand.rawValue, display: "⌘V"))
        // 等前台 App 读完再还原；期间用户自己又复制了别的东西就不还原。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    private static func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 16, units.count)])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.setIntegerValueField(.eventSourceUserData, value: KeyPoster.marker)
                event.post(tap: .cghidEventTap)
            }
            index += 16
        }
    }
}
