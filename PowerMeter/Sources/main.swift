import Cocoa
import SwiftUI
import IOKit
import IOKit.ps
import ServiceManagement

// MARK: - Palette
//
// The popover is light regardless of the system setting, and NSPopover's own chrome
// is pinned to .aqua alongside it so the frame cannot stay dark around a light body.
// Colours live here rather than inline so the next change is one edit, not eighty.
enum UI {
    static let background   = Color(white: 0.97)
    static let card         = Color.white
    static let cardBorder   = Color.black.opacity(0.12)
    static let edge         = Color.black.opacity(0.15)   // flow diagram's static lines
    static let chipIdle     = Color(white: 0.91)
    static let chipBorder   = Color.black.opacity(0.16)
    static let tabActive    = Color.white
    static let divider      = Color.black.opacity(0.10)
    static let neutralFill  = Color(white: 0.72)          // the calibrate button
    static let inset        = Color.black.opacity(0.06)   // preview pill behind text

    // Text. Black at a given opacity reads heavier than white does on dark, so these
    // are not a straight inversion of the values they replaced.
    static let text         = Color.black.opacity(0.88)
    static let textStrong   = Color.black.opacity(0.95)
    static func text(_ o: Double) -> Color { Color.black.opacity(min(0.92, o + 0.06)) }

    // Accents on a light ground: SwiftUI's stock green and orange are tuned for dark
    // backgrounds and wash out here, so text uses darker variants. Filled chips keep
    // the stock colours, since white on them still carries.
    static let good         = Color(red: 0.10, green: 0.52, blue: 0.22)
    static let warn         = Color(red: 0.78, green: 0.42, blue: 0.00)
    static let bad          = Color(red: 0.75, green: 0.15, blue: 0.12)
    static let cpuLine      = Color(red: 0.85, green: 0.45, blue: 0.05)
    static let battLine     = Color(red: 0.05, green: 0.50, blue: 0.55)
}

// MARK: - Power reading

struct PowerSnapshot {
    var systemW: Double = 0      // total Mac consumption (BatteryData.SystemPower)
    var adapterW: Double = 0     // power delivered by the wall adapter
    var batteryW: Double = 0     // signed: + charging into battery, - discharging
    var external: Bool = false   // adapter connected
    var charging: Bool = false
    var soc: Int = 0
    var adapterRatedW: Int = 0
    var timeToEmpty: Int = -1
    var timeToFull: Int = -1
    var valid: Bool = false
    // health / spec
    var designCap: Int = 0       // mAh
    var rawMaxCap: Int = 0       // mAh (current full capacity)
    var cycleCount: Int = 0
    var tempC: Double = 0        // °C
    var serial: String = ""
    var adapterVoltage: Double = 0  // V
    var adapterCurrent: Double = 0  // A
    var adapterDesc: String = ""
    var batteryVoltage: Double = 0  // V

    var live: Bool = false       // wattages came from SMC rather than the 60s IOKit snapshot

    // PowerTelemetryData — what the adapter draws vs what reaches the Mac
    var adapterInW: Double = 0   // SystemPowerIn: DC actually delivered
    var adapterLossW: Double = 0 // AdapterEfficiencyLoss: burned converting from wall AC
    var adapterInV: Double = 0
    var adapterInA: Double = 0
    // USB-PD profiles the adapter advertises, and which one was negotiated
    var pdProfiles: [PDProfile] = []
    var pdActiveIndex: Int = -1
    // ChargerData
    var notChargingReason: UInt64 = 0
    var chargerInhibit: UInt64 = 0
    var thermalLimitedSec: Int = 0
    // Per-cell readings
    var cellVoltages: [Double] = []  // V
    var cellRa: [Int] = []           // internal resistance, unitless SMC scale
    // Today's charge window — shows whether a charge limit is actually holding
    var dailyMaxSoc: Int = -1
    var dailyMinSoc: Int = -1
    // LifetimeData: extremes the pack has seen since it was built
    var lifeHours: Int = 0
    var lifeMaxTempC: Double = 0
    var lifeMinTempC: Double = 0
    var lifeAvgTempC: Double = 0
    var lifeMaxChargeA: Double = 0
    var lifeMaxDischargeA: Double = 0
    var lifeMaxPackV: Double = 0
    var lifeMinPackV: Double = 0
    // Fault flags
    var permanentFailure: Int = 0
    var cellDisconnects: Int = 0

    var healthPct: Int { designCap > 0 ? Int((Double(rawMaxCap) / Double(designCap) * 100).rounded()) : 0 }
    var condition: String { healthPct >= 80 ? "정상" : (healthPct >= 60 ? "양호" : "서비스 권장") }

    /// Wall draw estimate: what reaches the Mac plus what the adapter wastes.
    var wallW: Double { adapterInW + adapterLossW }
    var adapterEfficiency: Double? {
        wallW > 0.1 ? adapterInW / wallW : nil
    }
    var activePD: PDProfile? { pdProfiles.first { $0.index == pdActiveIndex } }

    /// Spread between the highest and lowest cell, in millivolts. Grows under load
    /// as the cell with the highest internal resistance sags furthest, so it only
    /// means much at rest.
    var cellSpreadMV: Int? {
        guard let hi = cellVoltages.max(), let lo = cellVoltages.min(), cellVoltages.count > 1 else { return nil }
        return Int(((hi - lo) * 1000).rounded())
    }

    // Only bit 7 is confirmed: it is set exactly when the adapter is absent and clear
    // when it is attached. Bit 55 was set in every state observed, charging or not, so
    // it carries no information here. Undecoded bits are surfaced as raw hex rather
    // than guessed at.
    var notChargingText: String? {
        guard external else { return nil }          // unplugged needs no explanation
        if charging { return nil }
        if thermalLimitedSec > 0 { return "온도 때문에 충전이 제한되고 있습니다" }
        if chargerInhibit != 0 { return String(format: "충전기가 억제됨 (0x%llx)", chargerInhibit) }
        let unknown = notChargingReason & ~((1 << 7) | (1 << 55))
        if unknown != 0 { return String(format: "충전 보류 중 (사유 0x%llx)", unknown) }
        return nil
    }
}

/// One SMC temperature sensor. Apple documents none of these key names, so the key
/// is shown as-is rather than given an invented label; only TB* is identified, and
/// only because its readings track the battery temperature IOKit reports.
struct TempReading: Identifiable {
    let key: String
    let c: Double
    var id: String { key }
    var isBattery: Bool { key.hasPrefix("TB") }

    /// Which part of the machine the key's prefix denotes. Only the family is claimed,
    /// never the individual sensor — the same key names a performance core on one chip
    /// and an efficiency core on the next, so "Tp4z is core 4" would be invention.
    /// The families themselves hold up: on this Mac the CPU ones run hottest, SSD sits
    /// in the middle and TB* lands where IOKit puts the battery.
    var family: String? {
        switch key.prefix(2) {
        case "TB": return "배터리"
        case "Tp": return "CPU 코어"
        case "Te": return "CPU 다이"
        case "Th": return "SoC 히트싱크"
        case "Ts": return "SSD"
        case "Tf": return "CPU 코어"
        case "Tg": return "GPU"
        default:   return nil
        }
    }

    /// Tp/Te/Tf. Tf carries the performance cores on M3, where Te holds only the
    /// efficiency ones — without it an M3 would report the cooler half as its CPU
    /// temperature. On an M2 Max the same prefix publishes a fixed 102.8°C instead,
    /// which the stuck-value filter removes, so covering both costs nothing.
    /// TC* is left out: it mixes hot and cool sensors, and TCMz reads identical to the
    /// hottest Tp anyway.
    var isCPU: Bool { key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("Tf") }
}

struct TempSample {
    let at: Date
    let cpu: Double
    let batt: Double
}

struct PDProfile: Identifiable {
    let index: Int
    let volts: Double
    let amps: Double
    var id: Int { index }
    var watts: Double { volts * amps }
    var label: String {
        let v = volts == volts.rounded() ? String(format: "%.0fV", volts) : String(format: "%.1fV", volts)
        return "\(v)/\(String(format: "%.1fA", amps))"
    }
}

// MARK: - SMC (live power)
//
// AppleSmartBattery only republishes every 60s — its UpdateTime advances in exact
// 60s steps and every field, wattages included, is byte-identical in between. The
// SMC keys behind those fields update continuously, and reading them needs no
// privileges. PSTR and PDTR were confirmed against IOKit by catching the moment it
// refreshes: both matched SystemPower and AdapterPower to three decimals.
//
// SMCKeyData_t is 80 bytes under C alignment, which Swift's struct layout does not
// reproduce, so requests are built as raw buffers at explicit offsets.
final class SMCReader {
    private enum Off {
        static let key = 0, dataSize = 28, dataType = 32, result = 40, data8 = 42, bytes = 48
        static let total = 80
    }
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdReadIndex: UInt8 = 8
    private static let cmdReadKeyInfo: UInt8 = 9
    private static let kernelIndex: UInt32 = 2
    private static let floatType = fourCC("flt ")

