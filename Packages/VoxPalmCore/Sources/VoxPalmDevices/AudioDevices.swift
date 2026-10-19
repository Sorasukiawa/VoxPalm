import CoreAudio
import Foundation

/// 一台 CoreAudio 设备（输入、输出或两者都有）。
public struct AudioDeviceInfo: Codable, Hashable, Identifiable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let manufacturer: String?
    public let transport: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let nominalSampleRate: Double
    /// 每项是 [最小, 最大]；大多数设备两者相等。
    public let availableSampleRates: [[Double]]
    public let inputStreamFormat: StreamFormat?
    public let isDefaultInput: Bool
    public let isDefaultOutput: Bool
    public let isDefaultSystemOutput: Bool
    public let isRunningSomewhere: Bool

    public struct StreamFormat: Codable, Hashable, Sendable {
        public let sampleRate: Double
        public let channels: Int
        public let bitsPerChannel: Int
        public let formatID: String
    }

    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }
    public var isBluetooth: Bool { transport == "Bluetooth" || transport == "Bluetooth LE" }

    /// 蓝牙收音的大概协议。蓝牙耳麦只要开麦就会切到通话协议（HFP），采样率掉到 8–32 kHz。
    public var bluetoothProfileGuess: String? {
        guard isBluetooth else { return nil }
        guard hasInput else { return nominalSampleRate >= 44_100 ? "A2DP 立体声（只放音）" : "仅输出，采样率偏低" }
        switch nominalSampleRate {
        case ..<8_001: return "HFP 窄带（CVSD 8 kHz，电话音质）"
        case ..<16_001: return "HFP 宽带（mSBC 16 kHz）"
        case ..<32_001: return "HFP 超宽带（约 \(Int(nominalSampleRate / 1000)) kHz）"
        default: return "高采样率收音（\(Int(nominalSampleRate / 1000)) kHz，可能是 LE Audio 或厂商方案）"
        }
    }

    /// 蓝牙收音是否掉进了 HFP 低采样率（≤ 32 kHz）。
    public var isLowRateBluetoothInput: Bool { isBluetooth && hasInput && nominalSampleRate <= 32_000 }
}

public enum AudioDevices {
    public static func all() -> [AudioDeviceInfo] {
        let defaultIn = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let defaultOut = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let systemOut = defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
        return deviceIDs().compactMap { id in
            info(for: id, defaultIn: defaultIn, defaultOut: defaultOut, systemOut: systemOut)
        }
    }

    public static func inputs() -> [AudioDeviceInfo] { all().filter(\.hasInput) }

    public static func device(id: AudioObjectID) -> AudioDeviceInfo? {
        info(for: id,
             defaultIn: defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
             defaultOut: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
             systemOut: defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice))
    }

    public static func device(uid: String) -> AudioDeviceInfo? { all().first { $0.uid == uid } }

    public static var defaultInputID: AudioObjectID { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }
    public static var defaultOutputID: AudioObjectID { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    /// 改系统默认收音设备。只在语音会话里临时切换、结束后切回时用。
    @discardableResult
    public static func setDefaultInput(_ id: AudioObjectID) -> Bool {
        var value = id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value) == noErr
    }

    static func deviceIDs() -> [AudioObjectID] {
        CoreAudioProperty.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioObjectID.self)
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        CoreAudioProperty.value(AudioObjectID(kAudioObjectSystemObject), selector, default: AudioObjectID(kAudioObjectUnknown))
    }

    static func info(for id: AudioObjectID, defaultIn: AudioObjectID, defaultOut: AudioObjectID, systemOut: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = CoreAudioProperty.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let rates = CoreAudioProperty.array(id, kAudioDevicePropertyAvailableNominalSampleRates, of: AudioValueRange.self)
        return AudioDeviceInfo(
            id: id,
            uid: uid,
            name: CoreAudioProperty.string(id, kAudioObjectPropertyName) ?? uid,
            manufacturer: CoreAudioProperty.string(id, kAudioObjectPropertyManufacturer),
            transport: transportName(CoreAudioProperty.value(id, kAudioDevicePropertyTransportType, default: UInt32(0))),
            inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
            nominalSampleRate: CoreAudioProperty.value(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0)),
            availableSampleRates: rates.map { [$0.mMinimum, $0.mMaximum] },
            inputStreamFormat: inputFormat(id),
            isDefaultInput: id == defaultIn,
            isDefaultOutput: id == defaultOut,
            isDefaultSystemOutput: id == systemOut,
            isRunningSomewhere: CoreAudioProperty.value(id, kAudioDevicePropertyDeviceIsRunningSomewhere, default: UInt32(0)) != 0
        )
    }

    static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func inputFormat(_ id: AudioObjectID) -> AudioDeviceInfo.StreamFormat? {
        let streams = CoreAudioProperty.array(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioStreamID.self)
        guard let stream = streams.first else { return nil }
        let format: AudioStreamBasicDescription = CoreAudioProperty.value(stream, kAudioStreamPropertyPhysicalFormat, default: AudioStreamBasicDescription())
        guard format.mSampleRate > 0 else { return nil }
        return .init(sampleRate: format.mSampleRate, channels: Int(format.mChannelsPerFrame), bitsPerChannel: Int(format.mBitsPerChannel), formatID: fourCC(format.mFormatID))
    }

    static func transportName(_ code: UInt32) -> String {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "Continuity (wired)"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity (wireless)"
        case kAudioDeviceTransportTypeUnknown: return "Unknown"
        default: return fourCC(code)
        }
    }

    static func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let text = String(bytes: bytes, encoding: .ascii) ?? ""
        return text.allSatisfy({ $0.isASCII && !$0.isWhitespace || $0 == " " }) ? text : String(format: "0x%08X", code)
    }
}

/// CoreAudio 属性读取的小工具。
enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, default fallback: T) -> T {
        var address = address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(id, &address) else { return fallback }
        var result = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &result) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? result : fallback
    }

    static func array<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of _: T.Type) -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectHasProperty(id, &address),
              AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
