// src/compiler/machine/sections.wl
import * from "object.wl"


func machine_text_symbols(input: MachineObject) -> Vector(Int)? {
// ELF garbage collection works at section granularity. The lowering pass keeps
// one code buffer because branch patching is cheaper there, split it here once
// all function offsets are final.
    let result: Vector(Int) = [];
    let i: Int = 0;

    while (i < input.symbols.length()) {
        if (input.symbols[i].section == ".text") {
            if (result.length() != 0 &&
                input.symbols[result[result.length() - 1]].offset >= input.symbols[i].offset) {
                throw Error.InvalidArgument;
            }
            result.append(i);
        }
        i++;
    }

    let text_length: Int = -1;
    i = 0;
    while (i < input.sections.length()) {
        if (input.sections[i].name == ".text") {
            if (text_length >= 0) { throw Error.InvalidArgument; }
            text_length = input.sections[i].bytes.length();
        }
        i++;
    }
    // reachability may leave only data, or nothing at all. Nonempty code still
    // needs function boundaries before it can be split into ELF sections.
    if (result.length() == 0) {
        if (text_length > 0) { throw Error.InvalidArgument; }
        return result;
    }
    if (text_length <= 0) { throw Error.InvalidArgument; }

    i = 0;
    while (i < result.length()) {
        let offset: Int = Int(input.symbols[result[i]].offset);
        if (offset < 0 || offset >= text_length) {
            throw Error.InvalidArgument;
        }
        i++;
    }

    return result;
}

func machine_text_owner(input: MachineObject, ordered: Vector(Int), offset: UInt32) -> Int {
    let low: Int = 0;
    let high: Int = ordered.length();
    while (low < high) {
        let middle: Int = low + (high - low) / 2;
        if (input.symbols[ordered[middle]].offset <= offset) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }

    return low - 1;
}

func machine_split_text(input: MachineObject) -> MachineObject? {
    let sections: Vector(MachineSection) = [];
    let symbols: Vector(MachineSymbol) = [];
    let relocations: Vector(MachineRelocation) = [];
    let text_symbols: Vector(Int) = machine_text_symbols(input)?;
    let i: Int = 0;

    while (i < input.sections.length()) {
        let source: MachineSection = input.sections[i];
        if (source.name != ".text") {
            sections.append(MachineSection(name=source.name, bytes=source.bytes, alignment=source.alignment, executable=source.executable, writable=source.writable));
            i++;
            continue;
        }

        let function_index: Int = 0;
        while (function_index < text_symbols.length()) {
            let start: Int = Int(input.symbols[text_symbols[function_index]].offset);
            let end: Int = source.bytes.length();
            if (function_index + 1 < text_symbols.length()) {
                end = Int(input.symbols[text_symbols[function_index + 1]].offset);
            }
            if (start < 0 || end <= start || end > source.bytes.length()) { throw Error.InvalidArgument; }

            let code: Vector(Byte) = [];
            let byte_index: Int = start;
            while (byte_index < end) {
                code.append(source.bytes[byte_index]);
                byte_index++;
            }
            sections.append(MachineSection(name=".text." + function_index, bytes=code, alignment=source.alignment, executable=true, writable=false));
            function_index++;
        }
        i++;
    }
    i = 0;
    while (i < input.symbols.length()) {
        let source: MachineSymbol = input.symbols[i];
        let section: String = source.section;
        let offset: UInt32 = source.offset;
        if (section == ".text") {
            let owner: Int = machine_text_owner(input, text_symbols, offset);
            if (owner < 0) { throw Error.InvalidArgument; }

            section = ".text." + owner;
            offset -= input.symbols[text_symbols[owner]].offset;
        }
        symbols.append(MachineSymbol(name=source.name, section=section, offset=offset, external=source.external, hidden=source.hidden));
        i++;
    }
    i = 0;
    while (i < input.relocations.length()) {
        let source: MachineRelocation = input.relocations[i];
        let kind: UInt32 = source.kind;

        let section: String = source.section;
        let offset: UInt32 = source.offset;
        if (section == ".text") {
            let owner: Int = machine_text_owner(input, text_symbols, offset);
            if (owner < 0) { throw Error.InvalidArgument; }

            section = ".text." + owner;
            offset -= input.symbols[text_symbols[owner]].offset;
        }
        relocations.append(MachineRelocation(section=section, offset=offset, kind=kind, symbol=source.symbol, addend=source.addend));
        i++;
    }

    return MachineObject(machine=input.machine, sections=sections, symbols=symbols, relocations=relocations);
}
