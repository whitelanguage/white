// Test: INPUT_PRELUDE
// File: tests/integration/os/test_input_prelude.wl
// Focus: Builtin input function, namespace, and zero-length operations.

func read_with_alias() -> String? {
    return input("")?;
}

func main() -> Int {
    let bytes: String = input.read_bytes("", 0)?;
    catch(err) { return 1; }
    if (bytes.length() != 0) { return 2; }

    let full: String = input.read_full("", 0)?;
    catch(err) { return 3; }
    if (full.length() != 0) { return 4; }

    let skipped: Int = input.skip_bytes("", 0)?;
    catch(err) { return 5; }
    if (skipped != 0) { return 6; }

    print("PASS: builtin input prelude");
    return 0;
}
