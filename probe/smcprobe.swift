import Foundation
import IOKit

// ---- SMC low-level ----
let KERNEL_INDEX_SMC: UInt8 = 2
let SMC_CMD_READ_BYTES: UInt8 = 5
let SMC_CMD_READ_KEYINFO: UInt8 = 9
let SMC_CMD_READ_INDEX: UInt8 = 8

struct SMCKeyData_keyInfo_t { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
struct SMCKeyData_vers_t { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
struct SMCKeyData_pLimitData_t { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }

// 32-byte bytes tuple
typealias Bytes32 = (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8)

struct SMCKeyData_t {
    var key: UInt32 = 0
    var vers = SMCKeyData_vers_t()
    var pLimitData = SMCKeyData_pLimitData_t()
    var keyInfo = SMCKeyData_keyInfo_t()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes32 = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    var _pad: UInt32 = 0
}

func fourCharCode(_ s: String) -> UInt32 {
    var r: UInt32 = 0
    for ch in s.utf8 { r = (r << 8) + UInt32(ch) }
    return r
}
func codeToString(_ c: UInt32) -> String {
    let b = [UInt8((c >> 24) & 0xff), UInt8((c >> 16) & 0xff), UInt8((c >> 8) & 0xff), UInt8(c & 0xff)]
    return String(bytes: b, encoding: .ascii) ?? "????"
}

var conn: io_connect_t = 0
let svc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSMC"))
guard svc != 0, IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else {
    print("Cannot open SMC"); exit(1)
}
IOObjectRelease(svc)

var FIXED_SIZE = MemoryLayout<SMCKeyData_t>.stride
func call(_ input: inout SMCKeyData_t, _ output: inout SMCKeyData_t) -> kern_return_t {
    var outSize = FIXED_SIZE
    return IOConnectCallStructMethod(conn, UInt32(KERNEL_INDEX_SMC), &input, FIXED_SIZE, &output, &outSize)
}

func keyInfo(_ key: String) -> (UInt32, UInt32)? { // (dataSize, dataType)
    var input = SMCKeyData_t(); var output = SMCKeyData_t()
    input.key = fourCharCode(key); input.data8 = SMC_CMD_READ_KEYINFO
    if call(&input, &output) != KERN_SUCCESS { return nil }
    return (output.keyInfo.dataSize, output.keyInfo.dataType)
}

func readBytes(_ key: String, _ size: UInt32, _ type: UInt32) -> [UInt8]? {
    var input = SMCKeyData_t(); var output = SMCKeyData_t()
    input.key = fourCharCode(key); input.data8 = SMC_CMD_READ_BYTES
    input.keyInfo.dataSize = size
    if call(&input, &output) != KERN_SUCCESS { return nil }
    var arr = [UInt8]()
    withUnsafeBytes(of: output.bytes) { raw in
        for i in 0..<Int(size) { arr.append(raw[i]) }
    }
    return arr
}

func decode(_ bytes: [UInt8], _ type: UInt32) -> Double? {
    let t = codeToString(type)
    switch t {
    case "flt ":
        if bytes.count >= 4 {
            let v = bytes[0..<4].withUnsafeBytes { $0.load(as: Float32.self) }
            return Double(v)
        }
    case "ui8 ", "ui8\0": if bytes.count >= 1 { return Double(bytes[0]) }
    case "ui16": if bytes.count >= 2 { return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) }
    case "ui32": if bytes.count >= 4 { return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])) }
    case "si16":
        if bytes.count >= 2 { let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])); return Double(raw) }
    case "sp78":
        if bytes.count >= 2 { let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])); return Double(raw)/256.0 }
    default: return nil
    }
    return nil
}

print("stride = \(MemoryLayout<SMCKeyData_t>.stride)")
for sz in stride(from: 72, through: 100, by: 1) {
    FIXED_SIZE = sz
    var input = SMCKeyData_t(); var output = SMCKeyData_t()
    input.key = fourCharCode("#KEY"); input.data8 = SMC_CMD_READ_KEYINFO
    let kr = call(&input, &output)
    if kr == KERN_SUCCESS {
        print("SUCCESS at size \(sz), dataSize=\(output.keyInfo.dataSize) dataType=\(codeToString(output.keyInfo.dataType))")
    }
}
FIXED_SIZE = MemoryLayout<SMCKeyData_t>.stride
exit(0)

// Enumerate all keys
guard let (cnt, _) = keyInfo("#KEY") else { print("no #KEY"); exit(1) }
let bytesCnt = readBytes("#KEY", cnt, fourCharCode("ui32"))!
let total = Int(UInt32(bytesCnt[0]) << 24 | UInt32(bytesCnt[1]) << 16 | UInt32(bytesCnt[2]) << 8 | UInt32(bytesCnt[3]))
print("Total SMC keys: \(total)")

for i in 0..<total {
    var input = SMCKeyData_t(); var output = SMCKeyData_t()
    input.data8 = SMC_CMD_READ_INDEX; input.data32 = UInt32(i)
    if call(&input, &output) != KERN_SUCCESS { continue }
    let name = codeToString(output.key)
    guard name.hasPrefix("P") || name.hasPrefix("B") || name.hasPrefix("D") else { continue }
    guard let (size, type) = keyInfo(name) else { continue }
    let tstr = codeToString(type)
    guard tstr == "flt " else { continue }
    if let raw = readBytes(name, size, type), let v = decode(raw, type) {
        if abs(v) > 0.01 || name.hasPrefix("P") {
            print(String(format: "%@  type=%@  value=%.3f", name, tstr, v))
        }
    }
}
