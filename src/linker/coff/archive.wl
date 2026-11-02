// src/linker/coff/archive.wl
// format reference: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#archive-library-file-format
import * from "archive_model.wl"
import CoffSpan, CoffError, CoffObject from "model.wl"
import coff_range, coff_u16, coff_u32 from "reader.wl"
import coff_name_hash from "symbols.wl"


func archive_error(offset: Int, message: String, unsupported: Bool = false) -> ArchiveResult {
    let status = CoffError.InvalidObject;
    if unsupported { status = CoffError.UnsupportedObject; }
    return ArchiveResult(status=status, offset=offset, message=message);
}

func archive_decimal(bytes: Vector(Byte), field: CoffSpan) -> Int {
// size and long-name offsets use decimal ASCII, overflow is rejected before multiplication
    let value = 0;
    let digits = 0;
    let padding = false;
    for (let i = 0; i < field.size; i++) {
        let byte = Int(bytes[field.offset + i]);
        if (byte == 32) {
            padding = true;
        } else {
            if (padding || byte < 48 || byte > 57 || value > (2147483647 - (byte - 48)) / 10) { return -1; }
            value = value * 10 + byte - 48;
            digits++;
        }
    }
    if (digits == 0) { return -1; }
    return value;
}

func archive_be32(bytes: Vector(Byte), offset: Int) -> UInt32 {
    return (UInt32(bytes[offset]) << 24U) | (UInt32(bytes[offset + 1]) << 16U) |
           (UInt32(bytes[offset + 2]) << 8U) | UInt32(bytes[offset + 3]);
}

func archive_index(ref archive: CoffArchive, table: CoffSpan, second: Bool, collect: Bool) -> String {
// only member-header offsets are legal targets, offsets into payloads never become object IDs
    if (table.size < 4) { return "Truncated archive symbol directory"; }
    let bytes = archive.bytes;
    let members: Vector(Int) = [];
    let count: Long = Long(archive_be32(bytes, table.offset));
    let indices = 4;
    let names = 4;
    if second {
        let member_count = Long(coff_u32(bytes, table.offset));
        if (!coff_range(table.size, 4L, member_count, 4) || !coff_range(table.size, 4L + member_count * 4L, 1L, 4)) {
            return "Truncated second archive directory";
        }
        let previous: Long = -1L;
        for (let i = 0; Long(i) < member_count; i++) {
            let offset = Long(coff_u32(bytes, table.offset + 4 + i * 4));
            if (offset > 2147483647L || offset <= previous) { return "Invalid archive member offset order"; }
            let member = archive.offsets.lookup(Int(offset));
            if (member is null) { return "Archive index does not point to an object member header"; }
            members.append(member);
            previous = offset;
        }
        indices = 8 + Int(member_count) * 4;
        count = Long(coff_u32(bytes, table.offset + indices - 4));
        if (!coff_range(table.size, Long(indices), count, 2)) { return "Truncated archive symbol indices"; }
        names = indices + Int(count) * 2;
    } else {
        if (!coff_range(table.size, 4L, count, 4)) { return "Truncated archive symbol offsets"; }
        names = 4 + Int(count) * 4;
    }

    let cursor = names;
    for (let s = 0; Long(s) < count; s++) {
        let member_id = -1;
        if second {
            let index = coff_u16(bytes, table.offset + indices + s * 2);
            if (index == 0U || Long(index) > Long(members.length())) { return "Invalid archive symbol member index"; }
            member_id = members[Int(index) - 1];
        } else {
            let offset = Long(archive_be32(bytes, table.offset + 4 + s * 4));
            if (offset > 2147483647L) { return "Archive member offset exceeds supported file size"; }
            let member = archive.offsets.lookup(Int(offset));
            if (member is null) { return "Archive index does not point to an object member header"; }
            member_id = member;
        }
        let begin = cursor;
        while (cursor < table.size && bytes[table.offset + cursor] != Byte(0)) { cursor++; }
        if (cursor == table.size || cursor == begin) { return "Unterminated or empty archive symbol name"; }
        if collect {
            let name = CoffSpan(table.offset + begin, cursor - begin);
            let hash = coff_name_hash(bytes, name);
            let head = -1;
            let old = archive.buckets.lookup(hash);
            if (old is !null) { head = old; }
            archive.buckets.put(hash, archive.symbols.length());
            archive.symbols.append(ArchiveSymbol(name, member_id, head));
        }
        cursor++;
    }
    // GNU ar includes a NUL in the directory's size to keep it even.
    if (cursor != table.size && (cursor + 1 != table.size || bytes[table.offset + cursor] != Byte(0))) {
        return "Unexpected trailing archive directory bytes";
    }
    return "";
}

