// Test: FILE_EOF
// File: tests/integration/os/test_file_eof.wl
// Focus: Keeping read_all at EOF after the first read on Windows and POSIX.

import "file"


func main() -> Int {
    let output = file.create("file_eof_data.tmp")?;
    catch(err) { return 1; }
    output.write_all("abcdef")?;
    catch(err) { return 1; }
    output.close_checked()?;
    catch(err) { return 1; }

    let source = file.open("file_eof_data.tmp")?;
    catch(err) { return 1; }
    let first = source.read_all()?;
    catch(err) { return 1; }
    let second = source.read_all()?;
    catch(err) { return 1; }
    source.close_checked()?;
    catch(err) { return 1; }
    file.remove("file_eof_data.tmp")?;
    catch(err) { return 1; }

    if (first != "abcdef" || second != "") {
        print("FAIL: read_all reread the file after EOF");
        return 1;
    }
    print("PASS: read_all stays at EOF");
    return 0;
}
