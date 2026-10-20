import AppKit
import AVFoundation
import Observation
import SwiftUI
import VoxPalmDevices
import VoxPalmEngine
import VoxPalmVoice

// 选设备：左边转盘画出设备（拖、触控板左右滑、点两边、方向键都能切），右边按类别分组的列表，两边是同一份数据。
// 引导的「用什么按」「用什么收音」和设置的设备页共用（design/VoxPalm-Motion.html「选设备细看」）。

// MARK: - 设备清单

/// 转盘和列表里的一项控制设备：连着的设备，加上认识但没连上的型号（灰的，告诉用户还支持什么）。
struct PickerDevice: Identifiable, Equatable {
    enum Category: Int, CaseIterable, Comparable {
        case remote, presenter, mic, keyboard, headphones, other

        var title: String {
            switch self {
            case .remote: return "遥控器"
            case .presenter: return "翻页笔和脚踏板"
            case .mic: return "无线麦"
            case .keyboard: return "键盘"
            case .headphones: return "耳机"
            case .other: return "其他"
            }
        }

        static func < (a: Category, b: Category) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String
    let name: String
    /// 浮窗、面板用的短名字，例如「小米遥控器 2」
    let shortName: String
    let category: Category
    /// 转盘上画的样子
    let art: DeviceDiagram
    let connected: Bool
    let detail: String
    let device: ControlDevice?
}

/// 收音设备：跟随系统默认输入排第一，其余按这台 Mac / 外接 / 蓝牙 / iPhone 分组。
struct PickerMic: Identifiable, Equatable {
    let id: String
    let uid: String?
    let name: String
    let shortName: String
    let group: String
    let art: DeviceDiagram
    let detail: String
    let warning: String?
}

extension AppModel {
    /// 认识的型号：没连上也列出来（闭源适配目前都是无线麦）
    private static let knownModels: [(DeviceDiagram, PickerDevice.Category, String)] = [
        (.xiaomiRemote2, .remote, "小米遥控器 2"),
        (.siriRemote, .remote, "Siri Remote"),
    ] + PrivateModules.knownModels().map { ($0.diagram, .mic, $0.shortName) }

    static func shortName(for device: ControlDevice, art: DeviceDiagram) -> String {
        if let known = knownModels.first(where: { $0.0.id == art.id }) { return known.2 }
        switch device.id {
        case SystemKeysControlSource.mediaDeviceID: return "媒体键"
        case SystemKeysControlSource.keyboardDeviceID: return "键盘按键"
        case NowPlayingControlSource.deviceID: return "耳机按键"
        default: return device.name
        }
    }

    /// 这台设备在转盘上画什么：适配模块或用户选过的外形；耳机按键、键盘按键画自己的样子。
    func pickerArt(for device: ControlDevice) -> DeviceDiagram {
        switch device.id {
        case NowPlayingControlSource.deviceID: return PickerArt.earbuds
        case SystemKeysControlSource.keyboardDeviceID: return PickerArt.keyboard
        default:
            let resolved = diagram(for: device).diagram
            return resolved.id == "generic" && resolved.spots.isEmpty ? PickerArt.box : resolved
        }
    }

    func category(for device: ControlDevice, art: DeviceDiagram) -> PickerDevice.Category {
        switch device.sourceID {
        case "system-keys": return .keyboard
        case "now-playing": return .headphones
        case "hid":
            switch art.id {
            case DeviceDiagram.xiaomiRemote2.id, DeviceDiagram.siriRemote.id, DeviceDiagram.remote.id: return .remote
            case DeviceDiagram.presenter.id, DeviceDiagram.footPedal.id: return .presenter
            case DeviceDiagram.micTransmitter.id: return .mic
            default: return .other
            }
        default:
            // 闭源适配目前都是无线麦
            return .mic
        }
    }

