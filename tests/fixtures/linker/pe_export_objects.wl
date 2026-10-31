// tests/fixtures/linker/pe_export_objects.wl
import CoffObject from "../../../src/linker/coff/model.wl"
import * from "../../../src/compiler/machine/x86_64/model.wl"
import pe_fixture_object from "pe_objects.wl"


func pe_export_object() -> CoffObject? {
    return pe_fixture_object(X86Object(sections=[
        X86CodeSection(name=".text", bytes=[Byte(184), Byte(37), Byte(0), Byte(0), Byte(0), Byte(195)], alignment=16, executable=true, writable=false),
        X86CodeSection(name=".data", bytes=[Byte(5), Byte(0), Byte(0), Byte(0)], alignment=4, executable=false, writable=true)],
        symbols=[X86Symbol(name="Answer", section=".text", offset=0U, external=true),
            X86Symbol(name="Constant", section=".data", offset=0U, external=true)], relocations=[]))?;
}
