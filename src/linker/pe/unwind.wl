// src/linker/pe/unwind.wl
// AMD64 UNWIND_INFO: https://learn.microsoft.com/en-us/cpp/build/exception-handling-x64
import PeLayout from "model.wl"
import pe_name_is from "layout.wl"
import CoffObject from "../coff/model.wl"
import CoffLinkError, CoffLinkStatus from "../coff/link_model.wl"
import coff_u16, coff_u32 from "../coff/reader.wl"
import coff_put_word from "../coff/reloc.wl"


struct PeImageSpan(section: Int = -1, offset: Int = 0, remaining: Int = 0)
struct PeRuntimeFunction(begin: UInt32, end: UInt32, unwind: UInt32)
struct PeUnwindInfo(prologue: Int = 0, message: String = "", status: CoffLinkStatus = CoffLinkStatus.InvalidObject)
struct PeExceptionTable(rva: UInt32 = 0U, size: UInt32 = 0U, errors: Vector(CoffLinkError) = [])

func pe_exception_error(status: CoffLinkStatus, section: Int, offset: UInt32, message: String) -> PeExceptionTable {
    return PeExceptionTable(errors=[CoffLinkError(status=status, object=-1, section=section, offset=offset, message=message)]);
}

func pe_image_span(layout: PeLayout, data: Vector(Vector(Byte)), rva: UInt32, size: Long) -> PeImageSpan {
// an RVA may refer to BSS or file padding, unwind readers require initialized mapped bytes
    let i = 0;
    while (i < layout.sections.length()) {
        let section = layout.sections[i];
        let offset = Long(rva) - Long(section.rva);
        if (offset >= 0L && offset <= Long(data[i].length()) && size >= 0L && size <= Long(data[i].length()) - offset) {
            return PeImageSpan(i, Int(offset), data[i].length() - Int(offset));
        }
        i++;
    }
    return PeImageSpan();
}

func pe_nonvolatile_register(code: Int) -> Bool {
    return code == 3 || code == 5 || code == 6 || code == 7 || (code >= 12 && code <= 15);
}

func pe_check_unwind(bytes: Vector(Byte), offset: Int, available: Int) -> PeUnwindInfo {
// slots after an operation may contain operands, they are not additional unwind opcodes
    if (offset < 0 || offset > bytes.length() || available < 4 || available > bytes.length() - offset) {
        return PeUnwindInfo(message="Truncated UNWIND_INFO header");
    }
    let version = Int(bytes[offset]) & 7;
    let flags = Int(bytes[offset]) >> 3;
    if (version != 1 || flags != 0) {
        return PeUnwindInfo(status=CoffLinkStatus.Unsupported, message="Only version 1 unwind records without handlers or chains are supported");
    }
    let prologue = Int(bytes[offset + 1]);
    let count = Int(bytes[offset + 2]);
    let frame = Int(bytes[offset + 3]) & 15;
    let frame_offset = Int(bytes[offset + 3]) >> 4;
    let size = 4 + ((count + 1) & ~1) * 2;
    if (size > available || (frame == 0 && frame_offset != 0) || (frame != 0 && !pe_nonvolatile_register(frame))) {
        return PeUnwindInfo(message="Invalid UNWIND_INFO slots or frame register");
    }

    let previous = prologue;
    let frame_code = -1;
    let first_save = 256;
    let i = 0;
    while (i < count) {
        let at = offset + 4 + i * 2;
        let code_offset = Int(bytes[at]);
        let opcode = Int(bytes[at + 1]) & 15;
        let info = Int(bytes[at + 1]) >> 4;
        let slots = 1;
        if (code_offset == 0 || code_offset > previous) { return PeUnwindInfo(message="Unwind codes must have descending prologue offsets"); }
        previous = code_offset;
        if (opcode == 0) {
            if (!pe_nonvolatile_register(info)) { return PeUnwindInfo(message="Unwind push requires a nonvolatile register"); }
        } else if (opcode == 1) {
            if (info > 1) { return PeUnwindInfo(message="Invalid large stack allocation encoding"); }
            slots = 2 + info;
        } else if (opcode == 2) {
            // all four-bit opinfo values encode a valid 8..128 byte allocation.
        } else if (opcode == 3) {
            if (info != 0 || frame == 0 || frame_code >= 0) { return PeUnwindInfo(message="Invalid frame-pointer unwind operation"); }
            frame_code = code_offset;
        } else if (opcode == 4 || opcode == 5 || opcode == 8 || opcode == 9) {
            if (((opcode == 4 || opcode == 5) && !pe_nonvolatile_register(info)) || ((opcode == 8 || opcode == 9) && info < 6)) {
                return PeUnwindInfo(message="Unwind save requires a nonvolatile register");
            }
            slots = 2;
            if (opcode == 5 || opcode == 9) { slots = 3; }
            if (code_offset < first_save) { first_save = code_offset; }
        } else {
            return PeUnwindInfo(status=CoffLinkStatus.Unsupported, message="Unsupported AMD64 unwind operation");
        }
        if (slots > count - i) { return PeUnwindInfo(message="Truncated unwind operation operand"); }
        if (opcode == 1) {
            let allocation = UInt32(coff_u16(bytes, at + 2)) * 8U;
            if (info == 1) { allocation = coff_u32(bytes, at + 2); }
            if (allocation == 0U || (allocation & 7U) != 0U) { return PeUnwindInfo(message="Invalid unwind stack allocation size"); }
        }
        if (opcode == 5 || opcode == 9) {
            let alignment = 8U;
            if (opcode == 9) { alignment = 16U; }
            if ((coff_u32(bytes, at + 2) & (alignment - 1U)) != 0U) { return PeUnwindInfo(message="Unwind save offset is misaligned"); }
        }
        i += slots;
    }
    if ((frame != 0 && frame_code < 0) || (frame != 0 && first_save <= frame_code)) {
        return PeUnwindInfo(message="Frame-relative saves must follow frame-pointer setup");
    }
    return PeUnwindInfo(prologue=prologue);
}