    var pickerDevices: [PickerDevice] {
        var items: [PickerDevice] = devices.map { device in
            let art = pickerArt(for: device)
            let known = Self.knownModels.first { $0.0.id == art.id }
            return PickerDevice(id: device.id, name: known?.0.title ?? device.name, shortName: Self.shortName(for: device, art: art),
                                category: category(for: device, art: art), art: art, connected: true,
                                detail: Self.shortDetail(device), device: device)
        }
        for (diagram, category, short) in Self.knownModels where !items.contains(where: { $0.art.id == diagram.id }) {
            items.append(PickerDevice(id: "known:" + diagram.id, name: diagram.title, shortName: short, category: category,
                                      art: diagram, connected: false, detail: "没连上", device: nil))
        }
        // 选过、现在没连上的设备也留在列表里
        for id in config.controlDeviceIDs where !items.contains(where: { $0.id == id }) {
            items.append(PickerDevice(id: id, name: activeDeviceName ?? "已选的设备", shortName: activeDeviceName ?? "已选的设备", category: .other,
                                      art: PickerArt.box, connected: false, detail: "没连上", device: nil))
        }
        return items.enumerated().sorted { a, b in
            a.element.category != b.element.category ? a.element.category < b.element.category
                : a.element.connected != b.element.connected ? a.element.connected : a.offset < b.offset
        }.map(\.element)
    }

    static func shortDetail(_ device: ControlDevice) -> String {
        switch device.sourceID {
        case "system-keys": return device.id == SystemKeysControlSource.mediaDeviceID ? "F7 – F12 · 不用学键" : "F13 – F19 这类空闲键"
        case "now-playing": return "播放 / 暂停 · 读不到松开"
        default:
            let transport = device.detail.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return transport.isEmpty ? device.detail : transport
        }
    }

    var pickerMics: [PickerMic] {
        func kind(_ mic: AudioDeviceInfo) -> (String, DeviceDiagram) {
            if mic.transport == "Built-in" { return ("这台 Mac", PickerArt.laptop) }
            if mic.isBluetooth { return ("蓝牙", PickerArt.earbuds) }
            if mic.transport.hasPrefix("Continuity") { return ("iPhone", PickerArt.phone) }
            if mic.transport == "Virtual" { return ("其他", PickerArt.system) }
            return ("外接", PickerArt.receiver)
        }
        let systemDefault = micDevices.first(where: \.isDefaultInput)
        // 「跟随系统默认」画现在的默认麦克风长什么样
        var items = [PickerMic(id: "default", uid: nil, name: "跟随系统默认输入", shortName: "系统默认", group: "系统",
                               art: systemDefault.map { kind($0).1 } ?? PickerArt.system,
                               detail: "现在是 \(systemDefault?.name ?? "系统默认输入")", warning: nil)]
        for mic in micDevices {
            let (group, art) = kind(mic)
            let short = mic.transport == "Built-in" ? "Mac 麦克风" : mic.name
            items.append(PickerMic(id: mic.uid, uid: mic.uid, name: mic.name, shortName: short, group: group, art: art,
                                   detail: "\(DevicesPane.transportName(mic)) · \(Int(mic.nominalSampleRate / 1000)) kHz",
                                   warning: mic.isLowRateBluetoothInput ? "通话音质，转写会差一些" : nil))
        }
        let order = ["系统", "这台 Mac", "外接", "蓝牙", "iPhone", "其他"]
        return items.sorted { (order.firstIndex(of: $0.group) ?? 9) < (order.firstIndex(of: $1.group) ?? 9) }
    }

    /// 选中的控制设备在转盘上的那一项
    var activePickerDevice: PickerDevice? {
        guard let id = config.controlDeviceIDs.first else { return nil }
        return pickerDevices.first { $0.id == id }
    }

    /// 浮窗副标题、面板磁贴用的设备短名
    var activeShortName: String? { activePickerDevice?.shortName ?? activeDeviceName }
}

/// 收音设备、耳机、键盘这些没有按键示意图的东西，只画外形（毫米，和设备示意图同一套画法）。
enum PickerArt {
    private typealias Box = DeviceDiagram.Box
    private typealias Part = DeviceDiagram.Part
    private typealias Spot = DeviceDiagram.Spot

    static let laptop = DeviceDiagram(id: "art-laptop", title: "MacBook", width: 120, height: 76, parts: [
        Part(Box(10, 0, 100, 66), .rounded(5), .aluminum),
        Part(Box(14, 4, 92, 57), .rounded(2.5), .graphite),
        Part(.circle(60, 2, 1.4), .circle, .port),
        Part(Box(0, 66, 120, 7), .rounded(3.5), .aluminum),
        Part(Box(50, 66, 20, 2.6), .rounded(1.3), .recess),
    ], spots: [])

