// src/linker/pe/layout.wl
import * from "model.wl"
import * from "../coff/model.wl"
import * from "../coff/link_model.wl"
import coff_range, coff_name_matches from "../coff/reader.wl"


func pe_align(value: Long, alignment: Int) -> Long {
    return ((value + Long(alignment) - 1L) / Long(alignment)) * Long(alignment);
}

func pe_layout_error(status: CoffLinkStatus, object: Int, section: Int, message: String) -> PeLayoutResult {
    return PeLayoutResult(errors=[CoffLinkError(status=status, object=object, section=section, message=message)]);
}

func pe_prefix(object: CoffObject, name: CoffSpan) -> CoffSpan {
// suffixes control contribution order, only the prefix enters the image name
    let size = 0;
    while (size < name.size && object.bytes[name.offset + size] != Byte(36)) { size++; }
    return CoffSpan(name.offset, size);
}

func pe_name_equal(object: CoffObject, span: CoffSpan, name: Vector(Byte)) -> Bool {
    if (span.size != name.length()) { return false; }
    let i = 0;
    while (i < span.size) {
        if (object.bytes[span.offset + i] != name[i]) { return false; }
        i++;
    }
    return true;
}

func pe_name_before(left: Vector(Byte), right: Vector(Byte)) -> Bool {
    let count = left.length();
    if (right.length() < count) { count = right.length(); }
    let i = 0;
    while (i < count) {
        if (left[i] != right[i]) { return left[i] < right[i]; }
        i++;
    }
    return left.length() < right.length();
}

func pe_name_is(name: Vector(Byte), text: String) -> Bool {
    if (name.length() != text.length()) { return false; }
    let i = 0;
    while (i < name.length()) {
        if (name[i] != text[i]) { return false; }
        i++;
    }
    return true;
}

func pe_section_rank(name: Vector(Byte)) -> Int {
    if (pe_name_is(name, ".text")) { return 0; }
    if (pe_name_is(name, ".rdata")) { return 1; }
    if (pe_name_is(name, ".data")) { return 2; }
    if (pe_name_is(name, ".bss")) { return 3; }
    return 4;
}

func pe_part_before(objects: Vector(CoffObject), left: PeInput, right: PeInput) -> Bool {
// equal suffixes retain input order, names are compared as unsigned bytes
    let a = objects[left.object].sections[left.section].name;
    let b = objects[right.object].sections[right.section].name;
    let count = a.size;
    if (b.size < count) { count = b.size; }
    let i = 0;
    while (i < count) {
        let x = objects[left.object].bytes[a.offset + i];
        let y = objects[right.object].bytes[b.offset + i];
        if (x != y) { return x < y; }
        i++;
    }
    return a.size < b.size;
}

func pe_sort_parts(objects: Vector(CoffObject), parts: Vector(PeInput)) -> Vector(PeInput) {
// large .text$... inputs need bounded sorting rather than insertion into a growing vector
    let count = parts.length();
    let ordered = true;
    let i = 1;
    while (i < count) {
        if (pe_part_before(objects, parts[i], parts[i - 1])) {
            ordered = false;
            break;
        }
        i++;
    }
    if ordered { return parts; }

    let result: Vector(PeInput) = [];
    let scratch: Vector(PeInput) = [];
    i = 0;
    while (i < count) {
        result.append(parts[i]);
        scratch.append(parts[i]);
        i++;
    }
    let run = 1;
    while (run < count) {
        let start = 0;
        while (start < count) {
            let mid = count;
            if (run <= count - start) { mid = start + run; }
            let finish = count;
            if (run <= count - mid) { finish = mid + run; }
            let left = start;
            let right = mid;
            let out = start;
            while (out < finish) {
                if (right == finish || (left < mid && !pe_part_before(objects, result[right], result[left]))) {
                    scratch[out] = result[left];
                    left++;
                } else {
                    scratch[out] = result[right];
                    right++;
                }
                out++;
            }
            start = finish;
        }
        let swap = result;
        result = scratch;
        scratch = swap;
        if (run > count / 2) { run = count; }
        else { run *= 2; }
    }
    return result;
}

