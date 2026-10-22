// Test: OPTIONAL_RECEIVER
// File: tests/language/memory/test_optional_receiver.wl
// Focus: A projected receiver outlives an argument which replaces its union storage.

let dropped: Int = 0;

class Probe {
    let value: Int;
    init() { self.value = 42; }
    func read(arg: Int) -> Int { return self.value + arg; }
    deinit() { dropped++; }
}

func reset(ref value: Optional(Probe)) -> Int {
    value = null;
    return 1;
}

func main() -> Int {
    let value: Optional(Probe) = Probe();
    if (value is null) { return 1; }
    let result = value.read(reset(ref value));
    if (result != 43 || dropped != 1 || value is !null) { return 2; }
    print("PASS: optional receiver lifetime");
    return 0;
}