    static let receiver = DeviceDiagram(id: "art-receiver", title: "USB 接收器", width: 40, height: 60, parts: [
        Part(Box(0, 0, 40, 46), .rounded(9), .graphite),
        Part(Box(8, 9, 24, 13), .rounded(2.5), .recess),
        Part(.center(20, 33, 6, 1.8), .capsule, .led),
        Part(Box(14, 46, 12, 12), .rounded(2.5), .aluminum),
        Part(Box(16.5, 52, 7, 3.5), .rounded(1.5), .port),
    ], spots: [])

    static let phone = DeviceDiagram(id: "art-phone", title: "iPhone", width: 40, height: 82, parts: [
        Part(Box(0, 0, 40, 82), .rounded(8), .graphite),
        Part(Box(2, 2, 36, 78), .rounded(6.5), .recess),
        Part(.center(20, 6.4, 10, 3), .capsule, .port),
    ], spots: [])

    static let system = DeviceDiagram(id: "art-system", title: "系统默认输入", width: 60, height: 60, parts: [
        Part(Box(0, 0, 60, 60), .rounded(14), .graphite),
        Part(.circle(30, 30, 30), .circle, .recess),
        Part(.circle(30, 30, 30), .circle, .mark, symbol: "gearshape"),
    ], spots: [])

    static let earbuds = DeviceDiagram(id: "art-earbuds", title: "耳机", width: 64, height: 50, parts: [
        Part(.circle(16, 12, 19), .circle, .aluminum),
        Part(.center(19.5, 31, 7, 30), .capsule, .aluminum),
        Part(.circle(48, 12, 19), .circle, .aluminum),
        Part(.center(44.5, 31, 7, 30), .capsule, .aluminum),
        Part(.center(14, 9, 5, 2), .capsule, .grille),
        Part(.center(50, 9, 5, 2), .capsule, .grille),
    ], spots: [Spot("stem", "耳机柄", .center(19.5, 34, 7, 16), .capsule, .zone)])

    static let keyboard: DeviceDiagram = {
        var parts = [Part(Box(0, 0, 220, 78), .rounded(7), .aluminum)]
        var spots: [Spot] = []
        for (row, (y, h, count)) in [(5.0, 8.0, 14), (16.0, 13.0, 13), (32.0, 13.0, 13), (48.0, 13.0, 12)].enumerated() {
            let w = (210 - Double(count - 1) * 2) / Double(count)
            for index in 0..<count {
                let box = Box(5 + Double(index) * (w + 2), y, w, h)
                if row == 0 && index == count - 1 { spots.append(Spot("fkey", "F19（空闲键）", box, .rounded(1.5))) }
                else { parts.append(Part(box, .rounded(1.5), .blackKey)) }
            }
        }
        parts += [Part(Box(5, 63, 40, 11), .rounded(1.5), .blackKey), Part(Box(47, 63, 126, 11), .rounded(1.5), .blackKey),
                  Part(Box(175, 63, 40, 11), .rounded(1.5), .blackKey)]
        return DeviceDiagram(id: "art-keyboard", title: "键盘", width: 220, height: 78, parts: parts, spots: spots)
    }()

    /// 不知道长什么样、也没学过键的设备
    static let box = DeviceDiagram(id: "art-box", title: "设备", width: 46, height: 80, parts: [
        Part(Box(0, 0, 46, 80), .rounded(14), .graphite),
        Part(.circle(23, 30, 18), .circle, .blackKey),
        Part(.circle(23, 56, 12), .circle, .blackKey),
    ], spots: [])
}

// MARK: - 画设备

/// 只画设备本体，按比例放进给的地方。可以点亮一个键（一圈光往外扩）、高亮按下的键、点键。
struct DeviceFigure: View {
    let diagram: DeviceDiagram
    var highlighted: [String: DeviceArt.Highlight] = [:]
    var lit: String?
    var showsSymbols = true
    var onTap: ((String) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let layout = DiagramLayout.fitting(diagram, in: geometry.size)
            ZStack(alignment: .topLeading) {
                DeviceArt(diagram: diagram, layout: layout, highlighted: highlighted, showsSymbols: showsSymbols)
                if let lit, let spot = diagram.spots.first(where: { $0.id == lit }) {
                    LitRing(frame: layout.frame(spot.box), isCircle: spot.shape == .circle)
                }
                if let onTap {
                    ForEach(diagram.spots) { spot in
                        let frame = layout.frame(spot.box).insetBy(dx: -3, dy: -3)
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            .onTapGesture { onTap(spot.id) }
                            .help(spot.name)
                    }
                }
            }
        }
        .aspectRatio(CGFloat(diagram.width / diagram.height), contentMode: .fit)
    }
}

