// std/sys/target.wl
// compile-time properties of the selected target

enum Os {
    Windows = 0,
    Linux = 1,
    MacOS = 2,
    Unknown = 3,
}

enum Arch {
    X86 = 0,
    X86_64 = 1,
    Arm = 2,
    AArch64 = 3,
    Unknown = 10,
}

enum Abi {
    Msvc = 0,
    Gnu = 1,
    None = 3,
    Unknown = 4,
}

enum BinaryFormat {
    Coff = 0,
    Elf = 1,
    MachO = 2,
    Unknown = 4,
}

@CompilerIntrinsic("target_os")
const OS -> Os = Os.Unknown;

@CompilerIntrinsic("target_arch")
const ARCH -> Arch = Arch.Unknown;

@CompilerIntrinsic("target_abi")
const ABI -> Abi = Abi.Unknown;

@CompilerIntrinsic("target_binary_format")
const BINARY_FORMAT -> BinaryFormat = BinaryFormat.Unknown;

@CompilerIntrinsic("target_pointer_bits")
const POINTER_BITS -> Int = 0;
