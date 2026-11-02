// src/linker/coff/library_write.wl
import * from "library_model.wl"


func library_word(ref bytes: Vector(Byte), value: UInt32, width: Int, big: Bool = false) -> Void {
    for (let i = 0; i < width; i++) {
        let shift = i * 8;
        if big { shift = (width - i - 1) * 8; }
        bytes.append(Byte((value >> UInt32(shift)) & 255U));
    }
}

func library_text(ref bytes: Vector(Byte), text: String, terminated: Bool = true) -> Void {
    for (let i = 0; i < text.length(); i++) { bytes.append(text[i]); }
    if terminated { bytes.append(Byte(0)); }
}

func library_name_before(left: String, right: String) -> Bool {
    let count = left.length();
    if (right.length() < count) { count = right.length(); }
    for (let i = 0; i < count; i++) {
        if (left[i] != right[i]) { return left[i] < right[i]; }
    }
    return left.length() < right.length();
}

func library_order(entries: Vector(CoffLibraryEntry)) -> Vector(Int) {
// the second linker member needs byte-sorted names, merge indices without moving their payloads
    let order: Vector(Int) = [];
    let scratch: Vector(Int) = [];
    for (let i = 0; i < entries.length(); i++) { order.append(i); scratch.append(0); }
    let run = 1;
    let count = order.length();
    while (run < count) {
        let start = 0;
        while (start < count) {
            let mid = count;
            if (run <= count - start) { mid = start + run; }
            let end = count;
            if (run <= count - mid) { end = mid + run; }
            let left = start;
            let right = mid;
            for (let out = start; out < end; out++) {
                if (right == end || (left < mid && !library_name_before(entries[order[right]].name, entries[order[left]].name))) {
                    scratch[out] = order[left];
                    left++;
                } else {
                    scratch[out] = order[right];
                    right++;
                }
            }
            start = end;
        }
        let swap = order;
        order = scratch;
        scratch = swap;
        if (run > count / 2) { run = count; } else { run *= 2; }
    }
    return order;
}

func library_member(ref bytes: Vector(Byte), name: String, data: Vector(Byte)) -> Void {
// fixed-width fields and member padding are independent of the COFF payload's alignment
    let field = name;
    while (field.length() < 16) { field += " "; }
    let size = String(data.length());
    while (size.length() < 10) { size += " "; }
    library_text(ref bytes, field + "0           0     0     0       " + size + "`\n", false);
    for (let i = 0; i < data.length(); i++) { bytes.append(data[i]); }
    if ((data.length() & 1) != 0) { bytes.append(Byte(10)); }
}

func write_coff_library(parts: Vector(CoffLibraryPart)) -> CoffLibraryResult {
// both directories refer to member headers, timestamps stay zero so the archive is reproducible
    if (parts.length() > 65535) { return CoffLibraryResult(message="COFF library exceeds the 16-bit member index range"); }
    let entries: Vector(CoffLibraryEntry) = [];
    let unique: Dict(String, Bool) = Dict();
    let name_size = 0L;
    let payload_size = 0L;
    for (let m = 0; m < parts.length(); m++) {
        let part = parts[m];
        payload_size += 60L + Long(part.bytes.length()) + Long(part.bytes.length() & 1);
        if (payload_size > 2147483647L) { return CoffLibraryResult(message="COFF library exceeds the supported file size"); }
        for (let s = 0; s < part.symbols.length(); s++) {
            let name = part.symbols[s];
            if (name.length() == 0 || unique.contains_key(name)) {
                return CoffLibraryResult(message="Empty or duplicate COFF library symbol");
            }
            for (let b = 0; b < name.length(); b++) {
                if (name[b] == Byte(0)) { return CoffLibraryResult(message="NUL byte in COFF library symbol"); }
            }
            unique.put(name, true);
            name_size += Long(name.length()) + 1L;
            if (name_size > 2147483647L) { return CoffLibraryResult(message="COFF library exceeds the supported file size"); }
            entries.append(CoffLibraryEntry(name, m));
        }
    }
    let first_size = 4L + Long(entries.length()) * 4L + name_size;
    let second_size = 8L + Long(parts.length()) * 4L + Long(entries.length()) * 2L + name_size;
    let start = 8L + 60L + first_size + (first_size & 1L) + 60L + second_size + (second_size & 1L);
    if (start + payload_size > 2147483647L) {
        return CoffLibraryResult(message="COFF library exceeds the supported file size");
    }
    let offsets: Vector(UInt32) = [];
    for (let p = 0; p < parts.length(); p++) {
        offsets.append(UInt32(start));
        start += 60L + Long(parts[p].bytes.length()) + Long(parts[p].bytes.length() & 1);
    }

    let first: Vector(Byte) = [];
    library_word(ref first, UInt32(entries.length()), 4, true);
    for (let e = 0; e < entries.length(); e++) { library_word(ref first, offsets[entries[e].member], 4, true); }
    for (let text = 0; text < entries.length(); text++) { library_text(ref first, entries[text].name); }

    let second: Vector(Byte) = [];
    library_word(ref second, UInt32(parts.length()), 4);
    for (let off = 0; off < offsets.length(); off++) { library_word(ref second, offsets[off], 4); }
    library_word(ref second, UInt32(entries.length()), 4);
    let order = library_order(entries);
    for (let index = 0; index < order.length(); index++) { library_word(ref second, UInt32(entries[order[index]].member + 1), 2); }
    for (let key = 0; key < order.length(); key++) { library_text(ref second, entries[order[key]].name); }

    let bytes: Vector(Byte) = [];
    library_text(ref bytes, "!<arch>\n", false);
    library_member(ref bytes, "/", first);
    library_member(ref bytes, "/", second);
    for (let member = 0; member < parts.length(); member++) { library_member(ref bytes, "imports.obj/", parts[member].bytes); }
    return CoffLibraryResult(bytes=bytes);
}
