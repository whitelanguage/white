// Test: TARGET_MODEL
// File: tests/language/types/test_target_model.wl
// Focus: Target architecture, pointer width, ABI, and binary format agree.

import "sys"

func main() -> Int {
    let pointer_bits -> Int = Int(size_of(AnyPtr)) * 8;
    if (sys.POINTER_BITS != pointer_bits) {
        print("FAIL: target pointer width does not match AnyPtr");
        return 1;
    }

    let arch32 -> Bool = sys.ARCH == sys.Arch.X86 || sys.ARCH == sys.Arch.Arm;
    let arch64 -> Bool = sys.ARCH == sys.Arch.X86_64 || sys.ARCH == sys.Arch.AArch64;
    if ((arch32 && pointer_bits != 32) || (arch64 && pointer_bits != 64)) {
        print("FAIL: target architecture and pointer width disagree");
        return 1;
    }

    if ((sys.OS == sys.Os.Windows && sys.BINARY_FORMAT != sys.BinaryFormat.Coff) || (sys.OS == sys.Os.Linux && sys.BINARY_FORMAT != sys.BinaryFormat.Elf) || (sys.OS == sys.Os.MacOS && sys.BINARY_FORMAT != sys.BinaryFormat.MachO)) {
        print("FAIL: target operating system and binary format disagree");
        return 1;
    }

    print("PASS: target model");
    return 0;
}
