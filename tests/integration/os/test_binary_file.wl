// Test: BINARY_FILE_IO
// File: tests/integration/os/test_binary_file.wl
// Focus: Writing byte buffers without treating them as UTF-8 text.

import "file"

func main() -> Int {
    let path: String = "test_binary_file.tmp";
    let output: file.File = file.create(path)?;
    catch(err) {
        print("FAIL: Could not create binary test file");
        return 1;
    }
    let bytes: Vector(Byte) = [Byte(0), Byte(255), Byte(128), Byte(10), Byte(65)];
    let written: Int = output.write_bytes(bytes)?;
    catch(err) {
        print("FAIL: Could not write binary data");
        return 1;
    }
    output.close();

    let input: file.File = file.open(path)?;
    catch(err) {
        print("FAIL: Could not reopen binary test file");
        return 1;
    }
    let contents: String = input.read_all()?;
    catch(err) {
        print("FAIL: Could not read binary data");
        return 1;
    }
    input.close();
    file.remove(path)?;
    catch(err) {
        print("FAIL: Could not remove binary test file");
        return 1;
    }

    if (written != 5 || contents.length() != 5 || contents[0] != Byte(0) || contents[1] != Byte(255) || contents[2] != Byte(128) || contents[3] != Byte(10) || contents[4] != Byte(65)) {
        print("FAIL: Binary file contents changed during I/O");
        return 1;
    }
    print("PASS: Binary file I/O");
    return 0;
}
