// Test: STANDARD_LIBRARY_ERRORS
// File: tests/language/errors/test_std_errors.wl
// Focus: File and environment failures report structured errors

import "file"
import "io"
import "process"
import "sys"

func missing_file_reports_error() -> Bool {
    let input: file.File = file.open("__whitelang_missing_file_7ce66f31__")?;
    catch(err) {
        return err == file.Error.NotFound;
    }
    input.close();
    return false;
}

func missing_env_reports_error() -> Bool {
    let value: String = sys.env.get("__WHITELANG_MISSING_ENV_7CE66F31__")?;
    catch(err) {
        return err == sys.env.Error.NotFound;
    }
    return value is null;
}

func exposes_error_domains() -> Bool {
    let file_error: file.Error = file.Error.NotFound;
    let io_error: io.Error = io.Error.EndOfFile;
    let process_error: process.Error = process.Error.NotFound;
    let env_error: sys.env.Error = sys.env.Error.NotFound;
    return file_error == file.Error.NotFound && io_error == io.Error.EndOfFile && process_error == process.Error.NotFound && env_error == sys.env.Error.NotFound;
}

func main() -> Int {
    if (!missing_file_reports_error()) {
        print("FAIL: missing file error");
        return 1;
    }
    if (!missing_env_reports_error()) {
        print("FAIL: missing environment error");
        return 1;
    }
    if (!exposes_error_domains()) {
        print("FAIL: standard library error domains");
        return 1;
    }
    print("PASS: standard library errors");
    return 0;
}
