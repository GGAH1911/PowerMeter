struct V { var a:UInt8=0; var b:UInt8=0; var c:UInt8=0; var d:UInt8=0; var r:UInt16=0 }
struct P { var v:UInt16=0; var l:UInt16=0; var c:UInt32=0; var g:UInt32=0; var m:UInt32=0 }
struct K { var s:UInt32=0; var t:UInt32=0; var a:UInt8=0 }
print("V", MemoryLayout<V>.stride, "P", MemoryLayout<P>.stride, "K", MemoryLayout<K>.stride)