    private var conn: io_connect_t = 0
    private(set) var available = false
    // A key's size and type never change, but re-asking for them doubles the cost of
    // every read (0.40ms against 0.21ms measured). Enumeration runs off the main
    // thread, so the connection and the cache are both behind this lock.
    private let lock = NSLock()
    private var infoCache: [String: (size: UInt32, type: UInt32)] = [:]

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        available = IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS
    }
    deinit { if available { IOServiceClose(conn) } }

    private static func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for c in s.utf8 { r = (r << 8) + UInt32(c) }
        return r
    }
    private func put32(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        withUnsafeBytes(of: v) { for i in 0..<4 { b[off + i] = $0[i] } }
    }
    private func get32(_ b: [UInt8], _ off: Int) -> UInt32 {
        b[off..<off+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    private func call(_ input: inout [UInt8]) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        var output = [UInt8](repeating: 0, count: Off.total)
        var outSize = Off.total
        let kr = input.withUnsafeMutableBytes { ip in
            output.withUnsafeMutableBytes { op in
                IOConnectCallStructMethod(conn, Self.kernelIndex,
                                          ip.baseAddress, Off.total,
                                          op.baseAddress, &outSize)
            }
        }
        guard kr == KERN_SUCCESS, output[Off.result] == 0 else { return nil }
        return output
    }

    private func info(_ key: String) -> (size: UInt32, type: UInt32)? {
        lock.lock()
        if let hit = infoCache[key] { lock.unlock(); return hit }
        lock.unlock()
        var req = [UInt8](repeating: 0, count: Off.total)
        put32(&req, Off.key, Self.fourCC(key))
        req[Off.data8] = Self.cmdReadKeyInfo
        guard let meta = call(&req) else { return nil }
        let entry = (size: get32(meta, Off.dataSize), type: get32(meta, Off.dataType))
        lock.lock(); infoCache[key] = entry; lock.unlock()
        return entry
    }

    private func rawBytes(_ key: String, _ size: UInt32) -> [UInt8]? {
        var req = [UInt8](repeating: 0, count: Off.total)
        put32(&req, Off.key, Self.fourCC(key))
        put32(&req, Off.dataSize, size)
        req[Off.data8] = Self.cmdReadBytes
        guard let out = call(&req) else { return nil }
        return Array(out[Off.bytes..<Off.bytes + Int(min(size, 32))])
    }

    /// Reads a 4-byte `flt ` key. Returns nil if the key is absent or another type.
    func readFloat(_ key: String) -> Double? {
        guard available, let meta = info(key), meta.type == Self.floatType, meta.size >= 4,
              let b = rawBytes(key, meta.size), b.count >= 4 else { return nil }
        return Double(b[0..<4].withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
    }

    /// Reads a single-byte key such as the fan count.
    func readUInt8(_ key: String) -> Int? {
        guard available, let meta = info(key), meta.size >= 1,
              let b = rawBytes(key, meta.size), let first = b.first else { return nil }
        return Int(first)
    }

    /// Every key the SMC publishes. ~1500 entries and ~300ms, so callers run it once
    /// off the main thread and keep the result.
    func allKeys() -> [String] {
        guard available, let countMeta = info("#KEY"), let cb = rawBytes("#KEY", countMeta.size), cb.count >= 4
        else { return [] }
        let total = Int(UInt32(cb[0]) << 24 | UInt32(cb[1]) << 16 | UInt32(cb[2]) << 8 | UInt32(cb[3]))
        guard total > 0, total < 10_000 else { return [] }
        var keys: [String] = []
        keys.reserveCapacity(total)
        for i in 0..<total {
            var req = [UInt8](repeating: 0, count: Off.total)
            req[Off.data8] = Self.cmdReadIndex
            put32(&req, 44, UInt32(i))               // data32 sits at offset 44
            guard let out = call(&req) else { continue }
            let code = get32(out, Off.key)
            guard code != 0,
                  let name = String(bytes: [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                                            UInt8((code >> 8) & 0xff), UInt8(code & 0xff)],
                                    encoding: .ascii) else { continue }
            keys.append(name)
        }
        return keys
    }

    /// Fan speeds in RPM. Empty on fanless Macs, where the keys are absent entirely.
    func fanRPMs() -> [Double] {
        guard let n = readUInt8("FNum"), n > 0, n < 10 else { return [] }
        return (0..<n).compactMap { readFloat(String(format: "F%dAc", $0)) }
    }

    /// System draw and adapter supply, in watts. Nil unless *both* keys read, so a
    /// machine that publishes only one degrades to the IOKit snapshot rather than
    /// reporting a confident zero: a missing PDTR would otherwise look like an idle
    /// adapter while the battery is actually charging.
    func power() -> (system: Double, adapter: Double)? {
        guard let system = readFloat("PSTR"), let adapter = readFloat("PDTR") else { return nil }
        return (system, adapter)
    }
}

enum PowerReader {
    static func read() -> PowerSnapshot {
        var s = PowerSnapshot()
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return s }
        defer { IOObjectRelease(svc) }
        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = propsRef?.takeRetainedValue() as? [String: Any] else { return s }

        let amperage = (p["Amperage"] as? Int) ?? 0
        let voltage  = (p["Voltage"]  as? Int) ?? 0
        s.external   = (p["ExternalConnected"] as? Bool) ?? false
        s.charging   = (p["IsCharging"] as? Bool) ?? false
        s.soc        = (p["CurrentCapacity"] as? Int) ?? 0
        s.batteryW   = Double(amperage) * Double(voltage) / 1_000_000.0
        s.timeToEmpty = (p["TimeRemaining"] as? Int) ?? (p["AvgTimeToEmpty"] as? Int ?? -1)
        s.timeToFull  = (p["AvgTimeToFull"] as? Int) ?? -1

        if let bd = p["BatteryData"] as? [String: Any] {
            if let sp = bd["SystemPower"]  as? Double { s.systemW  = sp }
            else if let sp = bd["SystemPower"] as? Int { s.systemW = Double(sp) }
            if let ap = bd["AdapterPower"] as? Double { s.adapterW = ap }
            else if let ap = bd["AdapterPower"] as? Int { s.adapterW = Double(ap) }
        }
        if s.systemW == 0 {
            if !s.external { s.systemW = abs(s.batteryW) }
            else { s.systemW = max(0, s.adapterW - max(0, s.batteryW)) }
        }
        if let ad = p["AdapterDetails"] as? [String: Any] {
            s.adapterRatedW = (ad["Watts"] as? Int) ?? 0
            s.adapterVoltage = Double((ad["AdapterVoltage"] as? Int) ?? 0) / 1000.0
            s.adapterCurrent = Double((ad["Current"] as? Int) ?? 0) / 1000.0
            s.adapterDesc = (ad["Description"] as? String) ?? ""
        }
        if abs(s.adapterW) < 0.05 { s.adapterW = 0 }
        // health / spec
        s.designCap   = (p["DesignCapacity"] as? Int) ?? 0
        s.rawMaxCap   = (p["AppleRawMaxCapacity"] as? Int) ?? ((p["NominalChargeCapacity"] as? Int) ?? 0)
        s.cycleCount  = (p["CycleCount"] as? Int) ?? 0
        s.tempC       = Double((p["Temperature"] as? Int) ?? 0) / 100.0
        s.serial      = (p["Serial"] as? String) ?? ""
        s.batteryVoltage = Double(voltage) / 1000.0

        // Adapter conversion loss and true DC input. All mW / mV / mA.
        if let pt = p["PowerTelemetryData"] as? [String: Any] {
            s.adapterInW   = Double((pt["SystemPowerIn"] as? Int) ?? 0) / 1000.0
            s.adapterLossW = Double((pt["AdapterEfficiencyLoss"] as? Int) ?? 0) / 1000.0
            s.adapterInV   = Double((pt["SystemVoltageIn"] as? Int) ?? 0) / 1000.0
            s.adapterInA   = Double((pt["SystemCurrentIn"] as? Int) ?? 0) / 1000.0
        }
        // USB-PD menu is only published while an adapter is attached.
        if let raw = p["AppleRawAdapterDetails"] as? [[String: Any]], let ad = raw.first {
            s.pdActiveIndex = (ad["UsbHvcHvcIndex"] as? Int) ?? -1
            if let menu = ad["UsbHvcMenu"] as? [[String: Any]] {
                s.pdProfiles = menu.compactMap { e in
                    guard let i = e["Index"] as? Int,
                          let mv = e["MaxVoltage"] as? Int,
                          let ma = e["MaxCurrent"] as? Int else { return nil }
                    return PDProfile(index: i, volts: Double(mv) / 1000.0, amps: Double(ma) / 1000.0)
                }
            }
        }
        if let cd = p["ChargerData"] as? [String: Any] {
            s.notChargingReason = UInt64(bitPattern: Int64((cd["NotChargingReason"] as? Int) ?? 0))
            s.chargerInhibit    = UInt64(bitPattern: Int64((cd["ChargerInhibitReason"] as? Int) ?? 0))
            s.thermalLimitedSec = (cd["TimeChargingThermallyLimited"] as? Int) ?? 0
        }
        s.permanentFailure = (p["PermanentFailureStatus"] as? Int) ?? 0
        s.cellDisconnects  = (p["BatteryCellDisconnectCount"] as? Int) ?? 0
        if let bd = p["BatteryData"] as? [String: Any] {
            if let cv = bd["CellVoltage"] as? [Int] { s.cellVoltages = cv.map { Double($0) / 1000.0 } }
            if let ra = bd["WeightedRa"] as? [Int] { s.cellRa = ra }
            s.dailyMaxSoc = (bd["DailyMaxSoc"] as? Int) ?? -1
            s.dailyMinSoc = (bd["DailyMinSoc"] as? Int) ?? -1
            if let lt = bd["LifetimeData"] as? [String: Any] {
                s.lifeHours          = (lt["TotalOperatingTime"] as? Int) ?? 0
                s.lifeMaxTempC       = Double((lt["MaximumTemperature"] as? Int) ?? 0) / 10.0
                s.lifeMinTempC       = Double((lt["MinimumTemperature"] as? Int) ?? 0) / 10.0
                s.lifeAvgTempC       = Double((lt["AverageTemperature"] as? Int) ?? 0) / 10.0
                s.lifeMaxChargeA     = Double((lt["MaximumChargeCurrent"] as? Int) ?? 0) / 1000.0
                s.lifeMaxDischargeA  = Double(abs((lt["MaximumDischargeCurrent"] as? Int) ?? 0)) / 1000.0
                s.lifeMaxPackV       = Double((lt["MaximumPackVoltage"] as? Int) ?? 0) / 1000.0
                s.lifeMinPackV       = Double((lt["MinimumPackVoltage"] as? Int) ?? 0) / 1000.0
            }
        }
        s.valid = true
        return s
    }
}

// MARK: - State classification

enum PowerState {
    case battery     // unplugged: battery -> mac
    case idle        // plugged but adapter ~0, running off battery
    case charging    // adapter -> mac + adapter -> battery
    case boost       // adapter insufficient: adapter -> mac + battery -> mac
    case powering    // adapter -> mac, battery held
}

// MARK: - Model

final class PowerModel: ObservableObject {
    @Published var snap = PowerSnapshot()
    @Published var state: PowerState = .battery
    @Published var macHealthPct: Int? = nil    // macOS "성능 최대치" (system_profiler)
    @Published var macCondition: String = ""

