// src/compiler/machine/x86_64/elf.wl
import * from "object.wl"

struct ElfSection(
    name: String,
    kind: UInt32,
    flags: UInt64,
    align: UInt64,
    data: Vector(Byte),
    link: UInt32,
    info: UInt32,
    entsize: UInt64
)

func elf_u16(ref out: Vector(Byte), value: UInt32) -> Void {
    out.append(Byte(value & 255U));
    out.append(Byte((value >> 8U) & 255U));
}

func elf_u32(ref out: Vector(Byte), value: UInt32) -> Void {
    out.append(Byte(value & 255U));
    out.append(Byte((value >> 8U) & 255U));
    out.append(Byte((value >> 16U) & 255U));
    out.append(Byte((value >> 24U) & 255U));
}

func elf_u64(ref out: Vector(Byte), value: UInt64) -> Void {
    elf_u32(ref out, UInt32(value & 4294967295UL));
    elf_u32(ref out, UInt32((value >> 32UL) & 4294967295UL));
}

func elf_i64(ref out: Vector(Byte), value: Long) -> Void {
    if (value >= 0L) {
        elf_u64(ref out, UInt64(value));

        return;
    }

    let magnitude: UInt64 = UInt64(-(value + 1L)) + 1UL;
    elf_u64(ref out, (~magnitude) + 1UL);
}

func elf_copy(ref out: Vector(Byte), data: Vector(Byte)) -> Void {
    let i: Int = 0;

    while (i < data.length()) {
        out.append(data[i]);
        i += 1;
    }
}

func elf_align(value: Int, alignment: Int) -> Int {
    if (alignment <= 1) { return value; }
    let mask: Int = alignment - 1;

    if (value > 2147483647 - mask) { return -1; }

    return (value + mask) & -alignment;
}

func elf_section_index(sections: Vector(ElfSection), name: String) -> Int {
    let i: Int = 0;

    while (i < sections.length()) {
        if (sections[i].name == name) { return i; }
        i += 1;
    }

    return -1;
}

func elf_add_string(ref table: Vector(Byte), name: String, ref offsets: Dict(String, Int)) -> Int {
    let old: Int = offsets.lookup(name);

    if (old != 0 || name.length() == 0) { return old; }
    let offset: Int = table.length();
    let i: Int = 0;

    while (i < name.length()) {
        table.append(name[i]);
        i += 1;
    }
    table.append(Byte(0));
    offsets.put(name, offset);

    return offset;
}

func elf_reloc_data(
    relocations: Vector(MachineRelocation),
    section: String,
    symbols: Dict(String, Int)
) -> Vector(Byte)? {
// encode the RELA records for one section
    let out: Vector(Byte) = [];
    let i: Int = 0;

    while (i < relocations.length()) {
        let relocation: MachineRelocation = relocations[i];

        if (relocation.section == section) {
            let symbol: Int = symbols.lookup(relocation.symbol);

            if (symbol == 0 || relocation.kind == 0U) { throw Error.InvalidArgument; }
            elf_u64(ref out, UInt64(relocation.offset));
            elf_u64(ref out, (UInt64(symbol) << 32UL) | UInt64(relocation.kind));
            elf_i64(ref out, relocation.addend);
        }

        i += 1;
    }

    return out;
}

