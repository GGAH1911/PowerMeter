import Foundation
import IOKit

func batteryProps() -> [String: Any]? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let p = props?.takeRetainedValue() as? [String: Any] else { return nil }
    return p
}

func signed(_ v: Int) -> Int {
    // 64-bit two's complement coming through as Int already signed by CF? Usually NSNumber gives signed.
    return v
}

guard let p = batteryProps() else { print("no battery"); exit(1) }

let amperage = (p["Amperage"] as? Int) ?? 0           // mA, signed
let voltage = (p["Voltage"] as? Int) ?? 0             // mV
let instAmp = (p["InstantAmperage"] as? Int) ?? 0
let ext = (p["ExternalConnected"] as? Bool) ?? false
let charging = (p["IsCharging"] as? Bool) ?? false
let soc = (p["CurrentCapacity"] as? Int) ?? 0

let battW = Double(amperage) * Double(voltage) / 1_000_000.0
print(String(format: "Voltage=%.3f V  Amperage=%d mA  InstAmp=%d", Double(voltage)/1000, amperage, instAmp))
print(String(format: "ExternalConnected=%@  IsCharging=%@  SOC=%d%%", ext ? "YES":"NO", charging ? "YES":"NO", soc))
print(String(format: "Battery power = %.2f W  (%@)", abs(battW), battW >= 0 ? "charging" : "discharging"))

if let bd = p["BatteryData"] as? [String: Any] {
    print("--- BatteryData ---")
    for k in ["AdapterPower", "SystemPower", "Voltage", "StateOfCharge"] {
        if let v = bd[k] { print("  \(k) = \(v)") } else { print("  \(k) = <absent>") }
    }
}
if let ad = p["AdapterDetails"] as? [String: Any] {
    print("--- AdapterDetails ---")
    print("  \(ad)")
}
