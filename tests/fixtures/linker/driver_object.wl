// tests/fixtures/linker/driver_object.wl
extern "c" {
    func answer() -> Int;
}

func main() -> Int {
    if (answer() != 42) { return 1; }
    print("PASS: Extra COFF object");
    return 0;
}
