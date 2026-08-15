// Test: NATIVE_TEXT_BOUNDARIES
// File: tests/integration/os/test_native_text.wl
// Focus: Native file, process, and environment APIs reject NUL bytes and malformed UTF-8 before entering the operating system.

import "file"
import "process"
import "sys"
import Error from "errors"

func rejects_file_path() -> Bool {
    let visible: String = "tests-native-text.tmp";
    let disguised: String = visible + '\0' + ".ignored";
    let handle: file.File = file.create(disguised)?;
    catch(err) { return err == file.Error.InvalidPath; }
    handle.close();
    if (file.exists(visible)) {
        file.remove(visible)?;
        catch(err) { return false; }
    }
    return false;
}

func rejects_invalid_file_path() -> Bool {
    let invalid: String = "中"[0:1];
    let handle: file.File = file.File(invalid, "rb");
    return !handle.is_open() && handle.last_error() == file.Error.InvalidPath;
}

func rejects_process_argument() -> Bool {
    let argument: String = "before" + '\0' + "after";
    let status: Int = process.run("does-not-run", [argument])?;
    catch(err) { return err == Error.InvalidArgument; }
    return false;
}

func rejects_invalid_process_argument() -> Bool {
    let invalid: String = "中"[0:1];
    let status: Int = process.run("does-not-run", [invalid])?;
    catch(err) { return err == Error.InvalidArgument; }
    return false;
}

func rejects_environment_name() -> Bool {
    let value: String = sys.env.get("PATH" + '\0' + "IGNORED")?;
    catch(err) { return err == sys.env.Error.InvalidName; }
    return false;
}

func rejects_invalid_environment_name() -> Bool {
    let invalid: String = "中"[0:1];
    let value: String = sys.env.get(invalid)?;
    catch(err) { return err == sys.env.Error.InvalidName; }
    return false;
}

func main() -> Int {
    if (!rejects_file_path() || !rejects_invalid_file_path() || !rejects_process_argument() || !rejects_invalid_process_argument() || !rejects_environment_name() || !rejects_invalid_environment_name()) {
        print("FAIL: invalid native text reached the operating system");
        return 1;
    }
    print("PASS: native text boundaries");
    return 0;
}
