import Foundation
import IOKit
var conn: io_connect_t = 0
let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
print("svc=\(svc)")
let or = IOServiceOpen(svc, mach_task_self_, 0, &conn)
print("open kr=\(String(format:"0x%x",or)) conn=\(conn)")
// dump the class name
if svc != 0 {
  if let cls = IORegistryEntryCreateCFProperty(svc, "IOClass" as CFString, kCFAllocatorDefault, 0) {
    print("IOClass=\(cls.takeRetainedValue())")
  }
}
