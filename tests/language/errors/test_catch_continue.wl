// Test: CATCH_CONTINUATION
// File: tests/language/errors/test_catch_continue.wl
// Focus: Continuing after handled failures without exposing uninitialized locals.

func fail_text() -> String? {
    throw Error.InvalidArgument;
}

func main() -> Int {
    let first: String = "";
    first = fail_text()?;
    catch(err) {
        if (first != "") { return 1; }
    }

    let second: String = fail_text()?;
    catch(err) {
        print(err);
    }
    second = "ready";
    if (second != "ready") { return 2; }

    let third: String = fail_text()?;
    catch(err) {
        third = "fallback";
    }
    if (third != "fallback") { return 3; }

    print("PASS: catch continuation");
    return 0;
}
