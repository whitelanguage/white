// core/WhitelangTarget.wl
import "sys"

let __target_triple -> String = "";
let __target_os -> Int = -1;
let __target_arch -> Int = -1;
let __target_abi -> Int = -1;
let __target_format -> Int = -1;
let __target_pointer_bits -> Int = 0;

func native_target_triple() -> String {
    if (sys.OS == sys.Os.Windows) {
        if (sys.ARCH == sys.Arch.X86) { return "i686-pc-windows-msvc"; }
        if (sys.ARCH == sys.Arch.X86_64) { return "x86_64-pc-windows-msvc"; }
    } else if (sys.OS == sys.Os.Linux) {
        if (sys.ARCH == sys.Arch.X86) { return "i686-unknown-linux-gnu"; }
        if (sys.ARCH == sys.Arch.X86_64) { return "x86_64-unknown-linux-gnu"; }
        if (sys.ARCH == sys.Arch.Arm) { return "armv7-unknown-linux-gnueabihf"; }
        if (sys.ARCH == sys.Arch.AArch64) { return "aarch64-unknown-linux-gnu"; }
    } else if (sys.OS == sys.Os.MacOS) {
        if (sys.ARCH == sys.Arch.X86_64) { return "x86_64-apple-darwin"; }
        if (sys.ARCH == sys.Arch.AArch64) { return "arm64-apple-darwin"; }
    }
    return "";
}

func __set_target(triple -> String, os -> sys.Os, arch -> sys.Arch, abi -> sys.Abi, format -> sys.BinaryFormat, pointer_bits -> Int) -> Void {
    __target_triple = triple;
    __target_os = Int(os);
    __target_arch = Int(arch);
    __target_abi = Int(abi);
    __target_format = Int(format);
    __target_pointer_bits = pointer_bits;
}

func select_target(triple -> String) -> Bool {
    if (triple == "native") {
        let native -> String = native_target_triple();
        if (native.length() == 0) { return false; }
        __set_target(native, sys.OS, sys.ARCH, sys.ABI, sys.BINARY_FORMAT, sys.POINTER_BITS);
        return true;
    }
    if (triple == "i686-pc-windows-msvc") { __set_target(triple, sys.Os.Windows, sys.Arch.X86, sys.Abi.Msvc, sys.BinaryFormat.Coff, 32); return true; }
    if (triple == "x86_64-pc-windows-msvc") { __set_target(triple, sys.Os.Windows, sys.Arch.X86_64, sys.Abi.Msvc, sys.BinaryFormat.Coff, 64); return true; }
    if (triple == "i686-unknown-linux-gnu") { __set_target(triple, sys.Os.Linux, sys.Arch.X86, sys.Abi.Gnu, sys.BinaryFormat.Elf, 32); return true; }
    if (triple == "x86_64-unknown-linux-gnu") { __set_target(triple, sys.Os.Linux, sys.Arch.X86_64, sys.Abi.Gnu, sys.BinaryFormat.Elf, 64); return true; }
    if (triple == "armv7-unknown-linux-gnueabihf") { __set_target(triple, sys.Os.Linux, sys.Arch.Arm, sys.Abi.Gnu, sys.BinaryFormat.Elf, 32); return true; }
    if (triple == "aarch64-unknown-linux-gnu") { __set_target(triple, sys.Os.Linux, sys.Arch.AArch64, sys.Abi.Gnu, sys.BinaryFormat.Elf, 64); return true; }
    if (triple == "x86_64-apple-darwin") { __set_target(triple, sys.Os.MacOS, sys.Arch.X86_64, sys.Abi.None, sys.BinaryFormat.MachO, 64); return true; }
    if (triple == "arm64-apple-darwin" || triple == "aarch64-apple-darwin") { __set_target("arm64-apple-darwin", sys.Os.MacOS, sys.Arch.AArch64, sys.Abi.None, sys.BinaryFormat.MachO, 64); return true; }
    return false;
}

func get_target_triple() -> String {
    if (__target_triple.length() == 0) { return native_target_triple(); }
    return __target_triple;
}

func get_target_os() -> sys.Os {
    if (__target_os == Int(sys.Os.Windows)) { return sys.Os.Windows; }
    if (__target_os == Int(sys.Os.Linux)) { return sys.Os.Linux; }
    if (__target_os == Int(sys.Os.MacOS)) { return sys.Os.MacOS; }
    return sys.Os.Unknown;
}

func get_target_arch() -> sys.Arch {
    if (__target_arch == Int(sys.Arch.X86)) { return sys.Arch.X86; }
    if (__target_arch == Int(sys.Arch.X86_64)) { return sys.Arch.X86_64; }
    if (__target_arch == Int(sys.Arch.Arm)) { return sys.Arch.Arm; }
    if (__target_arch == Int(sys.Arch.AArch64)) { return sys.Arch.AArch64; }
    return sys.Arch.Unknown;
}

func get_target_abi() -> sys.Abi {
    if (__target_abi == Int(sys.Abi.Msvc)) { return sys.Abi.Msvc; }
    if (__target_abi == Int(sys.Abi.Gnu)) { return sys.Abi.Gnu; }
    if (__target_abi == Int(sys.Abi.None)) { return sys.Abi.None; }
    return sys.Abi.Unknown;
}

func get_target_binary_format() -> sys.BinaryFormat {
    if (__target_format == Int(sys.BinaryFormat.Coff)) { return sys.BinaryFormat.Coff; }
    if (__target_format == Int(sys.BinaryFormat.Elf)) { return sys.BinaryFormat.Elf; }
    if (__target_format == Int(sys.BinaryFormat.MachO)) { return sys.BinaryFormat.MachO; }
    return sys.BinaryFormat.Unknown;
}

func get_target_pointer_bits() -> Int {
    return __target_pointer_bits;
}
