// Test: PROCESS_RUN
// File: tests/integration/os/test_process_run.wl
// Focus: Direct process execution preserves argument boundaries and exit status

import "process"
import "sys"

func main() -> Int {
    let status: Int = 0;
    if (sys.OS == sys.Os.Windows) {
        status = process.run("cmd.exe", ["/d", "/s", "/c", "if \"a b\"==\"a b\" (exit 7) else (exit 9)"])?;
    } else {
        status = process.run("/bin/sh", ["-c", "test \"a b\" = \"a b\"; exit 7"])?;
    }
    catch(err) {
        print("FAIL: process could not be started");
        return 1;
    }

    if (status != 7) {
        print("FAIL: process exit status was not preserved");
        return 1;
    }
    print("PASS: direct process execution");
    return 0;
}