// MARK: - 转盘

/// 横着排的转盘：中间那个最大，两边缩小变淡。转到哪个就是选了哪个。
struct Carousel<Item: Identifiable, Content: View>: View where Item.ID: Hashable {
    let items: [Item]
    @Binding var selection: Item.ID?
    var spacing: CGFloat = 128
    var itemSize = CGSize(width: 190, height: 200)
    /// 被「认出来了」的那一项：外圈亮两下
    var pinged: Item.ID?
    /// 每一项画出来有多宽：宽的设备（媒体键、键盘、脚踏板）和旁边那台多隔开一些，不叠在一起
    var widthOf: ((Item) -> CGFloat)?
    @ViewBuilder let content: (Item, Bool) -> Content

    @State private var position: Double = 0
    @State private var dragStart: Double?
    @FocusState private var focused: Bool

    private var index: Int { min(max(Int(position.rounded()), 0), max(items.count - 1, 0)) }

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                content(item, offset == index)
                    .frame(width: itemSize.width, height: itemSize.height)
                    .overlay { if pinged == item.id { PingRing() } }
                    .modifier(CarouselEffect(position: position, index: offset, centers: centers))
                    .onTapGesture { go(offset) }
            }
            if items.count > 1 {
                HStack {
                    arrow("chevron.left", disabled: index == 0) { go(index - 1) }
                    Spacer()
                    arrow("chevron.right", disabled: index >= items.count - 1) { go(index + 1) }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .clipped()
        .gesture(DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragStart == nil { dragStart = position }
                let raw = (dragStart ?? 0) - value.translation.width / gap(around: dragStart ?? 0)
                let last = Double(max(items.count - 1, 0))
                position = raw < 0 ? -0.5 * -raw / (1 - raw) : raw > last ? last + 0.5 * (raw - last) / (1 + raw - last) : raw
            }
            .onEnded { value in
                let predicted = (dragStart ?? position) - value.predictedEndTranslation.width / gap(around: dragStart ?? position)
                dragStart = nil
                go(Int(predicted.rounded()))
            })
        .background(ScrollWheelCatcher { step in go(index + step) })
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { go(index - 1); return .handled }
        .onKeyPress(.rightArrow) { go(index + 1); return .handled }
        .onAppear { position = Double(indexOf(selection) ?? 0) }
        .onChange(of: selection) { _, new in
            if let target = indexOf(new), target != index { withAnimation(Motion.pick(Motion.bounce)) { position = Double(target) } }
        }
        .onChange(of: items.map(\.id)) { _, _ in
            if let target = indexOf(selection) { position = Double(target) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            go(direction == .increment ? index + 1 : index - 1)
        }
    }

    private func indexOf(_ id: Item.ID?) -> Int? { id.flatMap { id in items.firstIndex { $0.id == id } } }

    /// 每一项在一条横线上的中心位置。相邻两项至少隔 spacing；宽的要隔到中间那台和旁边缩小的那台不重叠。
    private var centers: [CGFloat] {
        var result: [CGFloat] = []
        var x: CGFloat = 0
        for (offset, item) in items.enumerated() {
            if offset > 0, let widthOf {
                let a = widthOf(items[offset - 1]), b = widthOf(item)
                let side = CarouselEffect.sideScale
                x += max(spacing, max(a + side * b, b + side * a) / 2 + 16)
            } else if offset > 0 {
                x += spacing
            }
            result.append(x)
        }
        return result
    }

    private func gap(around position: Double) -> CGFloat {
        let c = centers
        guard c.count > 1 else { return spacing }
        let i = min(max(Int(position.rounded()), 0), c.count - 1)
        let left = i > 0 ? c[i] - c[i - 1] : c[1] - c[0]
        let right = i < c.count - 1 ? c[i + 1] - c[i] : left
        return (left + right) / 2
    }

    private func go(_ target: Int) {
        guard !items.isEmpty else { return }
        let clamped = min(max(target, 0), items.count - 1)
        withAnimation(Motion.pick(Motion.bounce)) { position = Double(clamped) }
        if selection != items[clamped].id { selection = items[clamped].id }
    }

    private func arrow(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.background).shadow(color: .black.opacity(0.18), radius: 2, y: 1))
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0 : 0.85)
        .disabled(disabled)
    }
}

