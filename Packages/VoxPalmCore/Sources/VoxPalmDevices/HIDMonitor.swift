import Foundation
import IOKit
import IOKit.hid

public struct HIDUsagePair: Codable, Hashable, Sendable {
    public let page: Int
    public let usage: Int

    public init(page: Int, usage: Int) {
        self.page = page
        self.usage = usage
    }

    public var label: String { HIDUsageNames.describe(page: page, usage: usage) }
}

/// 一台 HID 设备的基本信息。不含序列号：蓝牙设备的序列号常常就是蓝牙地址。
public struct HIDDeviceInfo: Codable, Hashable, Identifiable, Sendable {
    public let id: UInt64
    public let vendorID: Int?
    public let productID: Int?
    public let versionNumber: Int?
    public let product: String?
    public let manufacturer: String?
    public let transport: String?
    public let primaryUsagePage: Int?
    public let primaryUsage: Int?
    public let usagePairs: [HIDUsagePair]
    public let isBuiltIn: Bool
    public let maxInputReportSize: Int?

    public var displayName: String { product ?? manufacturer ?? "未命名设备" }

    public var vendorProduct: String {
        String(format: "0x%04X:0x%04X", vendorID ?? 0, productID ?? 0)
    }

    public var kinds: [String] {
        var seen = Set<String>()
        return usagePairs.map { HIDUsageNames.deviceKind(page: $0.page, usage: $0.usage) }.filter { seen.insert($0).inserted }
    }

    /// 同一个物理设备常被系统拆成好几个 HID 接口（键盘、媒体键、厂商自定义），用这个把它们归到一起。
    public var physicalKey: String { "\(vendorProduct)|\(product ?? "")|\(transport ?? "")" }
}

public enum HIDAccess {
    /// 输入监控权限：读键盘类设备、监听系统键盘事件都要它。
    public static var isGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    public static var isDenied: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied
    }

    /// 没决定过时会弹系统授权框；已经拒绝过只能去「系统设置 → 隐私与安全性 → 输入监控」里打开。
    @discardableResult
    public static func request() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}

/// 只监听、不独占地读取所有 HID 设备的输入。回调都在主线程。
public final class HIDMonitor {
    public struct ValueEvent: Sendable {
        public let device: HIDDeviceInfo
        public let time: Double
        public let usagePage: Int
        public let usage: Int
        public let value: Int
        public let logicalMin: Int
        public let logicalMax: Int
        public let isRelative: Bool
        public let isButtonLike: Bool
        public let reportID: Int

        public var usageLabel: String { HIDUsageNames.describe(page: usagePage, usage: usage) }
    }

    public struct ReportEvent: Sendable {
        public let device: HIDDeviceInfo
        public let time: Double
        public let reportID: Int
        public let bytes: [UInt8]

        public var hex: String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
    }

    public enum DeviceChange: Sendable {
        case added(HIDDeviceInfo)
        case removed(HIDDeviceInfo)
    }

    public var onValue: ((ValueEvent) -> Void)?
    public var onReport: ((ReportEvent) -> Void)?
    public var onDeviceChange: ((DeviceChange) -> Void)?
    /// 只对返回 true 的设备上报输入；不设就是全部。
    public var deviceFilter: ((HIDDeviceInfo) -> Bool)?
    /// 是否记录原始输入报告（探针用；App 只需要解析后的值）。
    public var recordsRawReports = false

    public private(set) var openResult: IOReturn = kIOReturnSuccess

