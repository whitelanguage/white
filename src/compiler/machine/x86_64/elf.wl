// src/compiler/machine/x86_64/elf.wl
import * from "model.wl"
import * from "../object.wl"
import elf64_object from "../elf.wl"
import machine_split_text from "../sections.wl"


func x86_elf_reloc_type(kind: X86RelocationKind, external_call: Bool) -> UInt32 {
    if (kind == X86RelocationKind.Call32) { return 4U; }
    if (kind == X86RelocationKind.Abs64) { return 1U; }
    if (kind == X86RelocationKind.Rel32) {
        if external_call { return 4U; }

        return 2U;
    }

    return 0U;
}

func x86_elf_relocations(
    relocations: Vector(X86Relocation),
    symbols: Vector(X86Symbol)
) -> Vector(MachineRelocation)? {
    let result: Vector(MachineRelocation) = [];
    let undefined: Dict(String, Bool) = Dict();
    for (let s = 0; s < symbols.length(); s++) {
        if (symbols[s].section.length() == 0) { undefined.put(symbols[s].name, true); }
    }
    let i: Int = 0;

    while (i < relocations.length()) {
        let source: X86Relocation = relocations[i];
        let external_call = false;
        if (source.kind == X86RelocationKind.Rel32) {
            external_call = undefined.get(source.symbol)?;
            catch(err) { external_call = false; }
        }

        let kind: UInt32 = x86_elf_reloc_type(source.kind, external_call);
        if (kind == 0U) { throw Error.InvalidArgument; }

        // ELF measures PC-relative x86 relocations from the immediate field.
        // Execution resumes four bytes later, therefore the RELA addend is -4.
        let addend: Long = source.addend;
        if (source.kind == X86RelocationKind.Rel32 || source.kind == X86RelocationKind.Call32) { addend -= 4L; }
        result.append(MachineRelocation(section=source.section, offset=source.offset, kind=kind, symbol=source.symbol, addend=addend));
        i++;
    }

    return result;
}

func elf_reloc_data(
    relocations: Vector(X86Relocation),
    section: String,
    symbols: Dict(String, Int),
    all_symbols: Vector(X86Symbol)
) -> Vector(Byte)? {
// retain the narrow helper used by the x86 ELF regression test
    let mapped: Vector(MachineRelocation) = x86_elf_relocations(relocations, all_symbols)?;
    let out: Vector(Byte) = [];
    let i: Int = 0;

    while (i < mapped.length()) {
        let relocation: MachineRelocation = mapped[i];
        if (relocation.section == section) {
            let symbol: Int = 0;
            symbol = symbols.get(relocation.symbol)?;
            catch(err) { symbol = 0; }
            if (symbol == 0) { throw Error.InvalidArgument; }

            let offset: UInt64 = UInt64(relocation.offset);
            let info: UInt64 = (UInt64(symbol) << 32UL) | UInt64(relocation.kind);
            let addend: UInt64 = 0UL;
            if (relocation.addend >= 0L) {
                addend = UInt64(relocation.addend);
            } else {
                let magnitude: UInt64 = UInt64(-(relocation.addend + 1L)) + 1UL;
                addend = (~magnitude) + 1UL;
            }

            let byte_index: Int = 0;
            while (byte_index < 8) {
                out.append(Byte((offset >> UInt64(byte_index * 8)) & 255UL));
                byte_index++;
            }
            byte_index = 0;
            while (byte_index < 8) {
                out.append(Byte((info >> UInt64(byte_index * 8)) & 255UL));
                byte_index++;
            }
            byte_index = 0;
            while (byte_index < 8) {
                out.append(Byte((addend >> UInt64(byte_index * 8)) & 255UL));
                byte_index++;
            }
        }
        i++;
    }

    return out;
}

func elf_object(input: X86Object) -> Vector(Byte)? {
    let sections: Vector(MachineSection) = [];
    let symbols: Vector(MachineSymbol) = [];
    let i: Int = 0;

    while (i < input.sections.length()) {
        let source: X86CodeSection = input.sections[i];
        sections.append(MachineSection(name=source.name, bytes=source.bytes, alignment=source.alignment, executable=source.executable, writable=source.writable));
        i++;
    }
    i = 0;
    while (i < input.symbols.length()) {
        let source: X86Symbol = input.symbols[i];
        symbols.append(MachineSymbol(name=source.name, section=source.section, offset=source.offset, external=source.external, hidden=source.section.length() != 0 && !source.external));
        i++;
    }

    let relocations: Vector(MachineRelocation) = x86_elf_relocations(input.relocations, input.symbols)?;
    let split = machine_split_text(MachineObject(machine=62U, sections=sections, symbols=symbols, relocations=relocations))?;
    return elf64_object(split)?;
}