    private var idleStreak = 0
    private let idleThreshold = 8   // ~16s: longer than the adapter-power populate lag
    private var timer: Timer?
    private var healthTimer: Timer?
    private var psSource: CFRunLoopSource?
    var onTick: (() -> Void)?

    // Live sensors. Reading all ~146 temperature keys costs 28ms, so the full sweep
    // runs on the slow cycle off the main thread and only the hottest few are polled
    // per tick (1.65ms). The hot set is re-picked each sweep so it follows the load.
    @Published var temps: [TempReading] = []
    @Published var fanRPMs: [Double] = []
    @Published var history: [Double] = []      // system watts, oldest first
    // CPU and battery temperature over the last hour. Trimmed by timestamp rather than
    // by sample count so the window stays an hour whatever the tick rate is set to.
    @Published var tempHistory: [TempSample] = []
    private let tempWindow: TimeInterval = 3600

    // The battery temperature every tab shows. SMC's first TB sensor reads within
    // 0.01°C of IOKit's VirtualTemperature, so it is the same measurement arriving
    // sooner; IOKit's own Temperature is a different point on the pack and sits ~4°C
    // lower. Reading one identified key keeps every tab on one number.
    @Published private(set) var batteryTempKey: String?
    /// Mean across the tracked CPU sensors. The hottest single core was the obvious
    /// choice and the wrong one: a core wakes, spikes and sleeps within a tick, so the
    /// maximum jumped up to 10°C between readings and the reported key changed with it.
    /// Measured over the same eight sensors, the mean moves 1.33°C a tick against the
    /// maximum's 3.39°C, and spans half the range — closer to what "CPU temperature"
    /// should mean anyway.
    @Published private(set) var cpuTempC: Double = 0
    @Published private(set) var cpuSensorCount: Int = 0

    static func plausible(_ c: Double) -> Bool { c > 15 && c < 110 }

    private var tempKeys: [String] = []
    private var watchKeys: [String] = []
    // Every CPU sensor, not a selection of them. Averaging the eight hottest sounded
    // cheaper but sampled the hot tail, so the figure sat well above the die and still
    // moved 1.89°C a tick; across all of them it moves 0.44°C and spans 2.9°C instead
    // of 12.9°C. Picking a spread-out subset is worse than either — it lands on
    // whichever sensors happen to be quiet and stops tracking load at all.
    // Costs ~16ms a tick on a 112-sensor M2 Max once key sizes are cached.
    private var cpuWatchKeys: [String] = []
    // Keys whose value was bit-identical across two sweeps. A threshold constant never
    // moves: an M2 Max publishes Tf46 at a fixed 102.8°C through idle, full load and
    // cooldown alike, and it would otherwise headline as the hottest sensor in red.
    // Only the battery is exempt — it is the one family cross-checked against IOKit,
    // and a resting pack legitimately holds one value. Everything else has to prove it
    // is alive, because a prefix means different things on different chips: Tf is a
    // performance core on M3 and a constant here.
    private var lastSweep: [String: Double] = [:]
    // Counted rather than latched: a key that starts moving again clears itself, so a
    // sensor that merely happened to hold still for one comparison is not lost forever.
    private var stuckCount: [String: Int] = [:]
    private let watchCount = 6
    private let historyCap = 300

    var maxTemp: TempReading? { temps.max { $0.c < $1.c } }
    /// How far back the temperature chart reaches, from the samples themselves.
    var tempHistorySpan: String {
        guard let first = tempHistory.first, let last = tempHistory.last, tempHistory.count > 1 else {
            return "최근 1시간"
        }
        let sec = Int(last.at.timeIntervalSince(first.at))
        if sec >= 3600 { return "최근 1시간" }
        if sec >= 60 { return "최근 \(sec / 60)분" }
        return "최근 \(sec)초"
    }

    /// How far back `history` reaches at the current tick rate.
    var historySpan: String {
        let sec = Int(Double(max(history.count - 1, 0)) * interval)
        return sec >= 60 ? "최근 \(sec / 60)분" : "최근 \(sec)초"
    }

    private let smc = SMCReader()
    // AppleSmartBattery republishes on a 60s cycle, so re-reading it every tick just
    // rebuilds the same 67-key dictionary. Capacity, cycles and health come from this
    // cached snapshot; only the wattages are refreshed per tick, from SMC.
    private var slowSnap = PowerSnapshot()
    private var lastSlowRead = Date.distantPast
    private var forceSlowRead = true
    private let slowInterval: TimeInterval = 55

    var chargeW: Double { max(0, snap.batteryW) }
    var dischargeW: Double { max(0, -snap.batteryW) }

    var interval: Double { max(1, (UserDefaults.standard.object(forKey: "refreshInterval") as? Double) ?? 2.0) }

    func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        sampleMacHealth()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in self?.sampleMacHealth() }

        // Instant, event-driven refresh the moment AC is plugged/unplugged or charging state changes.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            Unmanaged<PowerModel>.fromOpaque(context).takeUnretainedValue().onPowerSourceChange()
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            psSource = src
        }
    }

    // Fired by the OS on power-source changes. Re-read immediately, then a couple of
    // quick follow-ups to catch the wattage fields as they populate.
    private func onPowerSourceChange() {
        // Plug/unplug changes ExternalConnected and the adapter spec, so the cached
        // IOKit snapshot has to be rebuilt rather than waited out.
        forceSlowRead = true
        tick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.forceSlowRead = true; self?.tick()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.forceSlowRead = true; self?.tick()
        }
    }

    // Sweeps every temperature sensor to re-pick the hot set, reads the battery
    // sensors and the fans. ~28ms plus a one-time ~280ms key enumeration, so it all
    // happens off the main thread.
    private var sweeping = false
    private func sweepSensors() {
        guard smc.available, !sweeping else { return }
        sweeping = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if self.tempKeys.isEmpty {
                self.tempKeys = self.smc.allKeys().filter { $0.hasPrefix("T") }
            }
            func sample() -> [String: Double] {
                var out: [String: Double] = [:]
                for k in self.tempKeys {
                    if let v = self.smc.readFloat(k), Self.plausible(v) { out[k] = v }
                }
                return out
            }
            // The very first sweep compares against nothing, so constants would headline
            // in red until the next one a minute later. Take a second pass a few seconds
            // in to seed the comparison instead.
            var previous = self.lastSweep
            if previous.isEmpty {
                previous = sample()
                Thread.sleep(forTimeInterval: 5)
            }
            let sampled = sample()
            var readings = sampled.map { TempReading(key: $0.key, c: $0.value) }
            var counts = self.stuckCount
            for r in readings where !r.isBattery {
                counts[r.key] = (previous[r.key] == sampled[r.key]) ? (counts[r.key] ?? 0) + 1 : 0
            }
            let stuck = Set(counts.filter { $0.value >= 1 }.keys)
            // Battery is resolved from every reading; only ranking drops the stuck ones.
            let battKey = readings.filter(\.isBattery).map(\.key).sorted().first
            readings.removeAll { stuck.contains($0.key) }
            var hottest = readings.sorted { $0.c > $1.c }.prefix(self.watchCount).map(\.key)
            // Guarantee at least one CPU sensor is watched even if other parts run hotter,
            // so the CPU reading never goes blank.
            if !hottest.contains(where: { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }),
               let cpu = readings.filter(\.isCPU).max(by: { $0.c < $1.c })?.key {
                hottest.append(cpu)
            }
            // Lowest-numbered TB sensor, not an average across them: TB0T is the one
            // that matches IOKit's VirtualTemperature, and averaging in the cooler
            // TB2T would produce a number no other source reports.
            let fans = self.smc.fanRPMs()
            let cpuSet = readings.filter(\.isCPU).map(\.key)
            DispatchQueue.main.async {
                self.lastSweep = sampled
                self.stuckCount = counts
                if !cpuSet.isEmpty { self.cpuWatchKeys = cpuSet }
                self.watchKeys = hottest
                if let battKey { self.batteryTempKey = battKey }
                self.fanRPMs = fans
                self.sweeping = false
            }
        }
    }

    // Read macOS's official "Maximum Capacity %" + Condition (smoothed Apple metric).
    private func sampleMacHealth() {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPPowerDataType"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = nil
            do { try p.run() } catch { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            var pct: Int? = nil; var cond = ""
            for raw in out.split(separator: "\n") {
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("Maximum Capacity:") {
                    let v = t.replacingOccurrences(of: "Maximum Capacity:", with: "")
                        .replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
                    pct = Int(v)
                } else if t.hasPrefix("Condition:") {
                    cond = t.replacingOccurrences(of: "Condition:", with: "").trimmingCharacters(in: .whitespaces)
                }
            }
            DispatchQueue.main.async {
                self.macHealthPct = pct
                self.macCondition = (cond == "Normal") ? "정상" : cond
            }
        }
    }

    private func tick() {
        if forceSlowRead || Date().timeIntervalSince(lastSlowRead) >= slowInterval {
            let fresh = PowerReader.read()
            if fresh.valid { slowSnap = fresh; lastSlowRead = Date(); forceSlowRead = false }
            sweepSensors()
        }
        var s = slowSnap
        guard s.valid else { return }

        // Live wattages override the snapshot's stale ones. Battery flow follows from
        // the energy balance: what the adapter supplies minus what the system draws.
        if let live = smc.power() {
            s.systemW = live.system
            s.adapterW = s.external ? live.adapter : 0
            s.batteryW = s.adapterW - live.system
            s.live = true
        }

        // Poll only the hot set; the sweep that chooses it runs on the slow cycle.
        if !watchKeys.isEmpty {
            // Same plausibility window as the sweep. A core that powers down reports
            // nonsense — an M2 Max core read 8.4°C moments after its load stopped.
            let readings = watchKeys.compactMap { k -> TempReading? in
                guard let v = smc.readFloat(k), Self.plausible(v) else { return nil }
                return TempReading(key: k, c: v)
            }
            if !readings.isEmpty { temps = readings.sorted { $0.c > $1.c } }
        }
        // Mean across the fixed CPU set, read every tick.
        if !cpuWatchKeys.isEmpty {
            let vs = cpuWatchKeys.compactMap { k -> Double? in
                guard let v = smc.readFloat(k), Self.plausible(v) else { return nil }
                return v
            }
            if !vs.isEmpty {
                cpuTempC = vs.reduce(0, +) / Double(vs.count)
                cpuSensorCount = vs.count
            }
        }
        // Battery temperature comes from SMC when it can, so the flow, health and
        // temperature tabs cannot disagree about it. IOKit's value stays as fallback.
        if let k = batteryTempKey, let v = smc.readFloat(k) { s.tempC = v }
        history.append(s.systemW)
        if history.count > historyCap { history.removeFirst(history.count - historyCap) }
        if cpuTempC > 0 || s.tempC > 0 {
            let now = Date()
            tempHistory.append(TempSample(at: now, cpu: cpuTempC, batt: s.tempC))
            let cutoff = now.addingTimeInterval(-tempWindow)
            if let keep = tempHistory.firstIndex(where: { $0.at >= cutoff }), keep > 0 {
                tempHistory.removeFirst(keep)
            }
        }

        let adapterActive = s.external && s.adapterW > 0.5
        let dis = max(0, -s.batteryW)
        let chg = max(0, s.batteryW)

        if s.external && !adapterActive && dis > 1.0 { idleStreak += 1 } else { idleStreak = 0 }

        let st: PowerState
        if !s.external {
            st = .battery
        } else if adapterActive {
            if chg > 0.1 { st = .charging }
            else if dis > 0.1 { st = .boost }
            else { st = .powering }
        } else if idleStreak >= idleThreshold {
            st = .idle
        } else {
            st = .powering
        }
        self.snap = s
        self.state = st
        onTick?()
    }
}

