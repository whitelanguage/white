// src/compiler/machine/aarch64/elf.wl
import * from "model.wl"
import * from "../object.wl"
import elf64_object from "../elf.wl"


func a64_elf_reloc_type(kind: A64RelocationKind) -> UInt32 {
// Values are from the ELF for the Arm 64-bit Architecture relocation table.
    if (kind == A64RelocationKind.Abs64) { return 257U; }
    if (kind == A64RelocationKind.Page21) { return 275U; }
    if (kind == A64RelocationKind.PageOffset12) { return 277U; }
    if (kind == A64RelocationKind.Jump26) { return 282U; }
    if (kind == A64RelocationKind.Call26) { return 283U; }

    return 0U;
}

func a64_elf_object(input: A64Object) -> Vector(Byte)? {
    let sections: Vector(MachineSection) = [];
    let symbols: Vector(MachineSymbol) = [];
    let relocations: Vector(MachineRelocation) = [];
    let i: Int = 0;

    while (i < input.sections.length()) {
        let source: A64Section = input.sections[i];
        sections.append(MachineSection(name=source.name, bytes=source.bytes, alignment=source.alignment, executable=source.executable, writable=source.writable));
        i++;
    }
    i = 0;
    while (i < input.symbols.length()) {
        let source: A64Symbol = input.symbols[i];
        symbols.append(MachineSymbol(name=source.name, section=source.section, offset=source.offset, external=source.external));
        i++;
    }
    i = 0;
    while (i < input.relocations.length()) {
        let source: A64Relocation = input.relocations[i];
        let kind: UInt32 = a64_elf_reloc_type(source.kind);
        if (kind == 0U) { throw Error.InvalidArgument; }

        relocations.append(MachineRelocation(section=source.section, offset=source.offset, kind=kind, symbol=source.symbol, addend=source.addend));
        i++;
    }

    return elf64_object(MachineObject(machine=183U, sections=sections, symbols=symbols, relocations=relocations))?;
}
