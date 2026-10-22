// Test: OPTIONAL_ENV
// File: tests/integration/os/test_optional_env.wl
// Focus: Missing environment values are Optional, present values remain usable after calls.

import "sys"
import "process"


func main(argc: Int, ptr argv: String) -> Int {
    let missing: Optional(String) = sys.env.get_env("__WHITE_TEST_MISSING_ENV_527196");
    if (missing is !null || sys.env.get_or("__WHITE_TEST_MISSING_ENV_527196", "fallback") != "fallback") {
        print("FAIL: Missing environment variable");
        return 1;
    }

    let path: Optional(String) = sys.env.get_env("PATH");
    if (path is null) {
        print("FAIL: PATH is missing");
        return 1;
    }
    if (path.length() == 0) {
        print("FAIL: PATH is empty");
        return 1;
    }

    let name: Optional(String) = process.argument(argc, argv, 0);
    if (name is null) {
        print("FAIL: Program argument is missing");
        return 1;
    }
    if (name.length() == 0 || process.argument(argc, argv, argc) is !null) {
        print("FAIL: Optional argument bounds");
        return 1;
    }
    print("PASS: Optional environment and arguments");
    return 0;
}
