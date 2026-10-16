// libFuzzer entry point. Built by Fuzz/build.sh together with Sources/JP2K
// into one module, so the decoder types are used without an import. This file
// is outside Sources/JP2K: the raw pointer from libFuzzer is wrapped once and
// never used again.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ data: UnsafePointer<UInt8>?, _ size: Int) -> CInt {
    guard let data, size > 0 else { return 0 }
    let bytes = unsafe Array(UnsafeBufferPointer(start: data, count: size))
    var limits = Limits()
    // Keeps ASan's RSS well under run.sh's -rss_limit_mb.
    limits.maxMemoryBytes = 256 << 20
    let decoder = JP2KDecoder(limits: limits)
    guard (try? decoder.readInfo(bytes)) != nil else { return 0 }
    // One full decode per input keeps large seeds fast enough under ASan.
    // decodePixels runs the whole component pipeline; container colour rules
    // (sRGB/gray/sYCC, palette, cdef) come first, and component-count
    // inference covers raw codestreams and unsupported colour spaces.
    do {
        _ = try decoder.decodePixels(bytes)
    } catch .unsupported {
        _ = try? decoder.decodePixels(bytes, color: .inferFromComponentCount)
    } catch {
        return 0
    }
    return 0
}
