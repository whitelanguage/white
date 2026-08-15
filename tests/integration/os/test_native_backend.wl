// Test: NATIVE_ENVIRONMENT_AND_PROCESS_BACKEND
// File: tests/integration/os/test_native_backend.wl
// Focus: Native environment lookup via sys.getenv and child-process execution status across platforms.

import "sys"
import "process"


func main() -> Int {
    let wl_path: String = sys.env.get_env("WL_PATH");
    if (wl_path is null || wl_path.length() == 0) {
        print("FAIL: native environment lookup");
        return 1;
    }

    let status: Int = 0;
    if (sys.OS == sys.Os.Windows) {
        status = process.shell("exit /b 7");
        if (status != 7) {
            print("FAIL: Win32 process exit status " + status);
            return 1;
        }
    } else {
        status = process.shell("true");
        if (status != 0) {
            print("FAIL: POSIX process execution");
            return 1;
        }
    }

    print("PASS: Native environment and process backend");
    return 0;
}
