// tests/fixtures/linker/driver_archive.wl
extern "c" in "example.lib" {
    func answer() -> Int;
}

func main() -> Int {
    return answer();
}