func pe_special_section(object: CoffObject, prefix: CoffSpan) -> Bool {
// these names require loader directories or linker policy before their bytes can be used
    return coff_name_matches(object, prefix, ".idata") || coff_name_matches(object, prefix, ".edata") ||
        coff_name_matches(object, prefix, ".pdata") || coff_name_matches(object, prefix, ".tls") ||
        coff_name_matches(object, prefix, ".rsrc") || coff_name_matches(object, prefix, ".reloc") ||
        coff_name_matches(object, prefix, ".CRT") || coff_name_matches(object, prefix, ".sxdata") ||
        coff_name_matches(object, prefix, ".gfids") || coff_name_matches(object, prefix, ".giats") ||
        coff_name_matches(object, prefix, ".gljmp") || coff_name_matches(object, prefix, ".00cfg");
}

func plan_pe(objects: Vector(CoffObject), import_object: Int = -1) -> PeLayoutResult {
// assign contributions before patching, raw offsets and RVAs have different alignment
    let layout = PeLayout();
    let object_id = 0;
    while (object_id < objects.length()) {
        let object = objects[object_id];
        let row: Vector(CoffPlacement) = [];
        let section_id = 0;
        while (section_id < object.sections.length()) {
            row.append(CoffPlacement(0U, 0));
            let input = object.sections[section_id];
            if (!coff_range(object.bytes.length(), Long(input.name.offset), Long(input.name.size), 1) ||
                !coff_range(object.bytes.length(), Long(input.data.offset), Long(input.data.size), 1) ||
                (input.data.size != 0 && Long(input.data.size) != Long(input.size)) || input.alignment < 1 ||
                input.alignment > 8192 || (input.alignment & (input.alignment - 1)) != 0) {
                return pe_layout_error(CoffLinkStatus.InvalidObject, object_id, section_id, "Invalid input section span or alignment");
            }
            let prefix = pe_prefix(object, input.name);
            if (coff_name_matches(object, prefix, ".drectve") && input.size != 0U) {
                return pe_layout_error(CoffLinkStatus.Unsupported, object_id, section_id, "COFF linker directives are not implemented yet");
            }
            if ((input.flags & 4096U) != 0U) {
                return pe_layout_error(CoffLinkStatus.Unsupported, object_id, section_id, "COMDAT selection is not implemented yet");
            }
            if ((input.flags & 2560U) != 0U || coff_name_matches(object, prefix, ".debug")) {
                section_id++;
                continue;
            }
            if (prefix.size < 1 || prefix.size > 8) {
                return pe_layout_error(CoffLinkStatus.Unsupported, object_id, section_id, "PE image section names must fit eight bytes");
            }
            // only the writer's generated import object supplies complete .idata metadata.
            let generated = object_id == import_object && coff_name_matches(object, prefix, ".idata");
            if (input.size != 0U && pe_special_section(object, prefix) && !generated) {
                return pe_layout_error(CoffLinkStatus.Unsupported, object_id, section_id, "Input section needs unsupported PE loader metadata");
            }
            if (input.size == 0U) { section_id++; continue; }
            if ((input.flags & 0xC0000000U) == 0U || (input.flags & 0x000E0000U) != 0U) {
                return pe_layout_error(CoffLinkStatus.Unsupported, object_id, section_id, "Unsupported image section characteristics");
            }

            let group = 0;
            while (group < layout.sections.length() && !pe_name_equal(object, prefix, layout.sections[group].name)) { group++; }
            // Windows limits an image to 96 sections, reserve one slot for generated .reloc.
            if (group == layout.sections.length()) {
                if (group >= 95) {
                    return pe_layout_error(CoffLinkStatus.Unsupported, object_id, section_id, "PE section count exceeds the supported image limit");
                }
                let name: Vector(Byte) = [];
                let i = 0;
                while (i < prefix.size) {
                    if (object.bytes[prefix.offset + i] == Byte(0)) {
                        return pe_layout_error(CoffLinkStatus.InvalidObject, object_id, section_id, "Image section name contains a zero byte");
                    }
                    name.append(object.bytes[prefix.offset + i]);
                    i++;
                }
                // COFF alignment and overflow flags belong to the input object only.
                layout.sections.append(PeSection(name=name, flags=input.flags & 0xFE0000E0U));
            }
            let section = layout.sections[group];
            if ((section.flags & 0xFE000000U) != (input.flags & 0xFE000000U)) {
                return pe_layout_error(CoffLinkStatus.Unsupported, object_id, section_id, "Contributions have conflicting memory permissions");
            }
            section.flags |= input.flags & 224U;
            if (input.alignment > section.alignment) { section.alignment = input.alignment; }
            section.parts.append(PeInput(object_id, section_id));
            layout.sections[group] = section;
            section_id++;
        }
        layout.placements.append(row);
        object_id++;
    }
    if (layout.sections.length() == 0) {
        return pe_layout_error(CoffLinkStatus.InvalidLayout, -1, -1, "PE image has no loadable sections");
    }

    // at most 95 names participate here, contribution sorting has no such small bound.
    let i = 1;
    while (i < layout.sections.length()) {
        let section = layout.sections[i];
        let rank = pe_section_rank(section.name);
        let j = i;
        while (j > 0 && (rank < pe_section_rank(layout.sections[j - 1].name) ||
            (rank == pe_section_rank(layout.sections[j - 1].name) && pe_name_before(section.name, layout.sections[j - 1].name)))) {
            layout.sections[j] = layout.sections[j - 1];
            j--;
        }
        layout.sections[j] = section;
        i++;
    }

    // the spare header permits adding .reloc without moving any existing RVA.
    layout.headers_size = UInt32(pe_align(64L + 24L + 240L + Long(layout.sections.length() + 1) * 40L, 512));
    let rva = pe_align(Long(layout.headers_size), 4096);
    let raw = Long(layout.headers_size);
    i = 0;
    while (i < layout.sections.length()) {
        let section = layout.sections[i];
        section.parts = pe_sort_parts(objects, section.parts);
        let alignment = 4096;
        if (section.alignment > alignment) { alignment = section.alignment; }
        rva = pe_align(rva, alignment);
        let size = 0L;
        let initialized = 0L;
        let j = 0;
        while (j < section.parts.length()) {
            let part = section.parts[j];
            let input = objects[part.object].sections[part.section];
            size = pe_align(size, input.alignment);
            if (size + Long(input.size) > 4294967295L || rva + size + Long(input.size) > 4294967295L) {
                return pe_layout_error(CoffLinkStatus.InvalidLayout, part.object, part.section, "PE virtual section range exceeds 32-bit addressing");
            }
            layout.placements[part.object][part.section] = CoffPlacement(UInt32(rva + size), i + 1, UInt32(size));
            if (input.data.size != 0) { initialized = size + Long(input.data.size); }
            size += Long(input.size);
            j++;
        }
        section.size = UInt32(size);
        section.initialized_size = UInt32(initialized);
        section.rva = UInt32(rva);
        let disk_size = pe_align(initialized, 512);
        if (raw + disk_size > 2147483647L) {
            return pe_layout_error(CoffLinkStatus.InvalidLayout, -1, i, "PE file exceeds the supported in-memory size");
        }
        section.raw_size = UInt32(disk_size);
        if (disk_size != 0L) { section.raw_offset = UInt32(raw); }
        if (initialized != 0L) { section.flags = (section.flags & ~128U) | 64U; }
        if ((section.flags & 32U) != 0U) { section.flags &= ~64U; }
        layout.sections[i] = section;
        raw += disk_size;
        rva = pe_align(rva + size, 4096);
        if (rva > 2147483647L) {
            return pe_layout_error(CoffLinkStatus.InvalidLayout, -1, i, "PE32+ image exceeds the 2 GiB loader limit");
        }
        i++;
    }
    layout.file_size = UInt32(raw);
    layout.image_size = UInt32(rva);

    return PeLayoutResult(layout=layout);
}
