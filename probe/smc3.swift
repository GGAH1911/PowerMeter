import Foundation
import IOKit
var conn: io_connect_t = 0
let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
_ = IOServiceOpen(svc, mach_task_self_, 0, &conn)
IOObjectRelease(svc)
// Try selectors 0..15 with input/output buffers of various sizes, key=#KEY readkeyinfo
func fcc(_ s:String)->UInt32{var r:UInt32=0;for c in s.utf8{r=(r<<8)+UInt32(c)};return r}
for sel in UInt32(0)...UInt32(12) {
  for sz in [80, 168, 120, 96, 88, 72, 256] {
    var inbuf = [UInt8](repeating:0, count: sz)
    var outbuf = [UInt8](repeating:0, count: sz)
    // place key at offset 0 (big-endian fourcc) and command byte at offset 42 (data8)
    let k = fcc("#KEY")
    inbuf[0]=UInt8((k>>24)&0xff); inbuf[1]=UInt8((k>>16)&0xff); inbuf[2]=UInt8((k>>8)&0xff); inbuf[3]=UInt8(k&0xff)
    if sz>42 { inbuf[42]=9 } // SMC_CMD_READ_KEYINFO
    var outSize = sz
    let kr = IOConnectCallStructMethod(conn, sel, &inbuf, sz, &outbuf, &outSize)
    if kr == KERN_SUCCESS {
      print("OK sel=\(sel) sz=\(sz) outSize=\(outSize)")
    }
  }
}
print("done")
