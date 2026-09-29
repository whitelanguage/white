// Test: X86_64_COFF
// File: tests/machine/x86_64/test_coff.wl
// Focus: Validate COFF inputs and preserve section relocation counts above 65535.

import * from "../../../src/compiler/machine/x86_64/model.wl"
import * from "../../../src/compiler/machine/x86_64/coff.wl"
import WirModule from "../../../src/compiler/wir/model.wl"
import new_wir_module from "../../../src/compiler/wir/builder.wl"
import X86ModuleResult, x86_lower_module from "../../../src/compiler/machine/x86_64/lowering.wl"

func read_u32(bytes: Vector(Byte), offset: Int) -> UInt32 {
    return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8U) | (UInt32(bytes[offset + 2]) << 16U) | (UInt32(bytes[offset + 3]) << 24U);
}

func rejected(object: X86Object) -> Bool {
    coff_object(object)?;
    catch(err) { return true; }
    return false;
}

func main() -> Int {
    let win32_program: WirModule = new_wir_module("i686-pc-windows-msvc", 32);
    let linux_program: WirModule = new_wir_module("x86_64-unknown-linux-gnu", 64);
    let win32: X86ModuleResult = x86_lower_module(ref win32_program);
    let linux: X86ModuleResult = x86_lower_module(ref linux_program);
    if (win32.errors.length() == 0 || linux.errors.length() == 0) {
        print("FAIL: the Win64 machine backend accepted an incompatible target");
        return 1;
    }
    let code: X86CodeSection = X86CodeSection(name=".text", bytes=[Byte(195)], alignment=16, executable=true, writable=false);
    let symbol: X86Symbol = X86Symbol(name="main", section=".text", offset=0U, external=true);
    if (!rejected(X86Object(sections=[code, code], symbols=[symbol], relocations=[])) || !rejected(X86Object(sections=[code], symbols=[symbol, symbol], relocations=[]))) {
        print("FAIL: duplicate COFF sections or symbols were accepted");
        return 1;
    }
    let bad: X86Relocation = X86Relocation(section=".text", offset=0U, kind=X86RelocationKind.Rel32, symbol="main", addend=0L);
    if (!rejected(X86Object(sections=[code], symbols=[symbol], relocations=[bad]))) {
        print("FAIL: out-of-range COFF relocation was accepted");
        return 1;
    }
    let data: Vector(Byte) = [];
    let relocations: Vector(X86Relocation) = [];
    let i: Int = 0;
    while (i < 65536) {
        data.append(Byte(0));
        data.append(Byte(0));
        data.append(Byte(0));
        data.append(Byte(0));
        relocations.append(X86Relocation(section=".text", offset=UInt32(i * 4), kind=X86RelocationKind.Rel32, symbol="main", addend=0L));
        i++;
    }
    code.bytes = data;
    let object: Vector(Byte) = coff_object(X86Object(sections=[code], symbols=[symbol], relocations=relocations))?;
    catch(err) {
        print("FAIL: COFF relocation overflow table was rejected");
        return 1;
    }
    let relocation_offset: Int = Int(read_u32(object, 44));
    if (object[52] != Byte(255) || object[53] != Byte(255) || (read_u32(object, 56) & 16777216U) == 0U || read_u32(object, relocation_offset) != 65537U) {
        print("FAIL: COFF extended relocation count is incorrect");
        return 1;
    }
    if (read_u32(object, relocation_offset + 10) != 0U || read_u32(object, relocation_offset + 65536 * 10) != 262140U) {
        print("FAIL: COFF overflow record lost a relocation");
        return 1;
    }
    if (read_u32(object, 8) != UInt32(relocation_offset + 65537 * 10)) {
        print("FAIL: COFF symbol table overlaps the extended relocation table");
        return 1;
    }
    print("PASS: x86_64 COFF validation and extended relocations");
    return 0;
}
