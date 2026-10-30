// src/linker/coff/reloc.wl
// AMD64 formulas: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
import * from "model.wl"
import * from "link_model.wl"
import coff_range, coff_u16, coff_u32, coff_reloc_width from "reader.wl"


func coff_u64(bytes: Vector(Byte), offset: Int) -> UInt64 {
    return UInt64(coff_u32(bytes, offset)) | (UInt64(coff_u32(bytes, offset + 4)) << 32UL);
}

func coff_signed_addend(bytes: Vector(Byte), offset: Int, width: Int) -> Int128 {
// addends live in the original field, retain their sign before widening the sum
    let value: Int128 = Int128(coff_u32(bytes, offset));
    if (width == 8) {
        let word: UInt64 = coff_u64(bytes, offset);
        value = Int128(UInt128(word));
        if ((word & 9223372036854775808UL) != 0UL) {
            value -= Int128(UInt128(1U) << UInt128(64U));
        }
    } else if (value >= Int128(2147483648L)) {
        value -= Int128(4294967296L);
    }
    return value;
}

func coff_put_word(bytes: Vector(Byte), offset: Int, width: Int, value: UInt64) -> Void {
    let i: Int = 0;
    while (i < width) {
        bytes[offset + i] = Byte((value >> UInt64(i * 8)) & 255UL);
        i++;
    }
}

func coff_patch_error(status: CoffLinkStatus, object: Int, section: Int, reloc: CoffReloc, message: String) -> CoffPatchResult {
    return CoffPatchResult(diagnostic=CoffLinkError(status=status, object=object, section=section, symbol=reloc.symbol, offset=reloc.offset, message=message));
}

func coff_reloc_overlap(relocs: Vector(CoffReloc)) -> Int {
// most producers emit ordered fields, allocate sort buffers only for the other case
    let end: Long = 0L;
    let ordered: Bool = true;
    let i: Int = 0;
    while (i < relocs.length()) {
        let width: Int = coff_reloc_width(relocs[i].kind);
        if (width > 0) {
            if (Long(relocs[i].offset) < end) { ordered = false; break; }
            end = Long(relocs[i].offset) + Long(width);
        }
        i++;
    }
    if ordered { return -1; }

    let order: Vector(Int) = [];
    let scratch: Vector(Int) = [];
    i = 0;
    while (i < relocs.length()) {
        if (coff_reloc_width(relocs[i].kind) > 0) {
            order.append(i);
            scratch.append(0);
        }
        i++;
    }
    // bottom-up mergesort bounds work and stack depth even for adversarial ordering.
    let run: Int = 1;
    let count: Int = order.length();
    while (run < count) {
        let start: Int = 0;
        while (start < count) {
            let mid: Int = count;
            if (run <= count - start) { mid = start + run; }
            let finish: Int = mid;
            if (run <= count - mid) { finish = mid + run; }
            else { finish = count; }
            let left: Int = start;
            let right: Int = mid;
            let out: Int = start;
            while (out < finish) {
                if (right == finish || (left < mid && relocs[order[left]].offset <= relocs[order[right]].offset)) {
                    scratch[out] = order[left];
                    left++;
                } else {
                    scratch[out] = order[right];
                    right++;
                }
                out++;
            }
            start = finish;
        }
        let swap: Vector(Int) = order;
        order = scratch;
        scratch = swap;
        if (run > count / 2) { run = count; }
        else { run *= 2; }
    }
    end = 0L;
    i = 0;
    while (i < count) {
        let item: Int = order[i];
        if (Long(relocs[item].offset) < end) { return item; }
        end = Long(relocs[item].offset) + Long(coff_reloc_width(relocs[item].kind));
        i++;
    }
    return -1;
}