/// 转盘每一项的位置：中间的最大，离得越远越小越淡；拖动、换选中时逐帧算（不是首尾两帧插值）。
struct CarouselEffect: ViewModifier, Animatable {
    /// 两边那台缩到多大
    static let sideScale: CGFloat = 0.6

    var position: Double
    let index: Int
    let centers: [CGFloat]

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    /// 转到 position（可以是小数）时，中间那一点在横线上的位置
    private func center(at position: Double) -> CGFloat {
        guard let last = centers.indices.last else { return 0 }
        if position <= 0 { return centers[0] + CGFloat(position) * (centers.count > 1 ? centers[1] - centers[0] : 0) }
        if position >= Double(last) { return centers[last] + CGFloat(position - Double(last)) * (last > 0 ? centers[last] - centers[last - 1] : 0) }
        let low = Int(position.rounded(.down))
        let t = CGFloat(position - Double(low))
        return centers[low] + (centers[low + 1] - centers[low]) * t
    }

    func body(content: Content) -> some View {
        let a = abs(Double(index) - position)
        let x = (centers.indices.contains(index) ? centers[index] : 0) - center(at: position)
        let scale = Motion.reduceMotion ? (a < 0.5 ? 1 : Self.sideScale) : 1 - min(a, 1.6) * (1 - Self.sideScale)
        content
            .scaleEffect(scale)
            .offset(x: x)
            .opacity(a > 2.6 ? 0 : 1 - min(a, 2.2) * 0.42)
            .zIndex(-a)
            .allowsHitTesting(a < 2.6)
    }
}

/// 「认出来了」：外圈亮两下。
struct PingRing: View {
    @State private var expand = false

    var body: some View {
        RoundedRectangle(cornerRadius: 40, style: .continuous)
            .stroke(Brand.coralTop, lineWidth: 2)
            .scaleEffect(expand ? 1.2 : 0.85)
            .opacity(expand ? 0 : 0.85)
            .onAppear { withAnimation(.easeOut(duration: 1.1).repeatCount(2, autoreverses: false)) { expand = true } }
            .allowsHitTesting(false)
    }
}

/// 触控板左右滑：只接滚动事件，点击和拖动照常交给下面的 SwiftUI。滑过一定距离走一格，一次手势只走一格。
struct ScrollWheelCatcher: NSViewRepresentable {
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> WheelView {
        let view = WheelView()
        view.onStep = onStep
        return view
    }

    func updateNSView(_ view: WheelView, context: Context) { view.onStep = onStep }

    final class WheelView: NSView {
        var onStep: ((Int) -> Void)?
        private var accumulated: CGFloat = 0
        private var locked = false
        private var unlock: DispatchWorkItem?

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }

        override func scrollWheel(with event: NSEvent) {
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
                super.scrollWheel(with: event)
                return
            }
            if event.phase == .began { accumulated = 0; locked = false }
            guard !locked else { return }
            accumulated += event.scrollingDeltaX
            guard abs(accumulated) > (event.hasPreciseScrollingDeltas ? 36 : 1) else { return }
            onStep?(accumulated < 0 ? 1 : -1)
            accumulated = 0
            locked = true
            unlock?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.locked = false }
            unlock = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }
}

// MARK: - 分组列表

