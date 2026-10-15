// src/compiler/machine/aarch64/allocator.wl
import * from "model.wl"
import WirValueID, wir_id_index from "../../wir/model.wl"


struct A64ValueMap(registers: Vector(A64Register), next_register: Int, next_float_register: Int)

func a64_work_register(index: Int) -> A64Register {
// X9-X15 are caller-saved temporaries and do not overlap ABI argument registers.
// X16 and X17 remain free for large address formation and linker veneers.
    if (index == 0) { return A64Register.X9; }
    if (index == 1) { return A64Register.X10; }
    if (index == 2) { return A64Register.X11; }
    if (index == 3) { return A64Register.X12; }
    if (index == 4) { return A64Register.X13; }
    if (index == 5) { return A64Register.X14; }
    if (index == 6) { return A64Register.X15; }

    return A64Register.None;
}

func a64_float_work_register(index: Int) -> A64Register {
// V16-V22 are volatile under AAPCS64 and do not overlap argument registers.
    if (index == 0) { return A64Register.V16; }
    if (index == 1) { return A64Register.V17; }
    if (index == 2) { return A64Register.V18; }
    if (index == 3) { return A64Register.V19; }
    if (index == 4) { return A64Register.V20; }
    if (index == 5) { return A64Register.V21; }
    if (index == 6) { return A64Register.V22; }

    return A64Register.None;
}

func a64_new_value_map(value_count: Int) -> A64ValueMap {
    let registers: Vector(A64Register) = [];
    let i: Int = 0;

    while (i < value_count) {
        registers.append(A64Register.None);
        i++;
    }

    return A64ValueMap(registers=registers, next_register=0, next_float_register=0);
}

func a64_alloc_register(ref values: A64ValueMap, floating: Bool) -> A64Register {
    if floating {
        let register: A64Register = a64_float_work_register(values.next_float_register % 7);
        values.next_float_register++;

        return register;
    }

    let register: A64Register = a64_work_register(values.next_register % 7);
    values.next_register++;

    return register;
}

func a64_bind_value(ref values: A64ValueMap, value_id: WirValueID, register: A64Register) -> Bool {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= values.registers.length()) { return false; }

    values.registers[index] = register;
    return true;
}

func a64_mapped_register(ref values: A64ValueMap, value_id: WirValueID) -> A64Register {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= values.registers.length()) { return A64Register.None; }

    return values.registers[index];
}
