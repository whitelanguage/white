// Test: PROCESS_ARGUMENTS
// File: tests/integration/os/test_process_args.wl
// Focus: Native program arguments are exposed as UTF-8 strings with checked bounds.

import "process"

func main(argc: Int, ptr argv: String) -> Int {
    if (argc < 1 || process.argument(argc, argv, 0) is null) {
        print("FAIL: Program name is missing");
        return 1;
    }
    if (process.argument(argc, argv, argc) is !null) {
        print("FAIL: Argument bounds were not checked");
        return 1;
    }
    if (argc == 3 && (process.argument(argc, argv, 1) != "hello world" || process.argument(argc, argv, 2) != "你好")) {
        print("FAIL: Native arguments were not decoded as UTF-8");
        return 1;
    }
    print("PASS: Native process arguments");
    return 0;
}
