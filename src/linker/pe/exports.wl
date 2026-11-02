// src/linker/pe/exports.wl
import PeExport, PeExportBinding, PeLayout from "model.wl"
import * from "../coff/model.wl"
import * from "../coff/link_model.wl"
import * from "../coff/symbols.wl"
import coff_put_word from "../coff/reloc.wl"


struct PeExportTable(bytes: Vector(Byte) = [], errors: Vector(CoffLinkError) = [], bindings: Vector(PeExportBinding) = [])

func pe_export_error(message: String) -> PeExportTable {
    return PeExportTable(errors=[CoffLinkError(status=CoffLinkStatus.InvalidLayout, object=-1, message=message)]);
}

func pe_export_text(name: String, ascii: Bool) -> Bool {
    let i = 0;
    while (i < name.length()) {
        let byte = Int(name[i]);
        if (byte == 0 || (ascii && (byte < 32 || byte > 126))) { return false; }
        i++;
    }
    return name.length() != 0;
}

func pe_export_before(left: String, right: String) -> Bool {
// the loader binary-searches names as unsigned ASCII bytes, locale order would break lookup
    let count = left.length();
    if (right.length() < count) { count = right.length(); }
    let i = 0;
    while (i < count) {
        if (left[i] != right[i]) { return left[i] < right[i]; }
        i++;
    }
    return left.length() < right.length();
}

func pe_export_order(requests: Vector(PeExport)) -> Vector(Int) {
// sort indices so ordinal-only exports and caller metadata keep their original storage
    let order: Vector(Int) = [];
    let i = 0;
    while (i < requests.length()) { order.append(i); i++; }
    let count = order.length();
    let ordered = true;
    i = 1;
    while (i < count) {
        if (pe_export_before(requests[order[i]].name, requests[order[i - 1]].name)) { ordered = false; break; }
        i++;
    }
    if ordered { return order; }

    let scratch: Vector(Int) = [];
    i = 0;
    while (i < count) { scratch.append(0); i++; }
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
                if (right == finish || (left < mid && !pe_export_before(requests[order[right]].name, requests[order[left]].name))) {
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
        let swap = order;
        order = scratch;
        scratch = swap;
        if (run > count / 2) { run = count; }
        else { run *= 2; }
    }
    return order;
}

func pe_export_string(ref bytes: Vector(Byte), text: String) -> Int {
    let offset = bytes.length();
    let i = 0;
    while (i < text.length()) { bytes.append(text[i]); i++; }
    bytes.append(Byte(0));
    return offset;
}

