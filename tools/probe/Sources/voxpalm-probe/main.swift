import AppKit
import Foundation

// 监听器（HID、事件监听、CoreAudio、正在播放）都挂在主线程的运行循环上；
// 命令本身在后台线程跑，这样向导可以一边等输入一边收事件。
setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let cli = ProbeCLI(arguments: Array(CommandLine.arguments.dropFirst()))
Thread {
    let code = cli.run()
    DispatchQueue.main.async { exit(code) }
}.start()
app.run()
