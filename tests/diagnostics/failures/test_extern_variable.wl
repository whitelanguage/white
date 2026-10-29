// Expected Error: "Only function declarations are allowed in extern blocks."
// File: tests/diagnostics/failures/test_extern_variable.wl
extern "C" {
    let value: String;
}

func main() -> Int {
    return 0;
}
