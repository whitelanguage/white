// Test: AARCH64_AAPCS64_C_ABI_FIXTURE
// File: tests/machine/aarch64/fixtures/aapcs64_abi.wl
// Focus: Export scalar, aggregate, HFA and 128-bit values to an AAPCS64 C host.

struct Pair(x: Long, y: Int)
struct Hfa(a: Float, b: Float, c: Float)
struct Large(a: Long, b: Long, c: Long)

extern "C" {
    func host_hfa(value: Hfa) -> Hfa;
    func host_large(value: Large) -> Large;
    func host_wide(value: UInt128) -> UInt128;
}

@ExportLib
let exported_counter: Long = 17L;

@ExportLib
func counter_read() -> Long {
    return exported_counter;
}

@ExportLib
func pair_make(x: Long, y: Int) -> Pair {
    return Pair(x=x, y=y);
}

@ExportLib
func pair_sum(value: Pair) -> Long {
    return value.x + Long(value.y);
}

@ExportLib
func hfa_make(a: Float, b: Float, c: Float) -> Hfa {
    return Hfa(a=a, b=b, c=c);
}

@ExportLib
func hfa_sum(value: Hfa) -> Float {
    return value.a + value.b + value.c;
}

@ExportLib
func hfa_relay(value: Hfa) -> Hfa {
    return host_hfa(value);
}

@ExportLib
func large_make(a: Long, b: Long, c: Long) -> Large {
    return Large(a=a, b=b, c=c);
}

@ExportLib
func large_sum(value: Large) -> Long {
    return value.a + value.b + value.c;
}

@ExportLib
func large_relay(value: Large) -> Large {
    return host_large(value);
}

@ExportLib
func wide_add(value: UInt128, extra: UInt128) -> UInt128 {
    return value + extra;
}

@ExportLib
func wide_relay(value: UInt128) -> UInt128 {
    return host_wide(value);
}

@ExportLib
func stack_pair(a: Long, b: Long, c: Long, d: Long, e: Long, f: Long, g: Long, h: Long, value: Pair) -> Long {
    return a + b + c + d + e + f + g + h + value.x + Long(value.y);
}
