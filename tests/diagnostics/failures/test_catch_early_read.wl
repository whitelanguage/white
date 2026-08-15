// Test: CATCH_EARLY_READ
// File: tests/diagnostics/failures/test_catch_early_read.wl
// Focus: Rejecting reads before a fallible declaration is definitely initialized.
// Expected Error: "MissingInitializer: Variable 'value' may be used before initialization."

func fail_text() -> String? {
    throw Error.InvalidArgument;
}

func main() -> Int {
    let value: String = fail_text()?;
    catch(err) {
        print(err);
    }
    print(value);
    value = "ready";
    return 0;
}
