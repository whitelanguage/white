// Test: LINK_INPUT_NAMES
// File: tests/linker/test_inputs.wl
// Focus: Archive suffixes and invalid logical library paths.
import is_archive_name, find_link_library from "../../src/linker/inputs.wl"


func main() -> Int {
    let valid = ["foo.lib", "FOO.LIB", "foo.LiB", "foo.a", "foo.A", "dir/foo.lib"];
    for (let i = 0; i < valid.length(); i++) {
        if (!is_archive_name(valid[i])) { return 1; }
    }
    let other = ["", "a", "foo", "foo.dll", "foo.lib.obj", "foo.library", "foo.a/"];
    for (let n = 0; n < other.length(); n++) {
        if (is_archive_name(other[n])) { return 1; }
    }
    let paths: Vector(String) = [];
    let invalid = ["../foo.lib", "dir\\foo.lib", "C:foo.lib", "foo.dll", "x" + String(Char(0)) + ".lib"];
    for (let bad = 0; bad < invalid.length(); bad++) {
        if (find_link_library(invalid[bad], paths).message.length() == 0) { return 1; }
    }
    print("PASS: Link input names");
    return 0;
}