func pe_export_table(objects: Vector(CoffObject), layout: PeLayout, requests: Vector(PeExport), image_name: String, rva: UInt32, import_object: Int = -1) -> PeExportTable {
// final placements already exist, exported addresses need RVAs rather than base relocations
    if (requests.length() == 0) { return PeExportTable(); }
    if (!pe_export_text(image_name, true) || image_name.length() > 255) {
        return pe_export_error("Export image name must be nonempty ASCII and at most 255 bytes");
    }
    let i = 0;
    while (i < image_name.length()) {
        if (image_name[i] == Byte(47) || image_name[i] == Byte(92) || image_name[i] == Byte(58)) {
            return pe_export_error("Export image name must not contain a path");
        }
        i++;
    }
    // the ordinal table stores a 16-bit index, keep the public ordinal range bounded too.
    if (requests.length() > 65535) { return pe_export_error("Too many PE exports"); }

    let normalized: Vector(PeExport) = [];
    let names: Dict(String, Bool) = Dict();
    let ordinals: Dict(UInt32, Bool) = Dict();
    let name_size = Long(image_name.length()) + 1L;
    let query_size = 0L;
    let named = 0;
    i = 0;
    while (i < requests.length()) {
        let item = requests[i];
        if (item.symbol.length() == 0) { item.symbol = item.name; }
        if (!pe_export_text(item.symbol, false) || (item.name.length() != 0 && !pe_export_text(item.name, true))) {
            return pe_export_error("Invalid PE export name or symbol");
        }
        if (item.name.length() == 0 && item.ordinal is null) {
            return pe_export_error("Unnamed exports require an explicit ordinal");
        }
        if (item.name.length() != 0) {
            if (names.contains_key(item.name)) { return pe_export_error("Duplicate PE export name '" + item.name + "'"); }
            names.put(item.name, true);
            named++;
            name_size += Long(item.name.length()) + 1L;
        }
        if (item.ordinal is !null) {
            let ordinal: UInt32 = item.ordinal;
            if (ordinal == 0U || ordinal > 65535U) { return pe_export_error("PE export ordinal must be between 1 and 65535"); }
            if (ordinals.contains_key(ordinal)) { return pe_export_error("Duplicate PE export ordinal"); }
            ordinals.put(ordinal, true);
        }
        normalized.append(item);
        query_size += Long(item.symbol.length()) + 1L;
        i++;
    }

    let order = pe_export_order(normalized);
    let next = 1U;
    let base = 65535U;
    let last = 0U;
    i = 0;
    while (i < order.length()) {
        let item = normalized[order[i]];
        let supplied = item.ordinal;
        let ordinal = 0U;
        if (supplied is !null) {
            ordinal = supplied;
        } else {
            while (next <= 65535U && ordinals.contains_key(next)) { next++; }
            if (next > 65535U) { return pe_export_error("No free PE export ordinal"); }
            ordinal = next;
            ordinals.put(next, true);
            next++;
        }
        item.ordinal = ordinal;
        if (ordinal < base) { base = ordinal; }
        if (ordinal > last) { last = ordinal; }
        normalized[order[i]] = item;
        i++;
    }
    let slots = Int(last - base + 1U);
    let name_table = 40 + slots * 4;
    let ordinal_table = name_table + named * 4;
    let strings = ordinal_table + named * 2;
    if (query_size > 2147483647L || Long(strings) + name_size > 2147483647L - Long(rva)) {
        return pe_export_error("PE export table exceeds the image range");
    }

    // use the COFF byte-name index, exports must not scan every symbol independently.
    let inputs: Vector(CoffObject) = [];
    i = 0;
    while (i < objects.length()) { inputs.append(objects[i]); i++; }
    let query = CoffObject();
    i = 0;
    while (i < normalized.length()) {
        let offset = query.bytes.length();
        pe_export_string(ref query.bytes, normalized[i].symbol);
        query.symbols.append(CoffSymbol(name=CoffSpan(offset, normalized[i].symbol.length()), value=0U, section=0,
            type=0U, storage=Byte(2), table_index=i, aux=CoffSpan()));
        i++;
    }
    let query_id = inputs.length();
    inputs.append(query);
    let index = CoffNameIndex();
    let object_id = 0;
    while (object_id < objects.length()) {
        let object = objects[object_id];
        i = 0;
        while (i < object.symbols.length()) {
            let symbol = object.symbols[i];
            if (symbol.storage == Byte(2) && symbol.section > 0) {
                let slot = coff_name_slot(inputs, ref index, CoffSymbolRef(object_id, i));
                let entry = index.entries[slot];
                entry.definition = CoffSymbolRef(object_id, i);
                index.entries[slot] = entry;
            }
            i++;
        }
        object_id++;
    }

    let bytes: Vector(Byte) = [];
    while (bytes.length() < strings) { bytes.append(Byte(0)); }
    let image_offset = pe_export_string(ref bytes, image_name);
    coff_put_word(bytes, 12, 4, UInt64(rva) + UInt64(image_offset));
    coff_put_word(bytes, 16, 4, UInt64(base));
    coff_put_word(bytes, 20, 4, UInt64(slots));
    coff_put_word(bytes, 24, 4, UInt64(named));
    coff_put_word(bytes, 28, 4, UInt64(rva) + 40UL);
    if (named != 0) {
        coff_put_word(bytes, 32, 4, UInt64(rva) + UInt64(name_table));
        coff_put_word(bytes, 36, 4, UInt64(rva) + UInt64(ordinal_table));
    }

    let name_id = 0;
    let bindings: Vector(PeExportBinding) = [];
    i = 0;
    while (i < order.length()) {
        let request_id = order[i];
        let item = normalized[request_id];
        let slot = coff_name_slot(inputs, ref index, CoffSymbolRef(query_id, request_id));
        let target = index.entries[slot].definition;
        if (target.object < 0) {
            return PeExportTable(errors=[CoffLinkError(status=CoffLinkStatus.UndefinedSymbol, object=-1,
                message="PE export symbol '" + item.symbol + "' is not defined by an input object")]);
        }
        if (target.object == import_object) { return pe_export_error("PE export must be defined by an input object, not a DLL import"); }
        let symbol = objects[target.object].symbols[target.symbol];
        let section = objects[target.object].sections[symbol.section - 1];
        let place = layout.placements[target.object][symbol.section - 1];
        if (place.section == 0 || symbol.value >= section.size) { return pe_export_error("PE export must point into loadable storage"); }

        let assigned = item.ordinal;
        if (assigned is null) { return pe_export_error("Missing assigned PE export ordinal"); }
        let ordinal: UInt32 = assigned;
        bindings.append(PeExportBinding(item.name, item.symbol, ordinal, UInt32(name_id), (section.flags & 0x20000000U) == 0U));
        let address_slot = Int(ordinal - base);
        coff_put_word(bytes, 40 + address_slot * 4, 4, UInt64(place.rva) + UInt64(symbol.value));
        if (item.name.length() != 0) {
            let name_offset = pe_export_string(ref bytes, item.name);
            coff_put_word(bytes, name_table + name_id * 4, 4, UInt64(rva) + UInt64(name_offset));
            coff_put_word(bytes, ordinal_table + name_id * 2, 2, UInt64(address_slot));
            name_id++;
        }
        i++;
    }
    return PeExportTable(bytes=bytes, bindings=bindings);
}