func elf64_object(input: MachineObject) -> Vector(Byte)? {
// serialize a target's sections and final ELF relocation numbers as ELF64
    if (input.machine == 0U || input.sections.length() == 0 || input.symbols.length() == 0) {
        throw Error.InvalidArgument;
    }

    let sections: Vector(ElfSection) = [];
    let i: Int = 0;

    while (i < input.sections.length()) {
        let source: MachineSection = input.sections[i];

        if (source.name.length() == 0 || elf_section_index(sections, source.name) >= 0) {
            throw Error.InvalidArgument;
        }

        let flags: UInt64 = 2UL;

        if (source.executable) { flags |= 4UL; }
        if (source.writable) { flags |= 1UL; }
        let align: UInt64 = UInt64(source.alignment);

        if (align == 0UL) { align = 1UL; }
        sections.append(ElfSection(name=source.name, kind=1U, flags=flags, align=align, data=source.bytes, link=0U, info=0U, entsize=0UL));
        i += 1;
    }

    let strtab: Vector(Byte) = [Byte(0)];
    let stroffsets: Dict(String, Int) = Dict();
    let sym_indices: Dict(String, Int) = Dict();
    i = 0;
    while (i < input.symbols.length()) {
        let symbol: MachineSymbol = input.symbols[i];

        if (symbol.name.length() == 0 || sym_indices.contains_key(symbol.name)) {
            throw Error.InvalidArgument;
        }
        elf_add_string(ref strtab, symbol.name, ref stroffsets);
        sym_indices.put(symbol.name, i + 1);
        i += 1;
    }

    let reloc_names: Vector(String) = [];
    i = 0;
    while (i < input.sections.length()) {
        let found: Bool = false;
        let j: Int = 0;

        while (j < input.relocations.length()) {
            if (input.relocations[j].section == input.sections[i].name) { found = true; }
            j += 1;
        }

        if found { reloc_names.append(".rela" + input.sections[i].name); }
        i += 1;
    }

    // Mark the object as not requiring an executable process stack. Without
    // this empty note GNU ld warns and may carry an executable-stack flag.
    if (elf_section_index(sections, ".note.GNU-stack") < 0) {
        sections.append(ElfSection(name=".note.GNU-stack", kind=1U, flags=0UL, align=1UL, data=[], link=0U, info=0U, entsize=0UL));
    }
    i = 0;
    while (i < reloc_names.length()) {
        sections.append(ElfSection(name=reloc_names[i], kind=4U, flags=0UL, align=8UL, data=[], link=0U, info=0U, entsize=24UL));
        i += 1;
    }

    let symtab_index: Int = sections.length();
    sections.append(ElfSection(name=".symtab", kind=2U, flags=0UL, align=8UL, data=[], link=0U, info=1U, entsize=24UL));
    let strtab_index: Int = sections.length();
    sections.append(ElfSection(name=".strtab", kind=3U, flags=0UL, align=1UL, data=strtab, link=0U, info=0U, entsize=0UL));
    let shstrtab_index: Int = sections.length();
    sections.append(ElfSection(name=".shstrtab", kind=3U, flags=0UL, align=1UL, data=[], link=0U, info=0U, entsize=0UL));

    let symtab: Vector(Byte) = [];
    elf_u32(ref symtab, 0U);
    let zero: Int = 0;

    while (zero < 20) {
        symtab.append(Byte(0));
        zero += 1;
    }
    i = 0;
    while (i < input.symbols.length()) {
        let symbol: MachineSymbol = input.symbols[i];
        let section: Int = elf_section_index(sections, symbol.section);
        let bind_type: UInt32 = 16U;

        if (symbol.section == ".text") { bind_type += 2U; }
        else if (symbol.section.length() != 0) { bind_type += 1U; }
        elf_u32(ref symtab, UInt32(stroffsets.lookup(symbol.name)));
        symtab.append(Byte(bind_type));
        symtab.append(Byte(0));
        if (section < 0) { elf_u16(ref symtab, 0U); }
        else {
            elf_u16(ref symtab, UInt32(section + 1));
        }
        elf_u64(ref symtab, UInt64(symbol.offset));
        elf_u64(ref symtab, 0UL);
        i += 1;
    }
    sections[symtab_index].data = symtab;
    sections[symtab_index].link = UInt32(strtab_index + 1);

    i = 0;
    while (i < reloc_names.length()) {
        let target: String = reloc_names[i].slice(5, reloc_names[i].length());
        let reloc: Vector(Byte) = elf_reloc_data(input.relocations, target, sym_indices)?;
        let section_index: Int = elf_section_index(sections, reloc_names[i]);

        if (section_index < 0) { throw Error.InvalidArgument; }
        sections[section_index].data = reloc;
        sections[section_index].link = UInt32(symtab_index + 1);
        sections[section_index].info = UInt32(elf_section_index(sections, target) + 1);
        i += 1;
    }

    let shstrtab: Vector(Byte) = [Byte(0)];
    let shoffsets: Dict(String, Int) = Dict();
    i = 0;
    while (i < sections.length()) {
        elf_add_string(ref shstrtab, sections[i].name, ref shoffsets);
        i += 1;
    }
    sections[shstrtab_index].data = shstrtab;

    let offsets: Vector(UInt64) = [];
    let file_size: Int = 64;
    i = 0;
    while (i < sections.length()) {
        let aligned: Int = elf_align(file_size, Int(sections[i].align));

        if (aligned < 0) { throw Error.Overflow; }
        offsets.append(UInt64(aligned));
        file_size = aligned + sections[i].data.length();
        i += 1;
    }

    let section_headers: Int = elf_align(file_size, 8);

    if (section_headers < 0 || sections.length() > 65534) { throw Error.Overflow; }

    let output: Vector(Byte) = [];
    let header: Int = 0;

    while (header < 64) {
        output.append(Byte(0));
        header += 1;
    }
    output[0] = Byte(127);
    output[1] = Byte(69);
    output[2] = Byte(76);
    output[3] = Byte(70);
    output[4] = Byte(2);
    output[5] = Byte(1);
    output[6] = Byte(1);
    output[16] = Byte(1);
    output[18] = Byte(input.machine & 255U);
    output[19] = Byte((input.machine >> 8U) & 255U);
    output[20] = Byte(1);
    output[52] = Byte(64);
    output[58] = Byte(64);
    output[60] = Byte(sections.length() + 1);
    output[62] = Byte(shstrtab_index + 1);

    let shoff: UInt64 = UInt64(section_headers);
    let shoff_index: Int = 40;
    let shoff_byte: Int = 0;

    while (shoff_byte < 8) {
        output[shoff_index + shoff_byte] = Byte((shoff >> UInt64(shoff_byte * 8)) & 255UL);
        shoff_byte += 1;
    }

    i = 0;
    while (i < sections.length()) {
        while (output.length() < Int(offsets[i])) { output.append(Byte(0)); }
        elf_copy(ref output, sections[i].data);
        i += 1;
    }

    while (output.length() < section_headers) { output.append(Byte(0)); }
    let null_header: Int = 0;

    while (null_header < 64) {
        output.append(Byte(0));
        null_header += 1;
    }

    i = 0;
    while (i < sections.length()) {
        elf_u32(ref output, UInt32(shoffsets.lookup(sections[i].name)));
        elf_u32(ref output, sections[i].kind);
        elf_u64(ref output, sections[i].flags);
        elf_u64(ref output, 0UL);
        elf_u64(ref output, offsets[i]);
        elf_u64(ref output, UInt64(sections[i].data.length()));
        elf_u32(ref output, sections[i].link);
        elf_u32(ref output, sections[i].info);
        elf_u64(ref output, sections[i].align);
        elf_u64(ref output, sections[i].entsize);
        i += 1;
    }

    return output;
}
