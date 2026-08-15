// Test: UNIMPORTED_IO_NAMESPACE
// File: tests/diagnostics/failures/test_unimported_io.wl
// Focus: Builtin input must not leak its io dependency into user modules.
// Expected Error: "NameError: Undefined variable or function 'io'."

func main() -> Int {
    let value: String = io.stdin.read_bytes(0)?;
    catch(err) { return 1; }
    return value.length();
}