func read_archive(bytes: Vector(Byte)) -> ArchiveResult {
// parse framing and symbol directories once, object payloads are decoded only when selected
    if (bytes.length() < 8 || coff_u32(bytes, 0) != 0x72613C21U || coff_u32(bytes, 4) != 0x0A3E6863U) {
        return archive_error(0, "Expected a regular COFF archive, thin archives are not supported");
    }
    let archive = CoffArchive(bytes);
    let first = CoffSpan();
    let second = CoffSpan();
    let longnames = CoffSpan();
    let linker_count = 0;
    let has_longnames = false;
    let cursor = 8;
    while (cursor < bytes.length()) {
        if (!coff_range(bytes.length(), Long(cursor), 1L, 60)) { return archive_error(cursor, "Truncated archive member header"); }
        if (bytes[cursor + 58] != Byte(96) || bytes[cursor + 59] != Byte(10)) {
            return archive_error(cursor + 58, "Invalid archive member header terminator");
        }
        let length = archive_decimal(bytes, CoffSpan(cursor + 48, 10));
        if (length < 0 || !coff_range(bytes.length(), Long(cursor) + 60L, Long(length), 1)) {
            return archive_error(cursor + 48, "Invalid archive member size");
        }
        let name_size = 16;
        while (name_size > 0 && bytes[cursor + name_size - 1] == Byte(32)) { name_size--; }
        if (name_size == 0) { return archive_error(cursor, "Empty archive member name"); }
        let data = CoffSpan(cursor + 60, length);
        if (name_size == 1 && bytes[cursor] == Byte(47)) {
            if (linker_count == 0) { first = data; }
            else if (linker_count == 1) { second = data; }
            else { return archive_error(cursor, "Too many archive linker members"); }
            linker_count++;
        } else if (name_size == 2 && bytes[cursor] == Byte(47) && bytes[cursor + 1] == Byte(47)) {
            if has_longnames { return archive_error(cursor, "Duplicate archive long-name table"); }
            longnames = data;
            has_longnames = true;
        } else {
            archive.offsets.put(cursor, archive.members.length());
            archive.members.append(ArchiveMember(cursor, data, CoffSpan(cursor, name_size)));
        }
        cursor += 60 + length;
        if ((length & 1) != 0) {
            if (cursor == bytes.length() || bytes[cursor] != Byte(10)) { return archive_error(cursor, "Missing archive alignment padding"); }
            cursor++;
        }
    }

    let long_starts: Dict(Int, Int) = Dict();
    let begin = 0;
    for (let pos = 0; pos < longnames.size; pos++) {
        let byte = bytes[longnames.offset + pos];
        if (byte == Byte(0) || byte == Byte(10)) {
            let end = pos;
            if (byte == Byte(10) && pos > begin && bytes[longnames.offset + pos - 1] == Byte(47)) { end--; }
            long_starts.put(begin, end - begin);
            begin = pos + 1;
        }
    }
    if (begin != longnames.size) { return archive_error(longnames.offset + begin, "Unterminated archive long name"); }
    for (let m = 0; m < archive.members.length(); m++) {
        let member = archive.members[m];
        let name = member.name;
        if (bytes[name.offset] == Byte(47)) {
            let offset = archive_decimal(bytes, CoffSpan(name.offset + 1, name.size - 1));
            let size = long_starts.lookup(offset);
            if (offset < 0 || size is null) { return archive_error(name.offset, "Invalid archive long-name offset or unsupported special member"); }
            member.name = CoffSpan(longnames.offset + offset, size);
        } else {
            if (name.size >= 3 && bytes[name.offset] == Byte(35) && bytes[name.offset + 1] == Byte(49) && bytes[name.offset + 2] == Byte(47)) {
                return archive_error(name.offset, "BSD extended archive names are not supported", true);
            }
            if (bytes[name.offset + name.size - 1] == Byte(47)) { member.name.size--; }
        }
        if (member.name.size == 0) { return archive_error(name.offset, "Empty archive object name"); }
        archive.members[m] = member;
    }
    if (linker_count == 0) {
        if (archive.members.length() == 0) { return ArchiveResult(archive=archive); }
        return archive_error(8, "Archive has no symbol directory", true);
    }
    let message = archive_index(ref archive, first, false, linker_count == 1);
    if (message.length() != 0) { return archive_error(first.offset, message); }
    if (linker_count == 2) {
        message = archive_index(ref archive, second, true, true);
        if (message.length() != 0) { return archive_error(second.offset, message); }
    }
    return ArchiveResult(archive=archive);
}

func archive_find(archive: CoffArchive, object: CoffObject, name: CoffSpan) -> Int {
// hash narrows the directory lookup, full bytes decide equality and earliest member wins
    let found = archive.buckets.lookup(coff_name_hash(object.bytes, name));
    if (found is null) { return -1; }
    let current: Int = found;
    let result = -1;
    while (current >= 0) {
        let entry = archive.symbols[current];
        let equal = entry.name.size == name.size;
        for (let i = 0; equal && i < name.size; i++) {
            equal = archive.bytes[entry.name.offset + i] == object.bytes[name.offset + i];
        }
        if (equal && (result < 0 || entry.member < result)) { result = entry.member; }
        current = entry.next;
    }
    return result;
}