func coff_apply_section(objects: Vector(CoffObject), symbols: CoffSymbolResult, layout: Vector(Vector(CoffPlacement)), image_base: UInt64, object_id: Int, section_id: Int) -> CoffPatchResult {
// copy one contribution before patching, failed links leave the input objects intact
    let dummy: CoffReloc = CoffReloc(0U, -1, 0U);
    if (symbols.errors.length() != 0 || object_id < 0 || object_id >= objects.length() || layout.length() != objects.length() || symbols.targets.length() != objects.length()) {
        return coff_patch_error(CoffLinkStatus.InvalidLayout, object_id, section_id, dummy, "Invalid relocation input or unresolved symbols");
    }
    let object: CoffObject = objects[object_id];
    if (section_id < 0 || section_id >= object.sections.length() || layout[object_id].length() != object.sections.length() || symbols.targets[object_id].length() != object.symbols.length()) {
        return coff_patch_error(CoffLinkStatus.InvalidLayout, object_id, section_id, dummy, "Missing section placement or symbol mapping");
    }
    let section: CoffSection = object.sections[section_id];
    let place: CoffPlacement = layout[object_id][section_id];
    if (place.section <= 0 || place.section > 65535 || place.offset > place.rva || Long(place.rva) + Long(section.size) > 4294967296L ||
        Int128(UInt128(image_base)) + Int128(place.rva) + Int128(section.size) > Int128(UInt128(18446744073709551615UL))) {
        return coff_patch_error(CoffLinkStatus.InvalidLayout, object_id, section_id, dummy, "Section placement exceeds the image address range");
    }
    if (!coff_range(object.bytes.length(), Long(section.data.offset), Long(section.data.size), 1) ||
        (section.data.size != 0 && Long(section.data.size) != Long(section.size))) {
        return coff_patch_error(CoffLinkStatus.InvalidObject, object_id, section_id, dummy, "Invalid section data span");
    }
    let overlap: Int = coff_reloc_overlap(section.relocs);
    if (overlap >= 0) {
        return coff_patch_error(CoffLinkStatus.Unsupported, object_id, section_id, section.relocs[overlap], "Overlapping relocation fields are not supported");
    }

    let patch: CoffPatch = CoffPatch();
    let i: Int = 0;
    while (i < section.data.size) {
        patch.bytes.append(object.bytes[section.data.offset + i]);
        i++;
    }
    i = 0;
    while (i < section.relocs.length()) {
        let reloc: CoffReloc = section.relocs[i];
        let width: Int = coff_reloc_width(reloc.kind);
        if (reloc.kind == 0U) { i++; continue; }
        if (width < 0 || reloc.kind >= 12U) {
            return coff_patch_error(CoffLinkStatus.Unsupported, object_id, section_id, reloc, "Unsupported AMD64 relocation application");
        }
        if (!coff_range(section.data.size, Long(reloc.offset), 1L, width) || reloc.symbol < 0 || reloc.symbol >= object.symbols.length()) {
            return coff_patch_error(CoffLinkStatus.InvalidObject, object_id, section_id, reloc, "Relocation has no initialized field or valid symbol");
        }
        let target: CoffSymbolRef = symbols.targets[object_id][reloc.symbol];
        if (target.object < 0 || target.object >= objects.length() || target.symbol < 0 || target.symbol >= objects[target.object].symbols.length()) {
            return coff_patch_error(CoffLinkStatus.UndefinedSymbol, object_id, section_id, reloc, "Missing relocation target");
        }
        let definition: CoffSymbol = objects[target.object].symbols[target.symbol];
        let absolute: Bool = definition.section == -1;
        let target_place: CoffPlacement = CoffPlacement(0U, 0);
        let target_rva: Int128 = Int128(definition.value) - Int128(UInt128(image_base));
        let target_va: Int128 = Int128(definition.value);
        if (!absolute) {
            if (definition.section <= 0 || definition.section > objects[target.object].sections.length() || layout[target.object].length() != objects[target.object].sections.length()) {
                return coff_patch_error(CoffLinkStatus.InvalidLayout, object_id, section_id, reloc, "Missing target section placement");
            }
            target_place = layout[target.object][definition.section - 1];
            let target_section: CoffSection = objects[target.object].sections[definition.section - 1];
            if (target_place.section <= 0 || target_place.section > 65535 || target_place.offset > target_place.rva || definition.value > target_section.size ||
                Long(target_place.rva) + Long(target_section.size) > 4294967296L) {
                return coff_patch_error(CoffLinkStatus.InvalidLayout, object_id, section_id, reloc, "Invalid target section placement");
            }
            target_rva = Int128(target_place.rva) + Int128(definition.value);
            target_va = Int128(UInt128(image_base)) + target_rva;
            if (target_va > Int128(UInt128(18446744073709551615UL))) {
                return coff_patch_error(CoffLinkStatus.InvalidLayout, object_id, section_id, reloc, "Target address exceeds the image address range");
            }
        }

        let offset: Int = Int(reloc.offset);
        let original: Int = section.data.offset + offset;
        let value: Int128 = Int128(0);
        let max_value: Int128 = Int128(4294967295L);
        let min_value: Int128 = Int128(0);
        if (reloc.kind == 1U || reloc.kind == 2U) {
            value = target_va + coff_signed_addend(object.bytes, original, width);
            if (width == 8) { max_value = Int128(UInt128(18446744073709551615UL)); }
            if (!absolute) {
                let kind: UInt32 = 3U;
                if (width == 8) { kind = 10U; }
                patch.base_relocs.append(CoffBaseReloc(place.rva + reloc.offset, kind));
            }
        } else if (reloc.kind == 3U) {
            value = target_rva + coff_signed_addend(object.bytes, original, 4);
        } else if (reloc.kind >= 4U && reloc.kind <= 9U) {
            // REL32_n measures from the field end plus n, not from the opcode.
            value = target_rva + coff_signed_addend(object.bytes, original, 4) - Int128(place.rva) - Int128(reloc.offset) - Int128(reloc.kind);
            min_value = Int128(-2147483648L);
            max_value = Int128(2147483647L);
            if absolute { patch.fixed_base = true; }
        } else if (reloc.kind == 10U) {
            if absolute {
                return coff_patch_error(CoffLinkStatus.Unsupported, object_id, section_id, reloc, "SECTION against an absolute symbol needs the final output section count");
            }
            value = Int128(target_place.section) + Int128(coff_u16(object.bytes, original));
            max_value = Int128(65535);
        } else if (reloc.kind == 11U) {
            if absolute {
                return coff_patch_error(CoffLinkStatus.Unsupported, object_id, section_id, reloc, "SECREL against an absolute symbol is not supported");
            }
            value = Int128(target_place.offset) + Int128(definition.value) + coff_signed_addend(object.bytes, original, 4);
        }
        if (value < min_value || value > max_value) {
            return coff_patch_error(CoffLinkStatus.RelocationOverflow, object_id, section_id, reloc, "Relocation result does not fit its field");
        }

        // REL32 carries signed bits, convert its checked negative range to u32 storage.
        if (value < Int128(0)) { value += Int128(4294967296L); }
        coff_put_word(patch.bytes, offset, width, UInt64(value));
        i++;
    }
    return CoffPatchResult(patch=patch);
}
