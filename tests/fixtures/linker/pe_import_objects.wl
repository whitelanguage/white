// tests/fixtures/linker/pe_import_objects.wl
import CoffObject from "../../../src/linker/coff/model.wl"
import * from "../../../src/compiler/machine/x86_64/model.wl"
import pe_fixture_object from "pe_objects.wl"


func pe_api_object() -> CoffObject? {
// mix a direct call through a linker thunk with an indirect call through the IAT
    return pe_fixture_object(X86Object(sections=[X86CodeSection(name=".text", bytes=[
        Byte(72), Byte(131), Byte(236), Byte(40), Byte(185), Byte(42), Byte(0), Byte(0), Byte(0),
        Byte(232), Byte(0), Byte(0), Byte(0), Byte(0), Byte(255), Byte(21), Byte(0), Byte(0), Byte(0), Byte(0),
        Byte(72), Byte(131), Byte(196), Byte(40), Byte(195)], alignment=16, executable=true, writable=false)],
        symbols=[X86Symbol(name="entry", section=".text", offset=0U, external=true),
            X86Symbol(name="SetLastError", section="", offset=0U, external=true), X86Symbol(name="__imp_GetLastError", section="", offset=0U, external=true)],
        relocations=[X86Relocation(section=".text", offset=10U, kind=X86RelocationKind.Call32, symbol="SetLastError", addend=0L),
            X86Relocation(section=".text", offset=16U, kind=X86RelocationKind.Rel32, symbol="__imp_GetLastError", addend=0L)]))?;
}

func pe_import_refs(names: Vector(String)) -> CoffObject? {
// data references exercise selection without needing executable code for every export
    let bytes: Vector(Byte) = [];
    let symbols: Vector(X86Symbol) = [];
    let seen: Dict(String, Bool) = Dict();
    let relocs: Vector(X86Relocation) = [];
    let i = 0;
    while (i < names.length()) {
        let offset = UInt32(bytes.length());
        let j = 0;
        while (j < 8) { bytes.append(Byte(0)); j++; }
        if (!seen.contains_key(names[i])) {
            symbols.append(X86Symbol(name=names[i], section="", offset=0U, external=true));
            seen.put(names[i], true);
        }
        relocs.append(X86Relocation(section=".data", offset=offset, kind=X86RelocationKind.Abs64, symbol=names[i], addend=0L));
        i++;
    }
    return pe_fixture_object(X86Object(sections=[X86CodeSection(name=".data", bytes=bytes, alignment=8, executable=false, writable=true)],
        symbols=symbols, relocations=relocs))?;
}

func pe_ordinal_object() -> CoffObject? {
// the optional native DLL supplies ordinal 7 returning 37 and a data export containing 5
    return pe_fixture_object(X86Object(sections=[X86CodeSection(name=".text", bytes=[
        Byte(72), Byte(131), Byte(236), Byte(40), Byte(232), Byte(0), Byte(0), Byte(0), Byte(0),
        Byte(76), Byte(139), Byte(21), Byte(0), Byte(0), Byte(0), Byte(0), Byte(65), Byte(3), Byte(2),
        Byte(72), Byte(131), Byte(196), Byte(40), Byte(195)], alignment=16, executable=true, writable=false)],
        symbols=[X86Symbol(name="entry", section=".text", offset=0U, external=true),
            X86Symbol(name="Answer", section="", offset=0U, external=true), X86Symbol(name="__imp_Constant", section="", offset=0U, external=true)],
        relocations=[X86Relocation(section=".text", offset=5U, kind=X86RelocationKind.Call32, symbol="Answer", addend=0L),
            X86Relocation(section=".text", offset=12U, kind=X86RelocationKind.Rel32, symbol="__imp_Constant", addend=0L)]))?;
}
