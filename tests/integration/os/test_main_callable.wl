// Test: MAIN_CALLABLE
// File: tests/integration/os/test_main_callable.wl
// Focus: Calling the source main must not run the native argv conversion twice.

func main(argc: Int, ptr argv: String) -> Int {
    if (argc == 2 && argv[1] == "inner") { return 7; }

    let args: String[2] = ["nested", "inner"];
    let callback = main;
    if (callback(2, ref args[0]) != 7) {
        print("FAIL: Callable main did not receive managed String slots");
        return 1;
    }
    print("PASS: Main callable uses the source ABI");
    return 0;
}