/// 转盘右边的列表：按组分，点一行转盘就转过去；选中那行的底色滑过去。
struct GroupedPickerList<Item: Identifiable, Row: View>: View where Item.ID: Hashable {
    let items: [Item]
    let group: (Item) -> String
    @Binding var selection: Item.ID?
    @ViewBuilder let row: (Item, Bool) -> Row
    @Namespace private var namespace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                        if offset == 0 || group(items[offset - 1]) != group(item) {
                            Text(group(item)).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                .padding(.leading, 8).padding(.top, offset == 0 ? 0 : 10).padding(.bottom, 2)
                        }
                        let selected = selection == item.id
                        Button {
                            withAnimation(Motion.pick(Motion.bounce)) { selection = item.id }
                        } label: {
                            row(item, selected)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .background {
                                    if selected {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Brand.coralTop.opacity(0.15))
                                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.coralTop.opacity(0.45), lineWidth: 1))
                                            .matchedGeometryEffect(id: "selection", in: namespace)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.trailing, 4)
            }
            .onChange(of: selection) { _, new in
                guard let new else { return }
                withAnimation(Motion.pick(Motion.smooth)) { proxy.scrollTo(new, anchor: .center) }
            }
            .onAppear { if let selection { proxy.scrollTo(selection, anchor: .center) } }
        }
    }
}

/// 列表里的一行：缩略图、名字、小字、选中的勾。
struct PickerRow: View {
    let art: DeviceDiagram
    let title: String
    let detail: String
    var dimmed = false
    var isNew = false
    let selected: Bool
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: 10) {
            DeviceFigure(diagram: art, showsSymbols: false)
                .padding(4)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
                .opacity(dimmed ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).opacity(dimmed ? 0.55 : 1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let trailing { trailing }
            if isNew {
                Text("新").font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Brand.coralBottom))
                    .transition(.scale.combined(with: .opacity))
            }
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.white, Brand.coralBottom)
                .scaleEffect(selected ? 1 : 0.4)
                .opacity(selected ? 1 : 0)
        }
    }
}

// MARK: - 控制设备

/// 控制设备的转盘 + 列表。转到连着的设备就选它；转到没连上的型号只是看看，告诉用户怎么连。
struct ControlDevicePicker: View {
    @Environment(AppModel.self) private var model
    /// 引导里按一下实物就认出来（引擎同时听所有设备）
    var identifies = false
    var stageWidth: CGFloat = 330
    /// 转到哪一项（包括没连上的型号）告诉外面，引导的「继续」按钮跟着变
    var onFocus: ((PickerDevice?) -> Void)?
    @State private var focusID: String?
    @State private var pinged: String?
    @State private var toast: String?
    @State private var newIDs: Set<String> = []
    @State private var knownIDs: Set<String> = []

    var body: some View {
        let items = model.pickerDevices
        HStack(alignment: .top, spacing: 22) {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    Carousel(items: items, selection: $focusID, spacing: stageWidth * 0.43, itemSize: CGSize(width: stageWidth * 0.56, height: 200), pinged: pinged,
                             widthOf: { min(stageWidth * 0.56, 200 * CGFloat($0.art.width / $0.art.height)) }) { item, _ in
                        DeviceFigure(diagram: item.art)
                            .shadow(color: .black.opacity(0.25), radius: 10, y: 8)
                            .saturation(item.connected ? 1 : 0)
                            .opacity(item.connected ? 1 : 0.55)
                    }
                    if let toast {
                        ToastPill(text: toast).padding(.top, 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(maxHeight: .infinity)
                meta(items.first { $0.id == focusID })
            }
            .frame(width: stageWidth)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))

            GroupedPickerList(items: items, group: { $0.category.title }, selection: $focusID) { item, selected in
                PickerRow(art: item.art, title: item.name, detail: item.connected ? item.detail : "没连上", dimmed: !item.connected,
                          isNew: newIDs.contains(item.id), selected: selected)
            }
        }
        .onAppear {
            model.refreshDevices()
            focusID = model.config.controlDeviceIDs.first ?? items.first(where: \.connected)?.id
            knownIDs = Set(items.map(\.id))
            if identifies && !UIPreview.isRendering { model.startIdentifying { device in identified(device) } }
        }
        .onDisappear { if identifies { model.stopIdentifying() } }
        .onChange(of: focusID) { _, new in
            let item = items.first { $0.id == new }
            onFocus?(item)
            guard let item, item.connected, let device = item.device else { return }
            if model.config.controlDeviceIDs != [device.id] { model.selectControlDevice(device.id) }
        }
        .onChange(of: items.map(\.id)) { _, ids in
            // 新连上的设备：列表里带一个「新」，转盘直接转过去
            let appeared = Set(ids).subtracting(knownIDs).filter { !$0.hasPrefix("known:") }
            knownIDs = Set(ids)
            guard let first = appeared.first else { return }
            withAnimation(Motion.pick(Motion.bounce)) { newIDs.formUnion(appeared) }
            focusID = first
            showToast("新连上 · \(items.first { $0.id == first }?.name ?? "")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { withAnimation { newIDs.subtract(appeared) } }
        }
    }

