// Test: CATCH_UNINITIALIZED_LOCAL
// File: tests/diagnostics/failures/test_catch_uninit.wl
// Focus: Requiring a fallible declaration to be initialized on every continuing path.
// Expected Error: "MissingInitializer: Local variable 'value' is not initialized on every path."

func fail_text() -> String? {
    throw Error.InvalidArgument;
}

func unchecked() -> Void {
    let value: String = fail_text()?;
    catch(err) {
        print(err);
    }
}

func main() -> Int {
    unchecked();
    return 0;
}
