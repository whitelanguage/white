// tests/fixtures/linker/pe_objects.wl
import CoffObject from "../../../src/linker/coff/model.wl"
import read_coff from "../../../src/linker/coff/reader.wl"
import * from "../../../src/compiler/machine/x86_64/model.wl"
import coff_object from "../../../src/compiler/machine/x86_64/coff.wl"


func pe_fixture_object(source: X86Object) -> CoffObject? {
    let bytes = coff_object(source)?;
    let result = read_coff(bytes);
    if (result.object is null) { throw Error.InvalidArgument; }
    return result.object;
}

func pe_leaf_object() -> CoffObject? {
    return pe_fixture_object(X86Object(sections=[X86CodeSection(name=".text", bytes=[Byte(184), Byte(42), Byte(0), Byte(0), Byte(0), Byte(195)], alignment=16, executable=true, writable=false)],
        symbols=[X86Symbol(name="entry", section=".text", offset=0U, external=true)], relocations=[]))?;
}

func pe_pointer_object() -> CoffObject? {
// a relocated data pointer is dereferenced by a leaf function, no imports or runtime helpers
    return pe_fixture_object(X86Object(sections=[
        X86CodeSection(name=".text", bytes=[Byte(72), Byte(139), Byte(5), Byte(0), Byte(0), Byte(0), Byte(0), Byte(139), Byte(0), Byte(195)], alignment=16, executable=true, writable=false),
        X86CodeSection(name=".data", bytes=[Byte(0), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0)], alignment=8, executable=false, writable=true),
        X86CodeSection(name=".rdata", bytes=[Byte(42), Byte(0), Byte(0), Byte(0)], alignment=4, executable=false, writable=false)],
        symbols=[X86Symbol(name="entry", section=".text", offset=0U, external=true), X86Symbol(name="pointer", section=".data", offset=0U, external=true), X86Symbol(name="answer", section=".rdata", offset=0U, external=true)],
        relocations=[X86Relocation(section=".text", offset=3U, kind=X86RelocationKind.Rel32, symbol="pointer", addend=0L), X86Relocation(section=".data", offset=0U, kind=X86RelocationKind.Abs64, symbol="answer", addend=0L)]))?;
}

func pe_caller_object() -> CoffObject? {
    return pe_fixture_object(X86Object(sections=[X86CodeSection(name=".text$Z", bytes=[Byte(72), Byte(131), Byte(236), Byte(40), Byte(232), Byte(0), Byte(0), Byte(0), Byte(0), Byte(72), Byte(131), Byte(196), Byte(40), Byte(195)], alignment=16, executable=true, writable=false)],
        symbols=[X86Symbol(name="entry", section=".text$Z", offset=0U, external=true), X86Symbol(name="answer", section="", offset=0U, external=true)],
        relocations=[X86Relocation(section=".text$Z", offset=5U, kind=X86RelocationKind.Call32, symbol="answer", addend=0L)]))?;
}

func pe_answer_object() -> CoffObject? {
    return pe_fixture_object(X86Object(sections=[X86CodeSection(name=".text$A", bytes=[Byte(184), Byte(42), Byte(0), Byte(0), Byte(0), Byte(195)], alignment=16, executable=true, writable=false)],
        symbols=[X86Symbol(name="answer", section=".text$A", offset=0U, external=true)], relocations=[]))?;
}

func pe_bss_object() -> CoffObject? {
    let object = pe_fixture_object(X86Object(sections=[
        X86CodeSection(name=".text", bytes=[Byte(139), Byte(5), Byte(0), Byte(0), Byte(0), Byte(0), Byte(195)], alignment=16, executable=true, writable=false),
        X86CodeSection(name=".bss", bytes=[], alignment=8, executable=false, writable=true)],
        symbols=[X86Symbol(name="entry", section=".text", offset=0U, external=true), X86Symbol(name="zero", section=".bss", offset=0U, external=true)],
        relocations=[X86Relocation(section=".text", offset=2U, kind=X86RelocationKind.Rel32, symbol="zero", addend=0L)]))?;
    object.sections[1].size = 8192U;
    object.sections[1].flags = 0xC0000080U;
    return object;
}
