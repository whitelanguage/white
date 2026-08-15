// Test: STANDARD_IO
// File: tests/integration/os/test_standard_io.wl
// Focus: Standard stream writes and fallible I/O contracts.
import "io"

func main() -> Int {
    io.stdout.write_all("PASS: standard ")?;
    catch(err) {
        print("FAIL: stdout write");
        return 1;
    }

    io.stdout.write_line("io")?;
    catch(err) {
        print("FAIL: stdout line");
        return 1;
    }

    let empty: String = io.stdin.read_bytes(0)?;
    catch(err) {
        print("FAIL: zero-length stdin read");
        return 1;
    }
    if (empty.length() != 0) {
        print("FAIL: zero-length read returned data");
        return 1;
    }
    return 0;
}