func pe_sort_runtime(entries: Vector(PeRuntimeFunction)) -> Vector(PeRuntimeFunction) {
// already ordered compiler output needs no sort allocation, other inputs use bounded mergesort
    let count = entries.length();
    let i = 1;
    let ordered = true;
    while (i < count) {
        if (entries[i].begin < entries[i - 1].begin) { ordered = false; break; }
        i++;
    }
    if ordered { return entries; }
    let result: Vector(PeRuntimeFunction) = [];
    let scratch: Vector(PeRuntimeFunction) = [];
    i = 0;
    while (i < count) { result.append(entries[i]); scratch.append(entries[i]); i++; }
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
                if (right == finish || (left < mid && result[left].begin <= result[right].begin)) {
                    scratch[out] = result[left]; left++;
                } else {
                    scratch[out] = result[right]; right++;
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

func pe_exception_table(objects: Vector(CoffObject), layout: PeLayout, data: Vector(Vector(Byte))) -> PeExceptionTable {
// validate after relocation, both function ranges and unwind addresses are final image RVAs
    let section_id = 0;
    while (section_id < layout.sections.length() && !pe_name_is(layout.sections[section_id].name, ".pdata")) { section_id++; }
    if (section_id == layout.sections.length()) { return PeExceptionTable(); }
    let section = layout.sections[section_id];
    let bytes = data[section_id];
    if ((section.rva & 3U) != 0U || (section.flags & 0xE0000000U) != 0x40000000U || section.size != UInt32(bytes.length()) || bytes.length() % 12 != 0) {
        return pe_exception_error(CoffLinkStatus.InvalidObject, section_id, 0U, "Exception table must be read-only, initialized and contain complete 12-byte records");
    }
    let cursor = 0;
    let i = 0;
    while (i < section.parts.length()) {
        let part = section.parts[i];
        let input = objects[part.object].sections[part.section];
        let place = layout.placements[part.object][part.section];
        if (place.offset != UInt32(cursor) || input.size % 12U != 0U) {
            return pe_exception_error(CoffLinkStatus.InvalidObject, section_id, place.offset, "Exception table contains partial records or contribution padding");
        }
        cursor += Int(input.size);
        i++;
    }

    let entries: Vector(PeRuntimeFunction) = [];
    let checked: Dict(UInt32, PeUnwindInfo) = Dict();
    i = 0;
    while (i < bytes.length()) {
        let entry = PeRuntimeFunction(coff_u32(bytes, i), coff_u32(bytes, i + 4), coff_u32(bytes, i + 8));
        if (entry.begin >= entry.end || (entry.unwind & 3U) != 0U) {
            return pe_exception_error(CoffLinkStatus.InvalidObject, section_id, UInt32(i), "Invalid runtime function range or unwind alignment");
        }
        let code = pe_image_span(layout, data, entry.begin, Long(entry.end) - Long(entry.begin));
        if (code.section < 0) { return pe_exception_error(CoffLinkStatus.InvalidObject, section_id, UInt32(i), "Runtime function range is outside initialized code"); }
        if ((layout.sections[code.section].flags & 0x20000000U) == 0U) {
            return pe_exception_error(CoffLinkStatus.InvalidObject, section_id, UInt32(i), "Runtime function range is not executable");
        }
        let info = PeUnwindInfo();
        let cached = checked.lookup(entry.unwind);
        if (cached is !null) { info = cached; }
        else {
            let storage = pe_image_span(layout, data, entry.unwind, 4L);
            if (storage.section < 0 || (layout.sections[storage.section].flags & 0xE0000000U) != 0x40000000U || storage.section == section_id) {
                return pe_exception_error(CoffLinkStatus.InvalidObject, section_id, UInt32(i + 8), "Unwind info must refer to initialized read-only storage");
            }
            info = pe_check_unwind(data[storage.section], storage.offset, storage.remaining);
            if (info.message.length() != 0) { return pe_exception_error(info.status, section_id, UInt32(i + 8), info.message); }
            checked.put(entry.unwind, info);
        }
        if (Long(info.prologue) > Long(entry.end) - Long(entry.begin)) {
            return pe_exception_error(CoffLinkStatus.InvalidObject, section_id, UInt32(i), "Unwind prologue extends beyond its function");
        }
        entries.append(entry);
        i += 12;
    }
    entries = pe_sort_runtime(entries);
    i = 0;
    while (i < entries.length()) {
        if (i > 0 && entries[i - 1].end > entries[i].begin) {
            return pe_exception_error(CoffLinkStatus.InvalidObject, section_id, UInt32(i * 12), "Runtime function ranges overlap");
        }
        coff_put_word(bytes, i * 12, 4, UInt64(entries[i].begin));
        coff_put_word(bytes, i * 12 + 4, 4, UInt64(entries[i].end));
        coff_put_word(bytes, i * 12 + 8, 4, UInt64(entries[i].unwind));
        i++;
    }
    return PeExceptionTable(rva=section.rva, size=section.size);
}
