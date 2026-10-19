import Darwin
import Foundation

/// 命令行交互的小工具。
enum Console {
    static func say(_ text: String = "") {
        print(text)
        fflush(stdout)
    }

    static func ask(_ question: String) -> String {
        print(question, terminator: "")
        fflush(stdout)
        return (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func confirm(_ question: String) -> Bool {
        ["y", "yes", "是", "要", "好"].contains(ask(question).lowercased())
    }

    /// 解析「1,3」这样的序号列表（从 1 开始），越界的忽略。
    static func indices(_ text: String, count: Int) -> [Int] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " })
            .compactMap { Int($0) }
            .filter { $0 >= 1 && $0 <= count }
            .map { $0 - 1 }
    }

    /// 找到运行探针的那个 App（终端），权限要授给它。
    static func hostAppName() -> String? {
        var pid = getppid()
        for _ in 0..<12 where pid > 1 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                let full = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if let range = full.range(of: ".app/") {
                    let appPath = String(full[..<range.lowerBound])
                    return ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
                }
            }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { break }
            pid = pid_t(info.pbi_ppid)
        }
        return nil
    }
}