func fmtW(_ w: Double) -> String {
    let dec = (UserDefaults.standard.object(forKey: "showDecimals") as? Bool) ?? true
    return dec ? String(format: "%.1fW", w) : String(format: "%.0fW", w)
}

// MARK: - Menu bar width

// How much the status item shows. `full` is raw value 0 so an unset default keeps
// the original behavior.
enum MenuBarMode: Int {
    case full = 0      // 🔌 29% 8.4W ＋18.3W
    case percent = 1   // 🔌 29%
    case watts = 2     // 🔌 8.4W
    case icon = 3      // 🔌

    static var current: MenuBarMode {
        MenuBarMode(rawValue: UserDefaults.standard.integer(forKey: "menuBarMode")) ?? .full
    }
}

// MARK: - Top energy apps (no-sudo CPU proxy for Activity-Monitor-style "energy" list)

struct AppCPU: Identifiable { let id = UUID(); let name: String; let cpu: Double }

final class TopApps: ObservableObject {
    @Published var apps: [AppCPU] = []
    private var timer: Timer?

    func start() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in self?.sample() }
    }

    private func sample() {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-Aro", "%cpu=,comm="]   // all procs, sorted by cpu desc, no header
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = nil
            do { try p.run() } catch { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            var res: [AppCPU] = []
            for line in out.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let sp = t.firstIndex(of: " ") else { continue }
                guard let cpu = Double(t[..<sp]) else { continue }
                if cpu < 0.5 { continue }
                var name = String(t[t.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
                if let slash = name.range(of: "/", options: .backwards) { name = String(name[slash.upperBound...]) }
                res.append(AppCPU(name: name, cpu: cpu))
                if res.count >= 5 { break }
            }
            DispatchQueue.main.async { self.apps = res }
        }
    }
}

// MARK: - Charge limit engine (delegates privileged SMC control to the `battery` CLI)

final class BatteryEngine: ObservableObject {
    @Published var installed = false
    @Published var limit: Int? = nil          // nil = no limit (충전 제한 끔)
    @Published var sailing: Bool = UserDefaults.standard.bool(forKey: "sailing")
    @Published var lastCalibration: Date? = UserDefaults.standard.object(forKey: "lastCalibration") as? Date
    @Published var busy = false               // a privileged install/uninstall is running
    @Published var lastMessage: String? = nil
    private let home = NSHomeDirectory()
    private var binPath: String?

    private func findBin() -> String? {
        let candidates = ["\(home)/.battery/battery",
                          "/opt/homebrew/bin/battery",
                          "/usr/local/bin/battery"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
    }

    func refresh() {
        binPath = findBin()
        installed = (binPath != nil)
        // The `battery` CLI stores its maintain target under ~/.battery/
        let candidates = ["\(home)/.battery/maintain.percentage",
                          "\(home)/.battery/.maintain.percentage"]
        var found: Int? = nil
        for f in candidates {
            if let txt = try? String(contentsOfFile: f, encoding: .utf8) {
                let t = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.contains("-") {                       // sailing range "75-80" → upper bound
                    let parts = t.split(separator: "-")
                    if parts.count == 2, let hi = Int(parts[1]) { found = hi; break }
                } else if let n = Int(t), (1...100).contains(n) { found = n; break }
            }
        }
        limit = found
    }

    func setSailing(_ on: Bool) {
        sailing = on
        UserDefaults.standard.set(on, forKey: "sailing")
        if let l = limit { setLimit(l) }   // re-apply current limit in new mode
    }

    private func envPath() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home)/.battery:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    func setLimit(_ pct: Int?) {
        guard let bin = binPath else { return }
        limit = pct   // optimistic
        let args: [String]
        if let p = pct {
            args = sailing ? ["maintain", "\(max(50, p-5))-\(p)"] : ["maintain", "\(p)"]
        } else {
            args = ["maintain", "stop"]
        }
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            p.environment = self.envPath()
            p.standardOutput = nil; p.standardError = nil
            try? p.run(); p.waitUntilExit()
            DispatchQueue.main.async { self.refresh() }
        }
    }

    // Long-running / forceful ops: launch fully detached so they survive and don't block.
    private func runDetached(_ args: [String]) {
        guard let bin = binPath else { return }
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.environment = self.envPath()
            let cmd = ([bin] + args).map { "'\($0)'" }.joined(separator: " ")
            p.arguments = ["-c", "\(cmd) >>\(self.home)/.battery/battery.log 2>&1 &"]
            try? p.run(); p.waitUntilExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
        }
    }
    func forceCharge() { runDetached(["charge", "100"]) }       // 일시적 100% 충전
    func forceDischarge(to pct: Int) { runDetached(["discharge", "\(pct)"]) }
    func calibrate() {
        runDetached(["calibrate"])
        let now = Date()
        lastCalibration = now
        UserDefaults.standard.set(now, forKey: "lastCalibration")
    }

    // MARK: Privileged install / uninstall
    //
    // Both delegate to the upstream tool rather than writing the sudoers file or
    // deleting root-owned paths ourselves — `battery uninstall` also re-enables
    // charging and unloads its daemon, which hand-deleting would skip.

    static let setupURL = "https://raw.githubusercontent.com/actuallymentor/battery/main/setup.sh"

    // setup.sh aborts when it resolves the calling user to root, but accepts the
    // unprivileged account as $1 — required since we run the whole thing as root.
    var installCommand: String {
        "set -e; t=$(mktemp -d); curl -fsSL \(Self.setupURL) -o \"$t/setup.sh\"; "
        + "/bin/bash \"$t/setup.sh\" '\(NSUserName())'; rm -rf \"$t\""
    }

    // battery derives configfolder and its LaunchAgent path from $HOME, so as bare
    // root it would clean /var/root and leave the real account's daemon running.
    var uninstallCommand: String {
        "HOME='\(home)' SUDO_USER='\(NSUserName())' "
        + "'\(binPath ?? "/usr/local/bin/battery")' uninstall silent"
    }

    // Two charge limiters fighting over the same SMC keys is the classic failure
    // mode, so surface it before installing rather than after.
    var conflictingApp: String? {
        let known = [("/Applications/AlDente.app", "AlDente"),
                     ("/Applications/battery.app", "Battery.app")]
        return known.first { FileManager.default.fileExists(atPath: $0.0) }?.1
    }

    func install()   { runPrivileged(installCommand,   action: "설치") }
    func uninstall() { runPrivileged(uninstallCommand, action: "제거") }

    private func runPrivileged(_ command: String, action: String) {
        guard !busy else { return }
        busy = true
        lastMessage = nil
        DispatchQueue.global().async {
            // AppleScript string literal: backslashes first, then quotes.
            let esc = command
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"\(esc)\" with administrator privileges"]
            let errPipe = Pipe()
            p.standardOutput = FileHandle.nullDevice   // install log is large; only errors matter
            p.standardError = errPipe
            var msg: String
            do {
                try p.run()
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    msg = "\(action) 완료"
                } else if err.contains("User canceled") || err.contains("-128") {
                    msg = "취소됨"
                } else {
                    msg = "\(action) 실패 — \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
            } catch {
                msg = "\(action) 실행 불가 — \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.busy = false
                self.lastMessage = msg
                self.refresh()
            }
        }
    }
}

// MARK: - SwiftUI flow diagram

struct NodeBox: View {
    let emoji: String, label: String, value: String, dim: Bool
    var sub: String? = nil
    var subColor: Color = UI.text(0.5)
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                Text(emoji).font(.system(size: 16))
                Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(UI.text(0.55))
            }
            Text(value).font(.system(size: 15, weight: .bold)).foregroundColor(UI.textStrong)
                .monospacedDigit()
            if let sub = sub {
                Text(sub).font(.system(size: 9, weight: .medium)).foregroundColor(subColor)
                    .monospacedDigit()
            }
        }
        .frame(width: 112, height: 58)
        .background(RoundedRectangle(cornerRadius: 14).fill(UI.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(UI.cardBorder, lineWidth: 1))
        .opacity(dim ? 0.32 : 1)
    }
}

struct Edge { let from: CGPoint; let to: CGPoint; let color: Color; let watts: Double }

