// Test: LARGE_STACK_FRAME
// File: tests/language/memory/test_stack_probe.wl
// Focus: Probing every guard page before using a large stack frame.

func fill(ptr bytes: Byte, count: Int, seed: Int) -> Int {
    let i: Int = 0;
    let checksum: Int = 0;
    while (i < count) {
        bytes[i] = Byte((i + seed) & 255);
        checksum += Int(bytes[i]);
        i += 1;
    }
    return checksum;
}

func large_frame(seed: Int) -> Int {
    let bytes: Byte[16384] = [0];
    return fill(ref bytes[0], 16384, seed);
}

func main() -> Int {
    let first: Int = large_frame(1);
    let second: Int = large_frame(17);
    if (first != 2088960 || second != 2088960) {
        print("FAIL: large stack frame was corrupted");
        return 1;
    }
    print("PASS: large stack frame");
    return 0;
}
