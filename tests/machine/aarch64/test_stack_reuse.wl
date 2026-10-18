// Test: AARCH64_STACK_REUSE
// File: tests/machine/aarch64/test_stack_reuse.wl
// Focus: Index sparse homes, reuse dead temporaries and preserve addressed storage and live-outs.

import "file"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import wir_type_layouts from "../../../src/compiler/wir/layout.wl"
import * from "../../../src/compiler/machine/aarch64/allocator.wl"
import * from "../../../src/compiler/machine/aarch64/stack.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import a64_lower_module from "../../../src/compiler/machine/aarch64/module.wl"
import * from "../../../src/compiler/machine/aarch64/model.wl"
import a64_elf_object from "../../../src/compiler/machine/aarch64/elf.wl"


func indexed() -> Bool {
    let first = WirValueID(101U);
    let far = WirValueID(1000000U);
    let dense = a64_stack_index([A64StackSlot(value=first, offset=0, size=8)], A64ValueRange(base=100, count=3));
    if (dense.indices.length() != 3 || a64_find_stack_slot(dense, first).value != first ||
        a64_find_stack_slot(dense, WirValueID(100U)).value != NO_WIR_VALUE ||
        a64_find_stack_slot(dense, NO_WIR_VALUE).value != NO_WIR_VALUE) {
        return false;
    }

    let sparse = a64_stack_index([A64StackSlot(value=first, offset=0, size=8),
        A64StackSlot(value=far, offset=16, size=16)], A64ValueRange(base=100, count=1000000));
    return sparse.indices.length() == 0 && a64_find_stack_slot(sparse, first).offset == 0 &&
           a64_find_stack_slot(sparse, far).offset == 16 &&
           a64_find_stack_slot(sparse, WirValueID(500000U)).value == NO_WIR_VALUE;
}

func intervals() -> Bool {
    let pool: A64HomePool = A64HomePool(size=0, regions=[], free=Dict(), ends=[]);
    a64_begin_home_block(ref pool, 5);
    let a = a64_reuse_home(ref pool, 8, 8, 1);
    let b = a64_reuse_home(ref pool, 16, 16, 2);
    a64_expire_homes(ref pool, 1);
    let c = a64_reuse_home(ref pool, 8, 8, 3);
    if (a != 0 || b != 16 || c == a || b % 16 != 0) { return false; }

    a64_expire_homes(ref pool, 2);
    let d = a64_reuse_home(ref pool, 8, 8, 4);
    a64_expire_homes(ref pool, 3);
    let e = a64_reuse_home(ref pool, 16, 16, 4);
    if (d != a || e != b || pool.size != 40) { return false; }
    a64_expire_homes(ref pool, 4);
    a64_expire_homes(ref pool, 5);

    pool.size = 2147483640;
    return a64_reserve_stack(ref pool, 16, 16) == -1;
}

func records(ref program: WirModule, block: WirBlockID, type: WirTypeID, int: WirTypeID, count: Int) -> WirValueID {
    let zero = wir_const_int(ref program, int, UInt128(0U));
    let result = zero;
    let i = 0;
    while (i < count) {
        let value = wir_const_int(ref program, int, UInt128(UInt32(i)));
        let record = wir_struct_value(ref program, block, type, [value, zero, zero, zero], "record", no_wir_location());
        result = wir_field(ref program, block, record, 0, "field", no_wir_location());
        i++;
    }
    return result;
}

func main() -> Int {
    if (!indexed() || !intervals()) {
        print("FAIL: AArch64 stack index or expiry buckets");
        return 1;
    }

    let program = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let int = wir_signed_int_type(ref program, 64);
    let record = wir_struct_type(ref program, [int, int, int, int]);
    let function = wir_add_function(ref program, "reuse", [], int, false, WirLinkage.Exported, WirABI.C);
    let entry = wir_add_block(ref program, function, "entry", []);
    let result = records(ref program, entry, record, int, 256);
    wir_return(ref program, entry, result, no_wir_location());

    let current = program.arena.functions[wir_id_index(UInt32(function))];
    let layouts = wir_type_layouts(program);
    let stack = a64_stack_layout(ref program, ref current, layouts);
    if (stack.message.length() != 0 || stack.frame_size > 64 || stack.frame_size % 16 != 0 ||
        stack.homes.slots.length() != 512) {
        print("FAIL: short-lived AArch64 homes were not reused, frame ", stack.frame_size);
        return 1;
    }

    let preserve = wir_add_function(ref program, "preserve", [], int, false, WirLinkage.Exported, WirABI.C);
    entry = wir_add_block(ref program, preserve, "entry", []);
    let next = wir_add_block(ref program, preserve, "next", []);
    let zero = wir_const_int(ref program, int, UInt128(0U));
    let forty_two = wir_const_int(ref program, int, UInt128(42U));
    let kept = wir_struct_value(ref program, entry, record, [forty_two, zero, zero, zero], "kept", no_wir_location());
    wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(next, [])], no_wir_location());
    records(ref program, next, record, int, 64);
    let field = wir_field(ref program, next, kept, 0, "kept.field", no_wir_location());
    wir_return(ref program, next, field, no_wir_location());

    let addressed = wir_add_function(ref program, "addressed", [], int, false, WirLinkage.Exported, WirABI.C);
    entry = wir_add_block(ref program, addressed, "entry", []);
    let storage = wir_stack_alloc(ref program, entry, record, "storage", no_wir_location());
    let value = wir_struct_value(ref program, entry, record, [forty_two, zero, zero, zero], "original", no_wir_location());
    wir_store(ref program, entry, value, storage, no_wir_location());
    let address = wir_field_address(ref program, entry, storage, 0, "address", no_wir_location());
    records(ref program, entry, record, int, 64);
    result = wir_load(ref program, entry, address, "loaded", no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());

    let errors = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: stack reuse WIR: ", errors[0]);
        return 1;
    }
    let lowered = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: stack reuse lowering: ", lowered.errors[0]);
        return 1;
    }
    let bytes = a64_elf_object(A64Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) { return 1; }
    let output = file.create("a64_stack_reuse.o")?;
    catch(err) { return 1; }
    output.write_bytes(bytes)?;
    catch(err) { return 1; }
    output.close();

    print("PASS: AArch64 indexed and reusable homes");
    return 0;
}
