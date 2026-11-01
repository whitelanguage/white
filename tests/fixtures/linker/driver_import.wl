// tests/fixtures/linker/driver_import.wl
extern "system" in "KeRnEl32.DlL" {
    func SetLastError(code: Int) -> Void;
    func GetLastError() -> Int;
}

func main() -> Int {
    SetLastError(42);
    if (GetLastError() != 42) { return 1; }
    print("PASS: DLL declaration names");
    return 0;
}