    private let manager: IOHIDManager
    private var devicesByID: [UInt64: HIDDeviceInfo] = [:]
    private var reportBuffers: [UInt64: UnsafeMutablePointer<UInt8>] = [:]
    private var running = false

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
    }

    deinit {
        stop()
    }

    /// 当前连着的全部 HID 设备（含内置键盘、触控板）。
    public static func snapshot() -> [HIDDeviceInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return set.map(Self.info(for:)).sorted { ($0.isBuiltIn ? 1 : 0, $0.displayName, $0.id) < ($1.isBuiltIn ? 1 : 0, $1.displayName, $1.id) }
    }

    public var devices: [HIDDeviceInfo] {
        devicesByID.values.sorted { $0.id < $1.id }
    }

    public func start() {
        guard !running else { return }
        running = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().deviceAdded(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().valueArrived(value)
        }, context)
        // 启动前已经连着的设备不算「新连上」。
        if let existing = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in existing {
                let info = Self.info(for: device)
                devicesByID[info.id] = info
            }
        }
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // kIOHIDOptionsTypeNone：不独占，设备照常把输入发给系统和别的 App。
        openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func stop() {
        guard running else { return }
        running = false
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        if let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in set {
                if let buffer = reportBuffers[Self.registryID(of: device)] {
                    IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, 0, nil, nil)
                }
            }
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        for buffer in reportBuffers.values { buffer.deallocate() }
        reportBuffers.removeAll()
        devicesByID.removeAll()
    }

    // MARK: - 回调

    private func deviceAdded(_ device: IOHIDDevice) {
        let info = Self.info(for: device)
        let isNew = devicesByID[info.id] == nil
        devicesByID[info.id] = info
        if recordsRawReports, reportBuffers[info.id] == nil, deviceFilter?(info) ?? true {
            let size = max(info.maxInputReportSize ?? 64, 1)
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            reportBuffers[info.id] = buffer
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, size, { context, _, sender, _, reportID, report, length, timeStamp in
                guard let context, let sender else { return }
                let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
                    .reportArrived(device: device, reportID: Int(reportID), bytes: bytes, timeStamp: timeStamp)
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        if isNew { onDeviceChange?(.added(info)) }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let id = Self.registryID(of: device)
        guard let info = devicesByID.removeValue(forKey: id) else { return }
        // 设备已经拔掉，缓冲区不会再被写入，可以安全释放。
        reportBuffers.removeValue(forKey: id)?.deallocate()
        onDeviceChange?(.removed(info))
    }

    private func reportArrived(device: IOHIDDevice, reportID: Int, bytes: [UInt8], timeStamp: UInt64) {
        let id = Self.registryID(of: device)
        guard let info = devicesByID[id] else { return }
        onReport?(ReportEvent(device: info, time: MonotonicClock.seconds(machTime: timeStamp), reportID: reportID, bytes: bytes))
    }

    private func valueArrived(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        let id = Self.registryID(of: device)
        let info = devicesByID[id] ?? Self.info(for: device)
        guard deviceFilter?(info) ?? true else { return }
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        // 键盘数组里的占位用途（无按键、按键过多）没有意义，丢掉。
        if page == 0x07 && (usage <= 0x03 || usage == 0xFFFF_FFFF) { return }
        if usage == 0xFFFF_FFFF { return }
        // 超过 8 字节的值（厂商自定义数据块）读整数会出错，这类数据看原始报告。
        guard IOHIDValueGetLength(value) <= 8 else { return }
        let integer = IOHIDValueGetIntegerValue(value)
        let min = IOHIDElementGetLogicalMin(element)
        let max = IOHIDElementGetLogicalMax(element)
        let type = IOHIDElementGetType(element)
        let buttonPages: Set<Int> = [0x07, 0x09, 0x0B, 0x0C]
        let isButtonLike = type == kIOHIDElementTypeInput_Button
            || (buttonPages.contains(page) && min == 0 && max == 1)
            || (page == 0x0C && !IOHIDElementIsRelative(element) && min == 0 && max <= 1)
        onValue?(ValueEvent(
            device: info,
            time: MonotonicClock.seconds(machTime: IOHIDValueGetTimeStamp(value)),
            usagePage: page,
            usage: usage,
            value: integer,
            logicalMin: min,
            logicalMax: max,
            isRelative: IOHIDElementIsRelative(element),
            isButtonLike: isButtonLike,
            reportID: Int(IOHIDElementGetReportID(element))
        ))
    }

    // MARK: - 读设备属性

    static func registryID(of device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }

    static func info(for device: IOHIDDevice) -> HIDDeviceInfo {
        func int(_ key: String) -> Int? { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue }
        func string(_ key: String) -> String? { IOHIDDeviceGetProperty(device, key as CFString) as? String }
        let pairs = (IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? []).compactMap { pair -> HIDUsagePair? in
            guard let page = (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue,
                  let usage = (pair[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue else { return nil }
            return HIDUsagePair(page: page, usage: usage)
        }
        let primaryPage = int(kIOHIDPrimaryUsagePageKey)
        let primaryUsage = int(kIOHIDPrimaryUsageKey)
        let transport = string(kIOHIDTransportKey)
        let builtIn = (IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? NSNumber)?.boolValue ?? false
        return HIDDeviceInfo(
            id: registryID(of: device),
            vendorID: int(kIOHIDVendorIDKey),
            productID: int(kIOHIDProductIDKey),
            versionNumber: int(kIOHIDVersionNumberKey),
            product: string(kIOHIDProductKey),
            manufacturer: string(kIOHIDManufacturerKey),
            transport: transport,
            primaryUsagePage: primaryPage,
            primaryUsage: primaryUsage,
            usagePairs: pairs.isEmpty ? [primaryPage.map { HIDUsagePair(page: $0, usage: primaryUsage ?? 0) }].compactMap { $0 } : pairs,
            isBuiltIn: builtIn || ["SPI", "FIFO", "SPMI"].contains(transport ?? ""),
            maxInputReportSize: int(kIOHIDMaxInputReportSizeKey)
        )
    }
}
