// src/compiler/machine/aarch64/elf.wl
import * from "model.wl"
import * from "../object.wl"
import elf64_object from "../elf.wl"
import machine_split_text from "../sections.wl"


func a64_elf_reloc_type(kind: A64RelocationKind) -> UInt32 {
// Values are from the ELF for the Arm 64-bit Architecture relocation table.
    if (kind == A64RelocationKind.Abs64) { return 257U; }
    if (kind == A64RelocationKind.Page21) { return 275U; }
    if (kind == A64RelocationKind.PageOffset12) { return 277U; }
    if (kind == A64RelocationKind.Jump26) { return 282U; }
    if (kind == A64RelocationKind.Call26) { return 283U; }
    if (kind == A64RelocationKind.GotPage21) { return 311U; }
    if (kind == A64RelocationKind.GotOffset12) { return 312U; }

    return 0U;
}

func a64_elf_object(input: A64Object) -> Vector(Byte)? {
    let sections: Vector(MachineSection) = [];
    let symbols: Vector(MachineSymbol) = [];
    let relocs: Vector(MachineRelocation) = [];
    for (let i = 0; i < input.sections.length(); i++) {
        let s = input.sections[i];
        sections.append(MachineSection(name=s.name, bytes=s.bytes, alignment=s.alignment, executable=s.executable, writable=s.writable));
    }
    for (let j = 0; j < input.symbols.length(); j++) {
        let s = input.symbols[j];
        symbols.append(MachineSymbol(name=s.name, section=s.section, offset=s.offset, external=s.external, hidden=s.hidden));
    }
    for (let k = 0; k < input.relocations.length(); k++) {
        let r = input.relocations[k];
        let kind = a64_elf_reloc_type(r.kind);
        if (kind == 0U) { throw Error.InvalidArgument; }
        relocs.append(MachineRelocation(section=r.section, offset=r.offset, kind=kind, symbol=r.symbol, addend=r.addend));
    }

    let split = machine_split_text(MachineObject(machine=183U, sections=sections, symbols=symbols, relocations=relocs))?;
    return elf64_object(split)?;
}
