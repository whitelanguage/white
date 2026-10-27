// Test: NATIVE_RESULT
// File: tests/integration/ffi/test_native_result.wl
// Focus: Keeping borrowed native results alive through argument cleanup.
// Link: native_boundary.c

let dropped: Int = 0;

class Probe {
    deinit() { dropped += 1; }
}

extern "C" {
    func native_echo(value: Probe) -> Probe;
}

func main() -> Int {
    {
        let original = Probe();
        let alias = native_echo(original);
        if (alias is !original) { return 1; }
        if (dropped != 0) { return 2; }
    }
    if (dropped != 1) { return 3; }

    {
        let temporary = native_echo(Probe());
        if (dropped != 1) { return 4; }
    }
    if (dropped != 2) { return 5; }

    print("PASS: native result lifetime");
    return 0;
}
