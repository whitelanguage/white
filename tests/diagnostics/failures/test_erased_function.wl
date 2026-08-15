// Test: ERASED_FUNCTION_MISMATCH
// File: tests/diagnostics/failures/test_erased_function.wl
// Focus: Checking a callable signature before restoring an erased function.
// Expected Error: "RuntimeError: Erased value has the wrong concrete type"

func answer() -> Int { return 42; }
func make() -> Function { return answer; }

func main() -> Int {
    let callback: Function() -> String = make();
    callback();
    return 0;
}
