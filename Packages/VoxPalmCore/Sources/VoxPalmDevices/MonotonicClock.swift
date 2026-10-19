import Darwin

/// 统一的单调时钟（开机后经过的秒数，不含睡眠），HID 时间戳和到达时间都换算到这里，方便跨通道比较先后。
public enum MonotonicClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func seconds(machTime: UInt64) -> Double {
        Double(machTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    public static func now() -> Double {
        seconds(machTime: mach_absolute_time())
    }
}
