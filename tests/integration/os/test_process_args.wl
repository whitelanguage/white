// Test: PROCESS_ARGUMENTS
// File: tests/integration/os/test_process_args.wl
// Focus: Native program arguments are exposed as UTF-8 strings with checked bounds.

import "process"

func main(argc: Int, ptr argv: String) -> Int {
    if (argc < 1 || process.argument(argc, argv, 0) is null) {
        print("FAIL: Program name is missing");
        return 1;
    }
    if (argv[0].length() == 0 || process.argument(argc, argv, -1) is !null) {
        print("FAIL: Direct argv access or negative bounds");
        return 1;
    }
    if (process.argument(argc, argv, argc) is !null) {
        print("FAIL: Argument bounds were not checked");
        return 1;
    }
    if (argc == 3) {
        let first: Optional(String) = process.argument(argc, argv, 1);
        let second: Optional(String) = process.argument(argc, argv, 2);
        if (first is null || second is null) {
            print("FAIL: Native arguments are missing");
            return 1;
        }
        if (first != "hello world" || second != "你好") {
            print("FAIL: Native arguments were not decoded as UTF-8");
            return 1;
        }
        if (argv[1] != first || argv[2] != second) {
            print("FAIL: Direct argv and process.argument disagree");
            return 1;
        }
    }
    if (argc == 5) {
        if (argv[1] != "" || argv[2] != "hello world" || argv[3] != "你好" || argv[4] != "quote\" slash\\ tail") {
            print("FAIL: Empty, quoted or Unicode argument");
            return 1;
        }
        let original = argv[2];
        argv[2] = "changed";
        let changed = process.argument(argc, argv, 2);
        if (changed is null) { return 1; }
        if (original != "hello world" || changed != "changed") {
            print("FAIL: Argument slot ownership");
            return 1;
        }
    }
    print("PASS: Native process arguments");
    return 0;
}