    private func identified(_ device: ControlDevice) {
        guard let item = model.pickerDevices.first(where: { $0.id == device.id }) else { return }
        focusID = item.id
        pinged = nil
        DispatchQueue.main.async { pinged = item.id }
        showToast("认出来了 · \(item.name)")
    }

    private func showToast(_ text: String) {
        withAnimation(Motion.pick(Motion.bounce)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            if toast == text { withAnimation(Motion.pick(Motion.exit)) { toast = nil } }
        }
    }

    @ViewBuilder
    private func meta(_ item: PickerDevice?) -> some View {
        VStack(spacing: 3) {
            Text(item?.name ?? "还没有设备")
                .font(.system(size: 17, weight: .bold))
                .lineLimit(1)
                .id(item?.id)
                .transition(.push(from: .trailing))
            HStack(spacing: 5) {
                Circle().fill(item?.connected == true ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                if let item, item.connected {
                    Text(item.id == model.config.controlDeviceIDs.first ? "正在用" : "已连上")
                    Text("·")
                    Text(item.detail).lineLimit(1)
                } else {
                    // 无线麦作为蓝牙收音设备连上就会出现，不用按键认
                    Text(item?.category == .mic ? "没连上 · 打开它，在系统设置 › 蓝牙 里连上" : "没连上 · 在系统设置 › 蓝牙 里配对，再按一下它的键").lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            PageDots(count: model.pickerDevices.count, index: model.pickerDevices.firstIndex { $0.id == item?.id } ?? 0)
                .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .animation(Motion.pick(Motion.bounce), value: item?.id)
    }
}

/// 转盘底下的小点：当前那个拉长。
struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(i == index ? AnyShapeStyle(Brand.coralBottom) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .frame(width: i == index ? 14 : 5, height: 5)
            }
        }
        .animation(Motion.pick(Motion.bounce), value: index)
    }
}

/// 顶上冒出来的小胶囊：「认出来了 · 小米遥控器 2」
struct ToastPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 16, height: 16).background(Circle().fill(Brand.coralBottom))
            Text(text).font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.background).shadow(color: .black.opacity(0.16), radius: 8, y: 3))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

// MARK: - 收音设备

/// 收音设备的转盘 + 列表。对着选中的麦说话，外面一圈圈的光跟着音量跳。
struct MicPicker: View {
    @Environment(AppModel.self) private var model
    var stageWidth: CGFloat = 330
    @State private var focusID: String?
    @State private var meter = MicMeter()