struct FlowCanvas: View {
    let edges: [Edge]
    // all three static edge lines for context
    static let lines: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 150, y: 54), CGPoint(x: 210, y: 54)),
        (CGPoint(x: 120, y: 82),  CGPoint(x: 150, y: 132)),
        (CGPoint(x: 210, y: 132), CGPoint(x: 240, y: 82)),
    ]
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, _ in
                // faint static edges
                for l in Self.lines {
                    var p = Path(); p.move(to: l.0); p.addLine(to: l.1)
                    ctx.stroke(p, with: .color(UI.inset), lineWidth: 2)
                }
                // animated dots
                for e in edges {
                    let n = max(2, min(8, Int((e.watts / 4).rounded())))
                    let speed = min(1.0, 0.3 + e.watts * 0.03)   // cycles / sec
                    for i in 0..<n {
                        var f = (t * speed + Double(i) / Double(n)).truncatingRemainder(dividingBy: 1)
                        if f < 0 { f += 1 }
                        let x = e.from.x + (e.to.x - e.from.x) * f
                        let y = e.from.y + (e.to.y - e.from.y) * f
                        let glow = CGRect(x: x - 6, y: y - 6, width: 12, height: 12)
                        ctx.fill(Path(ellipseIn: glow), with: .color(e.color.opacity(0.22)))
                        let core = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
                        ctx.fill(Path(ellipseIn: core), with: .color(e.color))
                    }
                }
            }
        }
        .frame(width: 360, height: 198)
    }
}

/// Rolling system-power trace. Drawn with Canvas like FlowCanvas rather than pulled
/// in from a charting framework — there are no axes, legend or hit-testing here, so
/// a chart library would only cost styling control.
struct Sparkline: View {
    let samples: [Double]
    var body: some View {
        Canvas { ctx, size in
            guard samples.count > 1 else { return }
            let hi = max(samples.max() ?? 1, 0.1)
            let lo = min(samples.min() ?? 0, hi)
            let span = max(hi - lo, 0.5)          // keep a flat trace from filling the box
            let dx = size.width / CGFloat(samples.count - 1)
            func point(_ i: Int) -> CGPoint {
                let y = size.height - CGFloat((samples[i] - lo) / span) * (size.height - 4) - 2
                return CGPoint(x: CGFloat(i) * dx, y: y)
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<samples.count { line.addLine(to: point(i)) }

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [Color.green.opacity(0.28), Color.green.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(.green.opacity(0.9)), lineWidth: 1.5)

            let last = point(samples.count - 1)
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)),
                     with: .color(.green))
        }
    }
}

/// One temperature series on its own scale, over a fixed one-hour window.
///
/// The x axis is always the full hour. Stretching however much has been collected
/// across the whole width made twenty seconds of data look exactly like an hour of
/// it; now a short history occupies the right edge and the rest stays empty, so how
/// much you are actually looking at is visible.
///
/// An hour holds more samples than the view has pixels, so each column is averaged
/// rather than overplotted — raw, every column drew its full spread and the trace
/// read as a picket fence. The label quotes the true min and max, so a smoother line
/// never hides the range.
struct TempSeriesChart: View {
    let samples: [TempSample]
    let value: (TempSample) -> Double
    let color: Color
    var window: TimeInterval = 3600

    private var clean: [Double] { samples.map(value).filter { $0 > 0 } }

    var range: (lo: Double, hi: Double)? {
        guard let lo = clean.min(), let hi = clean.max() else { return nil }
        return (lo, hi)
    }
    var label: String {
        guard let r = range else { return "" }
        return String(format: "%.0f\u{2013}%.0f\u{00B0}C", r.lo, r.hi)
    }
    /// Share of the window that has been filled, so the trace starts where it should.
    var filled: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return min(1, max(0, last.at.timeIntervalSince(first.at) / window))
    }

    var body: some View {
        Canvas { ctx, size in
            guard samples.count > 1, let r = range, let last = samples.last else { return }
            let span = max(r.hi - r.lo, 3)              // never zoom into sensor noise
            let originX = size.width * (1 - CGFloat(filled))
            let usable = max(1.0, size.width - originX)
            let occupied = window * filled
            let start = last.at.addingTimeInterval(-occupied)

            // Average per pixel column across the occupied part of the axis.
            let cols = max(1, Int(usable))
            var sums = [Double](repeating: 0, count: cols)
            var counts = [Int](repeating: 0, count: cols)
            for s in samples {
                let v = value(s)
                guard v > 0 else { continue }
                let f = occupied > 0 ? s.at.timeIntervalSince(start) / occupied : 1
                let idx = min(cols - 1, max(0, Int(f * Double(cols - 1))))
                sums[idx] += v; counts[idx] += 1
            }
            var line = Path()
            var started = false
            for i in 0..<cols where counts[i] > 0 {
                let v = sums[i] / Double(counts[i])
                let y = size.height - CGFloat((v - r.lo) / span) * (size.height - 4) - 2
                let p = CGPoint(x: originX + CGFloat(i), y: y)
                if started { line.addLine(to: p) } else { line.move(to: p); started = true }
            }
            guard started else { return }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: originX, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.22), color.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color), lineWidth: 1.5)
        }
    }
}

enum TempPalette {
    static let cpu = UI.cpuLine
    static let batt = UI.battLine
}

// Selectable chip. The stock segmented picker renders unselected segments nearly
// invisible against this dark background, so choices use this instead.
struct ChoiceChip: View {
    let label: String
    let active: Bool
    let action: () -> Void
    var minWidth: CGFloat = 30
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .white : UI.text(0.75))
                .frame(minWidth: minWidth)
                .padding(.vertical, 5).padding(.horizontal, 9)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Color.green.opacity(0.85) : UI.chipIdle))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(active ? Color.clear : UI.chipBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct ActionButton: View {
    let label: String; let color: Color; let action: () -> Void
    var body: some View {
        Button(action: action) {
            // White on a filled accent, not the palette's near-black: this sits on
            // colour, not on the light ground everything else does.
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(color))
        }.buttonStyle(.plain)
    }
}

struct TabButton: View {
    let title: String; let active: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            // The active pill is white, not a filled accent, so its label has to be
            // dark — white on white left the selected tab blank.
            Text(title).font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundColor(active ? UI.textStrong : UI.text(0.5))
                .padding(.vertical, 6).frame(maxWidth: .infinity)
                .background(active ? UI.tabActive : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
}

struct StatRow: View {
    let label: String; let value: String
    var accent: Color = UI.text
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundColor(UI.text(0.55))
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium)).foregroundColor(accent)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
    }
}

struct PowerFlowView: View {
    @ObservedObject var model: PowerModel
    @ObservedObject var engine: BatteryEngine
    @ObservedObject var topApps: TopApps
    @State private var tab = 0
    @State private var sliderVal: Double = 80
    @State private var confirmDischarge = false
    @State private var confirmCalibrate = false
    @State private var confirmInstall = false
    @State private var confirmUninstall = false
    @AppStorage("refreshInterval") private var refreshInterval: Double = 2.0
    @AppStorage("showDecimals") private var showDecimals: Bool = true
    @AppStorage("menuBarMode") private var menuBarMode: Int = MenuBarMode.full.rawValue
    @State private var draftMode: Int = MenuBarMode.current.rawValue   // pending, applied on 확인

    // node centers
    let adapterC = CGPoint(x: 94, y: 54)
    let macC = CGPoint(x: 266, y: 54)
    let battC = CGPoint(x: 180, y: 160)

    var caption: (String, String) {
        switch model.state {
        case .charging: return ("⚡ 충전 중", "어댑터가 맥과 배터리에 동시 공급")
        case .boost:    return ("🔌+🔋 동시 사용", "맥 소비 > 어댑터 · 배터리가 부족분 보충")
        case .powering: return ("🔌 어댑터 구동", "어댑터가 맥만 구동 · 배터리 유지")
        case .idle:
            if let lim = engine.limit, model.snap.soc >= lim {
                return ("🔌 충전 상한 유지", "\(lim)% 도달 · 충전 보류 (어댑터 대기)")
            }
            return ("🔌 어댑터 유휴", "어댑터 연결됨 · 지금은 배터리가 맥 구동")
        case .battery:  return ("🔋 배터리 구동", "어댑터 없음 · 배터리가 맥에 공급")
        }
    }

    var edges: [Edge] {
        let s = model.snap
        let GREEN = UI.good, ORANGE = UI.warn, WHITE = UI.text(0.55)
        let AM = (CGPoint(x: 150, y: 54), CGPoint(x: 210, y: 54))
        let AB = (CGPoint(x: 120, y: 82),  CGPoint(x: 150, y: 132))
        let BM = (CGPoint(x: 210, y: 132), CGPoint(x: 240, y: 82))
        switch model.state {
        case .charging:
            return [Edge(from: AM.0, to: AM.1, color: GREEN, watts: s.systemW),
                    Edge(from: AB.0, to: AB.1, color: GREEN, watts: model.chargeW)]
        case .boost:
            return [Edge(from: AM.0, to: AM.1, color: WHITE, watts: s.adapterW),
                    Edge(from: BM.0, to: BM.1, color: ORANGE, watts: model.dischargeW)]
        case .powering:
            return [Edge(from: AM.0, to: AM.1, color: WHITE, watts: s.systemW)]
        case .idle, .battery:
            return [Edge(from: BM.0, to: BM.1, color: ORANGE, watts: s.systemW)]
        }
    }

