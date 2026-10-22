// src/compiler/wir/storage.wl
import * from "model.wl"
import * from "layout.wl"


struct WirStorageParts(elements: Vector(WirValueID), offsets: Vector(UInt64))

func wir_has_storage(program: WirModule, value_id: WirValueID) -> Bool {
    let value = program.arena.values[wir_id_index(UInt32(value_id))];
    if (value.kind != WirValueKind.Constant) { return false; }
    let constant = program.arena.constants[wir_id_index(value.owner)];
    if (constant.kind == WirConstKind.Storage) { return true; }
    if (constant.kind != WirConstKind.Aggregate) { return false; }
    let i = 0;
    while (i < constant.elements.length()) {
        if (wir_has_storage(program, constant.elements[i])) { return true; }
        i++;
    }
    return false;
}

func wir_storage_parts(program: WirModule, layouts: Vector(WirTypeLayout), value_id: WirValueID, offset: UInt64, parts: WirStorageParts) -> Void {
// flatten nested initializers without turning symbolic addresses into host integers
    let value = program.arena.values[wir_id_index(UInt32(value_id))];
    if (value.kind == WirValueKind.Constant) {
        let constant = program.arena.constants[wir_id_index(value.owner)];
        if (constant.kind == WirConstKind.Zero) { return; }
        if (constant.kind == WirConstKind.Aggregate || constant.kind == WirConstKind.Storage) {
            let type = program.arena.types[wir_id_index(UInt32(value.type_id))];
            let layout = layouts[wir_id_index(UInt32(value.type_id))];
            let i = 0;
            while (i < constant.elements.length()) {
                let start: UInt64 = 0UL;
                if (constant.kind == WirConstKind.Storage) { start = constant.offsets[i]; }
                else if (type.kind == WirTypeKind.Struct) { start = layout.field_offsets[i]; }
                else { start = UInt64(i) * layouts[wir_id_index(UInt32(type.element))].size; }
                wir_storage_parts(program, layouts, constant.elements[i], offset + start, parts);
                i++;
            }
            return;
        }
    }
    parts.elements.append(value_id);
    parts.offsets.append(offset);
}