    var body: some View {
        let items = model.pickerMics
        HStack(alignment: .top, spacing: 22) {
            VStack(spacing: 0) {
                Carousel(items: items, selection: $focusID, spacing: stageWidth * 0.46, itemSize: CGSize(width: stageWidth * 0.56, height: 180),
                         widthOf: { min(stageWidth * 0.56, ($0.art.id == PickerArt.laptop.id ? 110 : 140) * CGFloat($0.art.width / $0.art.height)) }) { item, center in
                    ZStack {
                        if center { SoundRings(level: meter.level) }
                        DeviceFigure(diagram: item.art, showsSymbols: false)
                            .frame(maxHeight: item.art.id == PickerArt.laptop.id ? 110 : 140)
                            .shadow(color: .black.opacity(0.22), radius: 9, y: 7)
                    }
                }
                .frame(maxHeight: .infinity)
                VStack(spacing: 3) {
                    let item = items.first { $0.id == focusID }
                    Text(item?.name ?? "").font(.system(size: 17, weight: .bold)).lineLimit(1)
                        .id(item?.id).transition(.push(from: .trailing))
                    HStack(spacing: 6) {
                        Text(item?.detail ?? "")
                        if let warning = item?.warning { Chip(text: warning, warn: true) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    PageDots(count: items.count, index: items.firstIndex { $0.id == focusID } ?? 0).padding(.top, 4)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
                .animation(Motion.pick(Motion.bounce), value: focusID)
            }
            .frame(width: stageWidth)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))

            GroupedPickerList(items: items, group: \.group, selection: $focusID) { item, selected in
                // 音量看左边转盘上的光圈，列表里不再放像信号格的小竖条
                PickerRow(art: item.art, title: item.name, detail: item.detail + (item.warning == nil ? "" : " · 通话音质"), selected: selected)
            }
        }
        .onAppear {
            model.refreshDevices()
            focusID = model.config.voice.micUID ?? "default"
        }
        .onChange(of: focusID) { _, new in
            let uid = new == "default" ? nil : new
            if model.config.voice.micUID != uid { model.update { $0.voice.micUID = uid } }
            meter.start(uid: uid, after: 0.5)
        }
        .onDisappear { meter.stop() }
    }
}

/// 收音设备外面跟着音量跳的光：中间一团，声音大时往外扩一圈。
struct SoundRings: View {
    let level: Float
    @State private var rings: [UUID] = []
    @State private var lastRing = Date.distantPast

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Brand.coralTop.opacity(0.28), .clear], center: .center, startRadius: 0, endRadius: 80))
                .frame(width: 160, height: 160)
                .scaleEffect(0.55 + CGFloat(level) * 0.75)
                .animation(.linear(duration: 0.09), value: level)
            ForEach(rings, id: \.self) { id in
                ExpandingRing().id(id)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: level) { _, new in
            guard new > 0.5, Date().timeIntervalSince(lastRing) > 0.26, !Motion.reduceMotion else { return }
            lastRing = Date()
            let id = UUID()
            rings.append(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { rings.removeAll { $0 == id } }
        }
    }
}

private struct ExpandingRing: View {
    @State private var go = false

    var body: some View {
        Circle().stroke(Brand.coralTop, lineWidth: 1.5)
            .frame(width: 160, height: 160)
            .scaleEffect(go ? 1.55 : 0.6)
            .opacity(go ? 0 : 0.7)
            .onAppear { withAnimation(.easeOut(duration: 0.95)) { go = true } }
    }
}

/// 只量音量、不录下来：选收音设备时让外圈的光跟着跳。转盘停稳半秒才开麦，免得滑过去时把每个蓝牙耳机都切到通话模式。
@MainActor
@Observable
final class MicMeter {
    private(set) var level: Float = 0
    @ObservationIgnored private var capture: AudioCapture?
    @ObservationIgnored private var pending: DispatchWorkItem?

    func start(uid: String?, after delay: Double = 0) {
        stop()
        guard MicrophoneAccess.status == .authorized, !UIPreview.isRendering else { return }
        let work = DispatchWorkItem { [weak self] in self?.open(uid: uid) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func open(uid: String?) {
        let id = uid.flatMap { uid in AudioDevices.inputs().first { $0.uid == uid }?.id }
        let capture = AudioCapture()
        capture.onBuffer = { [weak self] buffer in
            let value = Self.loudness(buffer)
            DispatchQueue.main.async {
                guard let self else { return }
                self.level = self.level * 0.45 + value * 0.55
            }
        }
        do {
            try capture.start(deviceID: id)
            self.capture = capture
        } catch {
            log.error("量音量开麦失败：\(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        capture?.stop()
        capture = nil
        level = 0
    }

    /// 均方根换成 0…1：-55 dB 以下算没声音，-10 dB 算满。
    nonisolated static func loudness(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<frames { sum += data[i] * data[i] }
        } else if let data = buffer.int16ChannelData?[0] {
            for i in 0..<frames { let v = Float(data[i]) / 32768; sum += v * v }
        } else {
            return 0
        }
        let rms = sqrt(sum / Float(frames))
        let db = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (db + 55) / 45))
    }
}