    var battArrow: String {
        switch model.state {
        case .charging: return " ↑"
        case .boost, .idle, .battery: return " ↓"
        case .powering: return " ="
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                TabButton(title: "흐름", active: tab == 0) { tab = 0 }
                TabButton(title: "온도", active: tab == 1) { tab = 1 }
                TabButton(title: "건강", active: tab == 2) { tab = 2 }
                TabButton(title: "충전", active: tab == 3) { tab = 3 }
                TabButton(title: "설정", active: tab == 4) { tab = 4 }
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)

            Group {
                switch tab {
                case 0: flowTab
                case 1: tempTab
                case 2: healthTab
                case 3: chargeTab
                default: settingsTab
                }
            }
            // Sized to the tallest non-scrolling tab — 흐름 at 284pt once the sparkline
            // is in. 건강 scrolls, so it is exempt. A frame shorter than the content
            // pushes the bottom row onto the divider below instead of clipping.
            .frame(height: 292)

            Divider().background(UI.divider).padding(.horizontal, 16)

            HStack {
                Text(footerText).font(.system(size: 11)).foregroundColor(UI.text(0.6))
                Spacer()
                Button(action: { NSApp.terminate(nil) }) {
                    Text("종료").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundColor(UI.text(0.7))
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
        .frame(width: 380)
        .background(UI.background)
    }

    // MARK: Tab 1 — flow
    var flowTab: some View {
        let s = model.snap
        let cap = caption
        return VStack(spacing: 0) {
            Text(cap.0).font(.system(size: 15, weight: .semibold)).foregroundColor(UI.textStrong)
                .padding(.top, 4)
            Text(cap.1).font(.system(size: 11)).foregroundColor(UI.text(0.5))
                .padding(.top, 3).frame(height: 16)
            ZStack(alignment: .topLeading) {
                FlowCanvas(edges: edges)
                NodeBox(emoji: "⚡", label: "어댑터",
                        value: s.external ? fmtW(s.adapterW) : "—",
                        dim: (model.state == .battery))   // dim only when truly unplugged
                    .position(adapterC)
                // The Mac node carries the Mac's temperature and the battery node the
                // battery's. It used to show the battery reading on both.
                NodeBox(emoji: "💻", label: "맥 사용", value: fmtW(s.systemW), dim: false,
                        sub: model.cpuTempC > 0 ? String(format: "🌡 %.0f°C", model.cpuTempC) : nil,
                        subColor: model.cpuTempC >= 90 ? UI.warn : UI.text(0.5))
                    .position(macC)
                NodeBox(emoji: "🔋", label: "배터리", value: "\(s.soc)%\(battArrow)", dim: false,
                        sub: s.tempC > 0 ? String(format: "🌡 %.1f°C", s.tempC) : nil,
                        subColor: s.tempC >= 40 ? UI.warn : UI.text(0.5))
                    .position(battC)
            }
            .frame(width: 360, height: 198)
            if model.history.count > 1 {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(model.historySpan).font(.system(size: 9)).foregroundColor(UI.text(0.35))
                        Spacer()
                        Text(String(format: "최대 %.1fW", model.history.max() ?? 0))
                            .font(.system(size: 9)).foregroundColor(UI.text(0.35)).monospacedDigit()
                    }
                    Sparkline(samples: model.history).frame(height: 34)
                }
                .padding(.horizontal, 16)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Tab 2 — health
    var healthTab: some View {
        ScrollView { healthContent }
    }

    // Split out of healthTab so it can be rendered and inspected without a scroll view.
    var healthContent: some View {
        let s = model.snap
        return Group {
            VStack(spacing: 1) {
                StatRow(label: "배터리 건강",
                        value: model.macHealthPct.map { "\($0)%  ·  \(model.macCondition.isEmpty ? s.condition : model.macCondition)" }
                            ?? "\(s.healthPct)%  ·  \(s.condition)",
                        accent: (model.macHealthPct ?? s.healthPct) >= 80 ? UI.good : UI.warn)
                StatRow(label: "  └ 원시 용량비 (raw)", value: "\(s.healthPct)%")
                StatRow(label: "설계 용량", value: "\(s.designCap) mAh")
                StatRow(label: "최대 용량(원시)", value: "\(s.rawMaxCap) mAh")
                StatRow(label: "충전 사이클", value: "\(s.cycleCount) 회")
                StatRow(label: "배터리 온도", value: String(format: "%.1f °C", s.tempC))
                StatRow(label: "배터리 전압", value: String(format: "%.2f V", s.batteryVoltage))
                StatRow(label: "현재 잔량", value: "\(s.soc) %")
                StatRow(label: model.state == .charging ? "가득 차는 시간" : "남은 사용 시간",
                        value: timeValue)
                Divider().background(UI.divider).padding(.vertical, 4)
                StatRow(label: "전원 어댑터",
                        value: s.external ? "\(s.adapterRatedW) W" : "미연결",
                        accent: s.external ? UI.text : UI.text(0.5))
                if s.external {
                    StatRow(label: "  └ 전압 / 전류",
                            value: String(format: "%.1f V · %.2f A", s.adapterVoltage, s.adapterCurrent))
                    if let pd = s.activePD {
                        StatRow(label: "  └ 협상 프로파일",
                                value: "\(pd.label)  (\(String(format: "%.0fW", pd.watts)))",
                                accent: UI.good)
                        if s.pdProfiles.count > 1 {
                            HStack(spacing: 4) {
                                Text("      제공 프로파일").font(.system(size: 10))
                                    .foregroundColor(UI.text(0.4))
                                Spacer()
                                ForEach(s.pdProfiles) { p in
                                    Text(p.label)
                                        .font(.system(size: 9, weight: p.index == s.pdActiveIndex ? .bold : .regular))
                                        .foregroundColor(p.index == s.pdActiveIndex ? .green : UI.text(0.4))
                                        .padding(.vertical, 1).padding(.horizontal, 4)
                                        .background(RoundedRectangle(cornerRadius: 4)
                                            .fill(p.index == s.pdActiveIndex ? Color.green.opacity(0.15) : Color.clear))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    if s.adapterLossW > 0, let eff = s.adapterEfficiency {
                        StatRow(label: "  └ 어댑터 손실",
                                value: String(format: "%.2f W  ·  효율 %.1f%%", s.adapterLossW, eff * 100),
                                accent: eff >= 0.9 ? UI.text : UI.warn)
                        StatRow(label: "  └ 벽면 소비(추정)", value: String(format: "%.2f W", s.wallW))
                    }
                    if !s.adapterDesc.isEmpty {
                        StatRow(label: "  └ 설명", value: s.adapterDesc)
                    }
                }
                if !s.serial.isEmpty {
                    StatRow(label: "직렬번호", value: s.serial)
                }
                if s.cellVoltages.count > 1 {
                    Divider().background(UI.divider).padding(.vertical, 4)
                    StatRow(label: "배터리 셀", value: "\(s.cellVoltages.count)셀")
                    StatRow(label: "  └ 셀 전압",
                            value: s.cellVoltages.map { String(format: "%.3f", $0) }.joined(separator: " / ") + " V")
                    if let spread = s.cellSpreadMV {
                        StatRow(label: "  └ 셀 편차", value: "\(spread) mV",
                                accent: spread >= 50 ? UI.warn : UI.good)
                    }
                    if s.cellRa.count == s.cellVoltages.count {
                        StatRow(label: "  └ 내부 저항",
                                value: s.cellRa.map(String.init).joined(separator: " / "))
                    }
                    Text("셀 편차는 부하가 걸리면 커집니다. 저항이 높은 셀이 더 많이 떨어지기 때문이며, 무부하일 때의 값이 노화 지표입니다.")
                        .font(.system(size: 9)).foregroundColor(UI.text(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                if s.dailyMinSoc >= 0 && s.dailyMaxSoc >= 0 {
                    Divider().background(UI.divider).padding(.vertical, 4)
                    StatRow(label: "오늘 사용 구간",
                            value: "\(s.dailyMinSoc)% – \(s.dailyMaxSoc)%  (\(s.dailyMaxSoc - s.dailyMinSoc)%p)")
                }
                if s.lifeHours > 0 {
                    Divider().background(UI.divider).padding(.vertical, 4)
                    StatRow(label: "평생 기록", value: "")
                    StatRow(label: "  └ 총 가동 시간", value: "\(s.lifeHours) 시간")
                    StatRow(label: "  └ 온도 범위",
                            value: String(format: "%.1f ~ %.1f °C  (평균 %.1f)", s.lifeMinTempC, s.lifeMaxTempC, s.lifeAvgTempC),
                            accent: s.lifeMaxTempC >= 45 ? UI.warn : UI.text)
                    StatRow(label: "  └ 최대 충전 / 방전",
                            value: String(format: "%.2f A / %.2f A", s.lifeMaxChargeA, s.lifeMaxDischargeA))
                    StatRow(label: "  └ 팩 전압 범위",
                            value: String(format: "%.2f ~ %.2f V", s.lifeMinPackV, s.lifeMaxPackV))
                }
                if s.permanentFailure != 0 || s.cellDisconnects != 0 {
                    StatRow(label: "  └ 고장 지표",
                            value: "영구고장 \(s.permanentFailure) · 셀단선 \(s.cellDisconnects)",
                            accent: UI.warn)
                }
                Divider().background(UI.divider).padding(.vertical, 4)
                HStack {
                    Text("에너지 사용 상위 앱").font(.system(size: 12, weight: .medium))
                        .foregroundColor(UI.text(0.7))
                    Spacer()
                    Text("CPU 기준").font(.system(size: 9)).foregroundColor(UI.text(0.35))
                }
                if topApps.apps.isEmpty {
                    Text("측정 중…").font(.system(size: 11)).foregroundColor(UI.text(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(topApps.apps) { a in
                        StatRow(label: a.name, value: String(format: "%.0f%%", a.cpu),
                                accent: a.cpu > 50 ? UI.warn : UI.text)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
        }
    }

    var timeValue: String {
        let m = model.state == .charging ? model.snap.timeToFull : model.snap.timeToEmpty
        guard m > 0 && m < 60 * 48 else { return "—" }
        return String(format: "%d시간 %d분", m / 60, m % 60)
    }

    // Prefers what the app already knows for certain over the SMC bitfield, which is
    // only partly decoded.
    var chargeHoldReason: String? {
        let s = model.snap
        guard s.external, !s.charging else { return nil }
        if let lim = engine.limit, s.soc >= lim {
            return "충전 상한 \(lim)%에 도달해 엔진이 충전을 보류 중입니다."
        }
        if s.soc >= 100 { return "완충 상태입니다." }
        return s.notChargingText
    }

    // Apple Silicon die sensors sit in the 80–100°C band under sustained load and only
    // throttle above it, so warning at 80 would flag ordinary work as trouble. The
    // hottest sensor on a machine is usually a die sensor, which is what this colours.
    func tempColor(_ c: Double) -> Color {
        if c >= 100 { return .red }
        if c >= 90 { return .orange }
        return UI.text
    }

    // MARK: Tab — temperature
    //
    // Only the two sensors whose identity is established: the CPU family maximum and
    // the battery sensor cross-checked against IOKit. The rest of what SMC publishes
    // is unlabelled keys of unknown provenance, and listing them invited reading
    // meaning into numbers that have none.
    var tempTab: some View {
        VStack(alignment: .leading, spacing: 5) {
            if model.cpuTempC <= 0 && model.snap.tempC <= 0 {
                Text("센서를 읽는 중…").font(.system(size: 11)).foregroundColor(UI.text(0.4))
                    .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Circle().fill(TempPalette.cpu).frame(width: 7, height: 7)
                    Text("CPU").font(.system(size: 12)).foregroundColor(UI.text(0.6))
                    Spacer()
                    Text(model.cpuTempC > 0 ? String(format: "%.1f °C", model.cpuTempC) : "—")
                        .font(.system(size: 24, weight: .bold)).monospacedDigit()
                        .foregroundColor(tempColor(model.cpuTempC))
                    // Sensors, not cores: an M2 Max has 12 cores and 112 CPU sensors.
                    Text(model.cpuSensorCount > 0 ? "센서 \(model.cpuSensorCount)" : "")
                        .font(.system(size: 8))
                        .foregroundColor(UI.text(0.25)).frame(width: 42, alignment: .leading)
                }
                HStack(alignment: .firstTextBaseline) {
                    Circle().fill(TempPalette.batt).frame(width: 7, height: 7)
                    Text("배터리").font(.system(size: 12)).foregroundColor(UI.text(0.6))
                    Spacer()
                    Text(model.snap.tempC > 0 ? String(format: "%.1f °C", model.snap.tempC) : "—")
                        .font(.system(size: 24, weight: .bold)).monospacedDigit()
                        .foregroundColor(model.snap.tempC >= 40 ? UI.warn : UI.textStrong)
                    Text(model.batteryTempKey ?? "IOKit").font(.system(size: 8))
                        .foregroundColor(UI.text(0.25)).frame(width: 30, alignment: .leading)
                }

                if model.fanRPMs.isEmpty {
                    StatRow(label: "팬", value: "없음 (팬리스 모델)", accent: UI.text(0.45))
                } else {
                    ForEach(Array(model.fanRPMs.enumerated()), id: \.offset) { i, rpm in
                        StatRow(label: model.fanRPMs.count > 1 ? "팬 \(i + 1)" : "팬",
                                value: rpm > 0 ? String(format: "%.0f RPM", rpm) : "정지",
                                accent: rpm > 0 ? UI.text : UI.text(0.45))
                    }
                }

                Divider().background(UI.divider).padding(.top, 3)
                let cpuChart = TempSeriesChart(samples: model.tempHistory, value: { $0.cpu }, color: TempPalette.cpu)
                let battChart = TempSeriesChart(samples: model.tempHistory, value: { $0.batt }, color: TempPalette.batt)
                if model.tempHistory.count > 1 {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text("CPU").font(.system(size: 9)).foregroundColor(TempPalette.cpu.opacity(0.8))
                            Spacer()
                            Text(cpuChart.label).font(.system(size: 9))
                                .foregroundColor(UI.text(0.35)).monospacedDigit()
                        }
                        cpuChart.frame(height: 62)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text("배터리").font(.system(size: 9)).foregroundColor(TempPalette.batt.opacity(0.8))
                            Spacer()
                            Text(battChart.label).font(.system(size: 9))
                                .foregroundColor(UI.text(0.35)).monospacedDigit()
                        }
                        battChart.frame(height: 38)
                    }
                    HStack {
                        Text("1시간 전").font(.system(size: 9)).foregroundColor(UI.text(0.28))
                        Spacer()
                        Text("기록 \(model.tempHistorySpan)").font(.system(size: 9))
                            .foregroundColor(UI.text(0.28))
                        Spacer()
                        Text("지금").font(.system(size: 9)).foregroundColor(UI.text(0.28))
                    }
                } else {
                    Text("기록을 모으는 중…").font(.system(size: 10)).foregroundColor(UI.text(0.3))
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    var calibrationText: String {
        guard let d = engine.lastCalibration else { return "기록 없음" }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: Tab 4 — settings
    var settingsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("메뉴바 표시").font(.system(size: 12)).foregroundColor(UI.text(0.8))
                HStack(spacing: 6) {
                    ChoiceChip(label: "아이콘", active: draftMode == MenuBarMode.icon.rawValue,
                               action: { draftMode = MenuBarMode.icon.rawValue }, minWidth: 40)
                    ChoiceChip(label: "잔량", active: draftMode == MenuBarMode.percent.rawValue,
                               action: { draftMode = MenuBarMode.percent.rawValue }, minWidth: 40)
                    ChoiceChip(label: "전력", active: draftMode == MenuBarMode.watts.rawValue,
                               action: { draftMode = MenuBarMode.watts.rawValue }, minWidth: 40)
                    ChoiceChip(label: "전체", active: draftMode == MenuBarMode.full.rawValue,
                               action: { draftMode = MenuBarMode.full.rawValue }, minWidth: 40)
                }
                // The chips only move the draft; the menu bar changes on 확인.
                HStack(spacing: 6) {
                    Text("미리보기").font(.system(size: 9)).foregroundColor(UI.text(0.35))
                    Text(model.menuBarTitle(MenuBarMode(rawValue: draftMode) ?? .full))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundColor(model.previewColor)
                        .padding(.vertical, 2).padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 5).fill(UI.inset))
                    Spacer()
                    // The 확인 button's presence is itself the "not applied yet" signal;
                    // a separate warning and an undo button only restated it.
                    if draftMode != menuBarMode {
                        Button(action: { menuBarMode = draftMode; model.onTick?() }) {
                            Text("확인").font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.vertical, 4).padding(.horizontal, 12)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.green.opacity(0.85)))
                        }.buttonStyle(.plain)
                    }
                }
                .frame(height: 22)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("갱신 주기").font(.system(size: 12)).foregroundColor(UI.text(0.8))
                    Spacer()
                    ForEach([1.0, 2.0, 5.0], id: \.self) { v in
                        ChoiceChip(label: "\(Int(v))초", active: refreshInterval == v, action: {
                            refreshInterval = v
                            model.restartTimer()
                        }, minWidth: 34)
                    }
                }
                Text(model.snap.live
                     ? "전력값은 SMC에서 실시간으로 읽습니다 · 용량·사이클은 60초 주기"
                     : "SMC 사용 불가 — 전력값도 IOKit 60초 갱신값을 씁니다")
                    .font(.system(size: 9))
                    .foregroundColor(model.snap.live ? UI.text(0.35) : .orange.opacity(0.8))
            }
            Toggle(isOn: $showDecimals) {
                Text("전력 소수점 표시 (3.4W / 3W)").font(.system(size: 12)).foregroundColor(UI.text(0.85))
            }.toggleStyle(.switch).tint(.green)

            Toggle(isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in try? (on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()) }
            )) {
                Text("로그인 시 자동 시작").font(.system(size: 12)).foregroundColor(UI.text(0.85))
            }.toggleStyle(.switch).tint(.green)

            Spacer()
            Text("PowerMeter 2.1  ·  SMC + IOKit + battery 엔진")
                .font(.system(size: 9)).foregroundColor(UI.text(0.3))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 16).padding(.top, 14)
        .onAppear { draftMode = menuBarMode }   // reopening the popover discards an unconfirmed draft
    }

    // MARK: Tab 3 — charge control
    var chargeTab: some View {
        VStack(spacing: 12) {
            HStack {
                Text("충전 제한").font(.system(size: 13, weight: .medium))
                    .foregroundColor(UI.text(0.85))
                Spacer()
                if engine.installed {
                    Text(engine.limit.map { "\($0)%" } ?? "끔")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(engine.limit == nil ? UI.text(0.5) : UI.good)
                } else {
                    Text("엔진 미설치").font(.system(size: 12)).foregroundColor(UI.warn)
                }
            }

            // Why the adapter is attached but nothing is going into the battery.
            if let why = chargeHoldReason {
                HStack(spacing: 5) {
                    Text("ⓘ").font(.system(size: 10)).foregroundColor(UI.text(0.5))
                    Text(why).font(.system(size: 10)).foregroundColor(UI.text(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }

            if engine.installed {
                // slider 50–100
                VStack(spacing: 2) {
                    HStack(spacing: 8) {
                        Button { let v = max(50, Int(sliderVal) - 5); sliderVal = Double(v); engine.setLimit(v) } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 18))
                        }.buttonStyle(.plain).foregroundColor(UI.text(0.6))

                        Slider(value: $sliderVal, in: 50...100, step: 5) { editing in
                            if !editing { engine.setLimit(Int(sliderVal)) }
                        }.tint(.green)

                        Button { let v = min(100, Int(sliderVal) + 5); sliderVal = Double(v); engine.setLimit(v) } label: {
                            Image(systemName: "plus.circle.fill").font(.system(size: 18))
                        }.buttonStyle(.plain).foregroundColor(UI.text(0.6))
                    }
                    HStack { Text("50%"); Spacer(); Text("100%") }
                        .font(.system(size: 9)).foregroundColor(UI.text(0.35))
                }

                // presets
                HStack(spacing: 6) {
                    ChoiceChip(label: "끔", active: engine.limit == nil) { engine.setLimit(nil) }
                    ForEach([60, 70, 80, 90, 100], id: \.self) { p in
                        ChoiceChip(label: "\(p)", active: engine.limit == p) { engine.setLimit(p) }
                    }
                }

                Toggle(isOn: Binding(get: { engine.sailing }, set: { engine.setSailing($0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sailing (범위 유지)").font(.system(size: 11)).foregroundColor(UI.text(0.85))
                        Text(engine.sailing && engine.limit != nil
                             ? "\(max(50,(engine.limit ?? 80)-5))–\(engine.limit ?? 80)% 사이 유지"
                             : "상한 도달 후 5% 내려가면 재충전").font(.system(size: 9)).foregroundColor(UI.text(0.4))
                    }
                }
                .toggleStyle(.switch).tint(.green)

                Divider().background(UI.divider)

                // actions
                HStack(spacing: 6) {
                    ActionButton(label: "충전 100%", color: .green) { engine.forceCharge() }
                    ActionButton(label: "방전", color: .orange) { confirmDischarge = true }
                    ActionButton(label: "캘리브레이션", color: UI.neutralFill) { confirmCalibrate = true }
                }
                Text("방전: 어댑터 연결 중에도 제한%까지 강제 방전 · 캘리브레이션: 15→100→80% 전체 사이클")
                    .font(.system(size: 9)).foregroundColor(UI.text(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text("마지막 보정").font(.system(size: 10)).foregroundColor(UI.text(0.45))
                    Spacer()
                    Text(calibrationText).font(.system(size: 10)).foregroundColor(UI.text(0.6))
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("충전 제한 엔진(battery)이 설치되지 않았습니다.")
                        .font(.system(size: 11)).foregroundColor(UI.warn)
                    Text("설치하면 이 탭에서 충전 상한·방전·캘리브레이션을 제어합니다.\n관리자 인증 한 번으로 진행되며, 실행할 명령은 누르면 먼저 보여줍니다.")
                        .font(.system(size: 10)).foregroundColor(UI.text(0.45))
                    if let c = engine.conflictingApp {
                        Text("⚠️ \(c)이(가) 설치돼 있습니다. 같은 SMC 키를 두고 충돌하므로 먼저 제거하세요.")
                            .font(.system(size: 10)).foregroundColor(UI.warn)
                    }
                    ActionButton(label: engine.busy ? "설치 중…" : "엔진 설치",
                                 color: engine.busy ? UI.neutralFill : .green) {
                        if !engine.busy { confirmInstall = true }
                    }
                    if let m = engine.lastMessage {
                        Text(m).font(.system(size: 10))
                            .foregroundColor(m.hasSuffix("완료") ? UI.good : UI.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            if engine.installed {
                HStack {
                    Spacer()
                    Button(action: { if !engine.busy { confirmUninstall = true } }) {
                        Text(engine.busy ? "제거 중…" : "엔진 제거")
                            .font(.system(size: 10)).foregroundColor(UI.text(0.4))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 10)
        .onAppear { if let l = engine.limit { sliderVal = Double(l) } }
        .onChange(of: engine.limit) { newVal in if let l = newVal { sliderVal = Double(l) } }
        .alert("강제 방전", isPresented: $confirmDischarge) {
            Button("취소", role: .cancel) {}
            Button("방전 시작", role: .destructive) {
                engine.forceDischarge(to: engine.limit ?? Int(sliderVal))
            }
        } message: {
            Text("어댑터가 연결돼 있어도 \(engine.limit ?? Int(sliderVal))%까지 배터리를 강제로 방전합니다.")
        }
        .alert("배터리 캘리브레이션", isPresented: $confirmCalibrate) {
            Button("취소", role: .cancel) {}
            Button("시작", role: .destructive) { engine.calibrate() }
        } message: {
            Text("15%까지 방전 → 100% 충전 → 1시간 유지 → 80% 방전. 수 시간 걸리며 그동안 충전 제한이 해제됩니다.")
        }
        .alert("충전 제어 엔진 설치", isPresented: $confirmInstall) {
            Button("취소", role: .cancel) {}
            Button("설치") { engine.install() }
        } message: {
            Text("""
                 오픈소스 battery 엔진(actuallymentor/battery)의 공식 설치 스크립트를 관리자 권한으로 실행합니다.

                 설치되는 항목:
                 • /usr/local/co.palokaj.battery/ — battery·smc 실행 파일 (root 소유)
                 • /etc/sudoers.d/battery — 암호 없이 smc 실행을 허용하는 규칙
                 • /etc/paths.d/50-battery, /usr/local/bin 심볼릭 링크

                 실행할 명령:
                 \(engine.installCommand)

                 나중에 '엔진 제거'를 누르면 sudoers 규칙까지 모두 되돌립니다.
                 """)
        }
        .alert("충전 제어 엔진 제거", isPresented: $confirmUninstall) {
            Button("취소", role: .cancel) {}
            Button("제거", role: .destructive) { engine.uninstall() }
        } message: {
            Text("""
                 battery 엔진을 완전히 제거합니다. 충전 제한이 해제되고 정상 충전으로 돌아갑니다.

                 제거되는 항목: 실행 파일, /etc/sudoers.d/battery, /etc/paths.d/50-battery, 백그라운드 데몬, ~/.battery 설정

                 실행할 명령:
                 \(engine.uninstallCommand)
                 """)
        }
    }

    var footerText: String {
        let s = model.snap
        if s.adapterRatedW > 0 && s.external {
            return "정격 \(s.adapterRatedW)W 어댑터"
        }
        if model.timeStr.isEmpty { return "" }
        return model.timeStr
    }
}

extension PowerModel {
    var timeStr: String {
        let m = state == .charging ? snap.timeToFull : snap.timeToEmpty
        guard m > 0 && m < 60 * 48 else { return "" }
        return (state == .charging ? "완충까지 " : "남은 시간 ") + String(format: "%d:%02d", m/60, m%60)
    }

    // Menu bar string for a given width mode. Shared by the status item and the
    // settings preview so the two never drift apart.
    // Icon is driven by ExternalConnected (updates instantly), NOT by the wattage
    // fields (which lag ~15s). So plugging in flips to 🔌 immediately.
    func menuBarTitle(_ mode: MenuBarMode) -> String {
        let icon = snap.external ? "🔌" : "🔋"
        switch mode {
        case .icon:    return icon
        case .percent: return "\(icon) \(Self.pct(snap.soc))"
        case .watts:   return "\(icon) \(Self.watts(snap.systemW))"
        case .full:
            let flow: String
            switch state {
            case .charging: flow = " ＋\(Self.watts(chargeW))"
            case .boost:    flow = " ▼\(Self.watts(dischargeW))"
            default:        flow = ""
            }
            return "\(icon) \(Self.pct(snap.soc)) \(Self.watts(snap.systemW))\(flow)"
        }
    }

    // Fixed-width numbers, padded with U+2007 FIGURE SPACE rather than a plain space.
    // A monospaced-digit font only equalises the digits: an ordinary space measures
    // 3.27pt against a digit's 7.74pt, so space-padding still left the item resizing
    // every tick and shoving the rest of the menu bar sideways. FIGURE SPACE is a
    // digit's width by definition, which holds the item still between state changes.
    // 🔋 and 🔌 both measure 17.00pt, so the icon swap costs nothing either.
    private static let figureSpace = "\u{2007}"
    private static func pad(_ text: String, to columns: Int) -> String {
        String(repeating: figureSpace, count: max(0, columns - text.count)) + text
    }
    private static func pct(_ v: Int) -> String { pad("\(min(999, max(0, v)))", to: 3) + "%" }
    private static func watts(_ w: Double) -> String {
        let dec = (UserDefaults.standard.object(forKey: "showDecimals") as? Bool) ?? true
        let capped = min(999.9, max(0, w))
        let body = dec ? String(format: "%.1f", capped) : String(format: "%.0f", capped)
        return pad(body, to: dec ? 5 : 3) + "W"
    }

    /// The menu bar's own colour, remapped for the light popover. systemGreen is tuned
    /// against the menu bar's backdrop and washes out on a near-white pill.
    var previewColor: Color {
        switch menuBarColor {
        case NSColor.systemGreen:  return UI.good
        case NSColor.systemOrange: return UI.warn
        default:                   return UI.text
        }
    }

    var menuBarColor: NSColor {
        guard snap.external else { return .systemOrange }
        switch state {
        case .charging:     return .systemGreen
        case .boost, .idle: return .systemOrange
        default:            return .labelColor
        }
    }
}

// MARK: - Window
//
// A panel rather than an NSPopover. A popover is tethered to the status item, and the
// status item slides around whenever any other menu bar app changes width, so the
// window opened somewhere different almost every time. This one remembers where it
// was put and reopens there; drag it and the new spot is what it remembers.
final class Panel {
    private let panel: NSPanel
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private static let originKey = "panelOrigin"

    var isVisible: Bool { panel.isVisible }

    init(content: NSView, size: NSSize) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true       // drag anywhere on the body
        panel.appearance = NSAppearance(named: .aqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        panel.contentView = content

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            self?.saveOrigin()
        }
    }

    private func saveOrigin() {
        let o = panel.frame.origin
        UserDefaults.standard.set(["x": Double(o.x), "y": Double(o.y)], forKey: Self.originKey)
    }

    /// Saved spot if there is one, otherwise under the status item the first time.
    private func placeIfNeeded(below button: NSStatusBarButton?) {
        var origin: NSPoint? = nil
        if let d = UserDefaults.standard.dictionary(forKey: Self.originKey),
           let x = d["x"] as? Double, let y = d["y"] as? Double {
            origin = NSPoint(x: x, y: y)
        } else if let w = button?.window {
            let f = w.convertToScreen(button!.bounds)
            origin = NSPoint(x: f.maxX - panel.frame.width, y: f.minY - panel.frame.height - 6)
        }
        guard var o = origin else { return }
        // Keep it on a screen even if displays changed since the position was saved.
        let visible = (NSScreen.screens.first { $0.frame.contains(o) } ?? NSScreen.main)?.visibleFrame
        if let v = visible {
            o.x = min(max(o.x, v.minX), v.maxX - panel.frame.width)
            o.y = min(max(o.y, v.minY), v.maxY - panel.frame.height)
        }
        panel.setFrameOrigin(o)
    }

    func show(below button: NSStatusBarButton?) {
        placeIfNeeded(below: button)
        panel.orderFrontRegardless()
        panel.makeKey()
        // Borderless panels get no dismissal for free.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.hide(); return nil }    // Escape
            return e
        }
    }

    func hide() {
        [outsideMonitor, keyMonitor].forEach { if let m = $0 { NSEvent.removeMonitor(m) } }
        outsideMonitor = nil; keyMonitor = nil
        panel.orderOut(nil)
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let model = PowerModel()
    let engine = BatteryEngine()
    let topApps = TopApps()
    var panel: Panel!

    func applicationDidFinishLaunching(_ note: Notification) {
        engine.refresh()
        topApps.start()
        // Size comes from the view, not a hand-written constant, so the two cannot
        // disagree and clip the tab bar off the top.
        let host = NSHostingView(rootView: PowerFlowView(model: model, engine: engine, topApps: topApps))
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        let size = fitting.height > 0 ? fitting : NSSize(width: 380, height: 364)
        host.setFrameSize(size)
        panel = Panel(content: host, size: size)

        if let btn = statusItem.button {
            btn.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            btn.title = "…W"
            btn.action = #selector(togglePanel)
            btn.target = self
        }
        model.onTick = { [weak self] in
            self?.updateTitle()
            self?.engine.refresh()
        }
        model.start()
    }

    func updateTitle() {
        let title = model.menuBarTitle(MenuBarMode.current)
        statusItem.button?.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: model.menuBarColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ])
    }

    @objc func togglePanel() {
        if panel.isVisible { panel.hide() } else { panel.show(below: statusItem.button) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
