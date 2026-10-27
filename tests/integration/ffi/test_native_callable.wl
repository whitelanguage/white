// Test: NATIVE_CALLABLE
// File: tests/integration/ffi/test_native_callable.wl
// Focus: Adapting native ABI and borrowed results to first-class Function values.
// Link: native_boundary.c

import "../../fixtures/native_callable.wl" as native


let dropped: Int = 0;

class Probe {
    deinit() { dropped += 1; }
}

extern "C" {
    func native_echo(value: Probe) -> Probe;
    func native_text(value: String) -> String;
    func native_increment(ptr value: Int) -> Void;
    func native_sum(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int, h: Int) -> Int;
    func native_ten(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int, h: Int, i: Int, j: Int) -> Int;
    func native_mix(a: Int, b: Float, c: Int, d: Float, e: Int, f: Float, g: Int, h: Float, i: Int, j: Float) -> Float;
    func native_set(value: Int) -> Void;
    func native_get() -> Int;
}

extern "system" {
    func native_system(a: Int, b: Int) -> Int;
}

func forward(call: Function(Probe) -> Probe, value: Probe) -> Probe {
    return call(value);
}

func main() -> Int {
    let echo = native_echo;
    let echo_again: Function(Probe) -> Probe = native_echo;
    {
        let original = Probe();
        let alias = echo(original);
        let other = forward(echo_again, original);
        if (alias is !original || other is !original || dropped != 0) { return 1; }
    }
    if (dropped != 1) { return 2; }

    {
        let temporary = echo(Probe());
        if (dropped != 1) { return 3; }
    }
    if (dropped != 2) { return 4; }

    let sum = native_sum;
    if (sum(1, 2, 3, 4, 5, 6, 7, 8) != 204) { return 5; }
    let mix = native_mix;
    if (mix(1, 2.0, 3, 4.0, 5, 6.0, 7, 8.0, 9, 10.0) != 55.0) { return 6; }

    let set = native_set;
    let get = native_get;
    set(42);
    if (get() != 42) { return 7; }

    let system = native_system;
    if (system(10, 3) != 7) { return 8; }

    let imported = native.native_sum;
    if (imported(1, 2, 3, 4, 5, 6, 7, 8) != 204) { return 9; }

    let text = native_text;
    let message = text("temporary " + String(get()));
    if (message != "temporary 42") { return 10; }

    let increment: Function(ptr Int) -> Void = native_increment;
    let count = 41;
    increment(ref count);
    if (count != 42) { return 11; }

    let ten = native_ten;
    if (ten(1, 2, 3, 4, 5, 6, 7, 8, 9, 10) != 55) { return 12; }

    print("PASS: native callable adaptation");
    return 0;
}
