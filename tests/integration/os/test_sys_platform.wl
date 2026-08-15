// Test: SYS_PLATFORM_DETECTION
// File: tests/integration/os/test_sys_platform.wl
// Focus: Standard library system module integration, platform constant resolution, and conditional branching.

import "sys"

func platform_value() -> Int {
    if (sys.OS == sys.Os.Windows) {
        return 7;
    } else if (sys.OS == sys.Os.Linux) {
        return 9;
    } else if (sys.OS == sys.Os.MacOS) {
        return 11;
    }
    return 0;
}

func main() -> Int {
    let os: sys.Os = sys.OS;
    let arch: sys.Arch = sys.ARCH;
    let abi: sys.Abi = sys.ABI;
    let format: sys.BinaryFormat = sys.BINARY_FORMAT;

    if (os == sys.Os.Unknown) {
        print("FAIL: sys.OS is unknown");
        return 1;
    }

    if (arch == sys.Arch.Unknown) { print("FAIL: sys.ARCH is unknown"); return 1; }
    if (abi == sys.Abi.Unknown) { print("FAIL: sys.ABI is unknown"); return 1; }
    if (format == sys.BinaryFormat.Unknown) { print("FAIL: sys.BINARY_FORMAT is unknown"); return 1; }
    if (sys.POINTER_BITS != Int(size_of(AnyPtr)) * 8) { print("FAIL: sys.POINTER_BITS does not match the data model"); return 1; }
    if (sys.OS == sys.Os.Windows) {
        if (sys.ABI != sys.Abi.Msvc || sys.BINARY_FORMAT != sys.BinaryFormat.Coff) { print("FAIL: invalid Windows target"); return 1; }
        if (platform_value() != 7) {
            print("FAIL: compile-time platform return");
            return 1;
        }
    } else if (sys.OS == sys.Os.Linux) {
        if (sys.ABI != sys.Abi.Gnu || sys.BINARY_FORMAT != sys.BinaryFormat.Elf) { print("FAIL: invalid Linux target"); return 1; }
        if (platform_value() != 9) {
            print("FAIL: compile-time platform return");
            return 1;
        }
    } else if (sys.OS == sys.Os.MacOS) {
        if (sys.ABI != sys.Abi.None || sys.BINARY_FORMAT != sys.BinaryFormat.MachO) { print("FAIL: invalid macOS target"); return 1; }
        if (platform_value() != 11) {
            print("FAIL: compile-time platform return");
            return 1;
        }
    }

    if (sys.OS == sys.Os.Windows) {
        print("PASS: sys.OS WINDOWS");
    } else if (sys.OS == sys.Os.Linux) {
        print("PASS: sys.OS LINUX");
    } else if (sys.OS == sys.Os.MacOS) {
        print("PASS: sys.OS MACOS");
    } else {
        print("FAIL: unknown sys.OS");
        return 1;
    }
    return 0;
}
