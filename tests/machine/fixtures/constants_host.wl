// Test: NATIVE_CONSTANT_HOST
// File: tests/machine/fixtures/constants_host.wl
// Focus: Execute the aggregate constant object produced by test_constants.wl.

struct Small(value: Int)

extern "C" {
    func const_call() -> Long;
    func const_edge() -> Long;
    func const_small() -> Small;
    func const_pointer() -> Int;
    func const_bytes() -> Byte;
    func const_nested_bytes() -> Byte;
}


func main() -> Int {
    let small = const_small();
    if (const_call() != 84L || const_edge() != 42L || small.value != 42 || const_pointer() != 42 ||
        const_bytes() != Byte(169) || const_nested_bytes() != Byte(195)) {
        print("FAIL: native constant values");
        return 1;
    }

    print("PASS: native constant values");
    return 0;
}
