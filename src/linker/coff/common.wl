// src/linker/coff/common.wl
import * from "model.wl"
import * from "link_model.wl"
import CoffNameIndex, coff_define_symbol, coff_is_common from "symbols.wl"
import coff_range from "reader.wl"


struct CoffAllocation(objects: Vector(CoffObject) = [], errors: Vector(CoffLinkError) = [])

func coff_common_align(size: UInt32) -> Int {
// COFF has no common alignment field, link.exe rounds up naturally with a 32-byte cap
    let align = 1;
    while (align < 32 && UInt32(align) < size) { align <<= 1; }
    return align;
}

func coff_allocate_common(inputs: Vector(CoffObject)) -> CoffAllocation {
// defer allocation until the selected archive members have supplied their real definitions
    let found = false;
    for (let probe = 0; probe < inputs.length(); probe++) {
        for (let sym = 0; sym < inputs[probe].symbols.length(); sym++) {
            if (coff_is_common(inputs[probe].symbols[sym])) { found = true; break; }
        }
        if found { break; }
    }
    if (!found) { return CoffAllocation(objects=inputs); }

    let names = CoffNameIndex();
    for (let obj = 0; obj < inputs.length(); obj++) {
        let object = inputs[obj];
        for (let s = 0; s < object.symbols.length(); s++) {
            let symbol = object.symbols[s];
            if (symbol.storage != Byte(2)) { continue; }
            if (symbol.section < -2 || symbol.section > object.sections.length() ||
                !coff_range(object.bytes.length(), Long(symbol.name.offset), Long(symbol.name.size), 1)) {
                return CoffAllocation(errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject, object=obj, symbol=s,
                    message="Invalid symbol record supplied to common allocation")]);
            }
            if (symbol.section > 0 && object.sections[symbol.section - 1].discarded) { continue; }
            if (coff_is_common(symbol) && symbol.name.size == 0) {
                return CoffAllocation(errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject, object=obj, symbol=s,
                    message="Common symbol requires a name")]);
            }
            if (symbol.section > 0 || symbol.section == -1 || coff_is_common(symbol)) {
                if (!coff_define_symbol(inputs, ref names, CoffSymbolRef(obj, s))) {
                    return CoffAllocation(errors=[CoffLinkError(status=CoffLinkStatus.DuplicateSymbol, object=obj, symbol=s,
                        message="Duplicate external symbol definition")]);
                }
            }
        }
    }

    let generated = CoffObject(bytes=[Byte(46), Byte(98), Byte(115), Byte(115)]);
    let size = 0L;
    let max_align = 1;
    for (let entry = 0; entry < names.entries.length(); entry++) {
        let definition = names.entries[entry].definition;
        let symbol = inputs[definition.object].symbols[definition.symbol];
        if (!coff_is_common(symbol)) { continue; }

        let align = Long(coff_common_align(symbol.value));
        if (align > Long(max_align)) { max_align = Int(align); }
        let offset = ((size + align - 1L) / align) * align;
        size = offset + Long(symbol.value);
        if (size > 2147483647L || Long(generated.bytes.length()) + Long(symbol.name.size) > 2147483647L) {
            return CoffAllocation(errors=[CoffLinkError(status=CoffLinkStatus.InvalidLayout, object=definition.object,
                symbol=definition.symbol, message="Common storage exceeds the PE image range")]);
        }
        let name = generated.bytes.length();
        let bytes = inputs[definition.object].bytes;
        for (let n = 0; n < symbol.name.size; n++) { generated.bytes.append(bytes[symbol.name.offset + n]); }
        let id = generated.symbols.length();
        generated.symbols.append(CoffSymbol(name=CoffSpan(name, symbol.name.size), value=UInt32(offset), section=1,
            type=symbol.type, storage=Byte(2), table_index=id, aux=CoffSpan()));
        generated.symbol_map.append(id);
    }
    if (generated.symbols.length() == 0) { return CoffAllocation(objects=inputs); }
    // BSS records virtual size only, even a large common must not grow an output byte buffer.
    let code = 1U;
    let step = 1;
    while (step < max_align) { step <<= 1; code++; }
    generated.sections.append(CoffSection(name=CoffSpan(0, 4), size=UInt32(size), address=0U, data=CoffSpan(),
        flags=0xC0000080U | (code << 20U), alignment=max_align, relocs=[], lines=CoffSpan()));
    let objects: Vector(CoffObject) = [];
    for (let copy = 0; copy < inputs.length(); copy++) { objects.append(inputs[copy]); }
    objects.append(generated);
    return CoffAllocation(objects=objects);
}
