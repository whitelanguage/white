// src/linker/pe/reloc.wl
import CoffBaseReloc from "../coff/link_model.wl"


struct PeRelocData(bytes: Vector(Byte) = [], message: String = "")

func pe_emit_word(ref bytes: Vector(Byte), value: UInt64, width: Int) -> Void {
    let i = 0;
    while (i < width) {
        bytes.append(Byte((value >> UInt64(i * 8)) & 255UL));
        i++;
    }
}

func pe_sort_relocs(items: Vector(CoffBaseReloc)) -> Vector(CoffBaseReloc) {
// contributions arrive in RVA order, only unordered input records need sort buffers
    let count = items.length();
    let i = 1;
    let ordered = true;
    while (i < count) {
        if (items[i].rva < items[i - 1].rva) {
            ordered = false;
            break;
        }
        i++;
    }
    if ordered { return items; }

    let result: Vector(CoffBaseReloc) = [];
    let scratch: Vector(CoffBaseReloc) = [];
    i = 0;
    while (i < count) {
        result.append(items[i]);
        scratch.append(items[i]);
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
                if (right == finish || (left < mid && result[left].rva <= result[right].rva)) {
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

func pe_base_relocs(items: Vector(CoffBaseReloc)) -> PeRelocData {
// each page block has an eight-byte header, ABSOLUTE entries pad its size to four bytes
    let ordered = pe_sort_relocs(items);
    let bytes: Vector(Byte) = [];
    let i = 0;
    while (i < ordered.length()) {
        let page = ordered[i].rva & 0xFFFFF000U;
        let end = i;
        while (end < ordered.length() && (ordered[end].rva & 0xFFFFF000U) == page) {
            let kind = ordered[end].kind;
            if (kind != 3U && kind != 10U) { return PeRelocData(message="Unsupported PE base relocation type"); }
            if (end > 0 && ordered[end].rva == ordered[end - 1].rva) {
                return PeRelocData(message="Duplicate PE base relocation field");
            }
            end++;
        }
        let count = end - i;
        let size = 8L + Long(count + (count & 1)) * 2L;
        if (size > 2147483647L - Long(bytes.length())) { return PeRelocData(message="PE base relocation table exceeds the supported size"); }

        pe_emit_word(ref bytes, UInt64(page), 4);
        pe_emit_word(ref bytes, UInt64(size), 4);
        while (i < end) {
            let item = ordered[i];
            pe_emit_word(ref bytes, UInt64((item.kind << 12U) | (item.rva & 4095U)), 2);
            i++;
        }
        if ((count & 1) != 0) { pe_emit_word(ref bytes, 0UL, 2); }
    }
    return PeRelocData(bytes=bytes);
}
