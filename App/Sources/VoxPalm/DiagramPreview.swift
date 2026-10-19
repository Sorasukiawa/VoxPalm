import AppKit
import SwiftUI
import VoxPalmEngine

/// 调试用：`VoxPalm --render-diagrams <目录>` 把每种示意图（套上「AI 编程」预设）画成 PNG 后退出，不开窗口。
@MainActor
enum DiagramPreview {
    static func renderIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--render-diagrams"), index + 1 < args.count else { return }
        let directory = URL(fileURLWithPath: args[index + 1])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var diagrams = DeviceDiagram.choices.map { diagram -> DeviceDiagram in
            diagram.id == "generic"
                ? .generic(buttons: [(ButtonID("key:121"), "按键 PageDown"), (ButtonID("key:116"), "按键 PageUp"), (ButtonID("key:11"), "按键 B")])
                : diagram
        } + [DeviceDiagram.mediaKeys]
        diagrams += PrivateModules.previewDiagrams()
        for diagram in diagrams {
            var buttons: [String: ButtonID] = [:]
            for spot in diagram.spots where spot.id != "menu" {
                buttons[spot.id] = spot.button ?? ButtonID("demo:\(spot.id)")
            }
            let resolved = AppModel.ResolvedDiagram(diagram: diagram, buttons: buttons, isFixed: false, reportsRelease: diagram.reportsRelease)
            var keyMap = KeyMap()
            for binding in AIPreset.bindings(for: resolved) { keyMap.set(binding) }
            let callouts = DiagramCallout.make(diagram: diagram, buttons: buttons, keyMap: keyMap,
                                               reportsRelease: resolved.reportsRelease, learning: nil)
            let selected = diagram.spots.first { ["down", "next", "record"].contains($0.id) }?.id
            for scheme in [ColorScheme.light, .dark] {
                let view = DeviceDiagramView(diagram: diagram, callouts: callouts, pressed: [], buttons: buttons, selected: selected)
                    .padding(16)
                    .frame(width: 680)
                    .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.95))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                let name = "diagram-\(diagram.id)-\(scheme == .dark ? "dark" : "light").png"
                try? png.write(to: directory.appendingPathComponent(name))
            }
        }
        exit(0)
    }
}
