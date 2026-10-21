// Test: UNION_STORAGE
// File: tests/integration/tooling/test_union_storage.wl
// Focus: Source union storage agrees with low-level WIR layouts across targets.

import * from "../../../src/compiler/context.wl"
import select_target, get_target_triple, get_target_pointer_bits from "../../../src/compiler/target.wl"
import no_position from "../../../src/frontend/diagnostics.wl"
import * from "../../../src/compiler/wir/model.wl"
import new_wir_module from "../../../src/compiler/wir/builder.wl"
import wir_type_layout from "../../../src/compiler/wir/layout.wl"
import WirTypeMap, new_wir_type_map, wir_union_storage from "../../../src/compiler/wir/lowering/types.wl"
import new_ast_arena from "../../../src/frontend/arena.wl"


func check_storage(ref source: Compiler, ref types: WirTypeMap, ref program: WirModule, members: Vector(Int)) -> Bool {
    let id: Int = get_union_type_id(ref source, members, no_position());
    let layout: UnionLayout = get_union_layout(ref source, id);
    if (union_member_index(ref source, id, TYPE_STRING) >= 0 && layout.size != get_pointer_size_bytes() * 2) {
        print("FAIL: string payload", layout.size, layout.alignment, layout.payload_type, layout.payload_count);
        return false;
    }
    let storage: WirTypeID = wir_union_storage(ref types, ref source, ref program, id);
    let physical: WirTypeLayout = wir_type_layout(program, storage);
    if (!layout.valid || !physical.valid || UInt64(layout.size) != physical.size ||
        layout.alignment != physical.alignment || physical.field_offsets.length() != 2 ||
        physical.field_offsets[1] != UInt64(layout.payload_offset)) {
        print("FAIL: union storage differs for", program.target);
        return false;
    }
    return true;
}

func check_target(target: String) -> Bool {
    if (!select_target(target)) { return false; }
    let source: Compiler = new_compiler("", false, false, new_ast_arena())?;
    catch(err) { return false; }
    let program: WirModule = new_wir_module(target, get_target_pointer_bits());
    let types: WirTypeMap = new_wir_type_map();

    if (!check_storage(ref source, ref types, ref program, [TYPE_INT, TYPE_BOOL]) ||
        !check_storage(ref source, ref types, ref program, [TYPE_NULL, TYPE_STRING]) ||
        !check_storage(ref source, ref types, ref program, [TYPE_NULL, TYPE_INT128]) ||
        !check_storage(ref source, ref types, ref program, [TYPE_BYTE, TYPE_NULL]) ||
        !check_storage(ref source, ref types, ref program, [TYPE_INT16, TYPE_FLOAT32, TYPE_LONG])) {
        return false;
    }

    let narrow: Int = get_union_type_id(ref source, [TYPE_INT, TYPE_NULL], no_position());
    let broad: Int = get_union_type_id(ref source, [TYPE_STRING, TYPE_INT, TYPE_NULL], no_position());
    if (!union_accepts_type(ref source, broad, narrow) || !union_accepts_type(ref source, broad, TYPE_STRING) ||
        union_accepts_type(ref source, narrow, broad) || union_accepts_type(ref source, narrow, TYPE_UINT32) ||
        union_accepts_type(ref source, narrow, TYPE_NULLPTR) || union_accepts_type(ref source, TYPE_INT, narrow)) {
        print("FAIL: union member matching");
        return false;
    }
    return true;
}

func main() -> Int {
    let previous: String = get_target_triple();
    let targets: Vector(String) = ["i686-pc-windows-msvc", "i686-unknown-linux-gnu", "armv7-unknown-linux-gnueabihf",
        "x86_64-pc-windows-msvc", "x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu", "x86_64-apple-darwin", "arm64-apple-darwin"];
    let i: Int = 0;
    while (i < targets.length()) {
        if (!check_target(targets[i])) { return 1; }
        i++;
    }
    select_target(previous);
    print("PASS: union storage and member matching");
    return 0;
}
