// src/compiler/machine/aarch64/allocator.wl
import * from "model.wl"
import * from "../../wir/model.wl"


const A64_NO_NEXT_USE: Int = 2147483647;

struct A64UseQueue(positions: Vector(Int), cursor: Int)

struct A64UseTable(
    base: Int,
    dense_count: Int,
    sparse_indices: Dict(UInt32, Int),
    queues: Vector(A64UseQueue)
)

struct A64ValueRange(base: Int, count: Int)

struct A64RegisterPair(low: A64Register, high: A64Register)

struct A64RegisterBinding(register: A64Register, value: WirValueID, held: Bool, dirty: Bool, wide: Bool)

struct A64ValueMap(
    registers: Vector(A64Register),
    wide_high: Vector(A64Register),
    bindings: Vector(A64RegisterBinding),
    uses: A64UseTable,
    position: Int,
    next_register: Int,
    next_float_register: Int
)

func a64_include_value(value: WirValueID, ref first: Int, ref last: Int) -> Void {
    let index: Int = wir_id_index(UInt32(value));

    if (index < 0) {
        return;
    }

    if (first < 0 || index < first) { first = index; }
    if (index > last) { last = index; }
}

func a64_function_value_range(ref program: WirModule, order: Vector(WirBlockID)) -> A64ValueRange {
    let first: Int = -1;
    let last: Int = -1;
    let block_index: Int = 0;

    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];
        let i: Int = 0;

        while (i < block.parameters.length()) {
            a64_include_value(block.parameters[i], ref first, ref last);
            i++;
        }

        i = 0;
        while (i < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[i]))];

            if (instruction.result != NO_WIR_VALUE) {
                a64_include_value(instruction.result, ref first, ref last);
            }
            i++;
        }
        block_index++;
    }

    if (first < 0) {
        return A64ValueRange(base=0, count=0);
    }

    return A64ValueRange(base=first, count=last - first + 1);
}

func a64_sparse_add(ref sparse: Vector(WirValueID), seen: Dict(UInt32, Int), range: A64ValueRange, value: WirValueID) -> Void {
    let index: Int = wir_id_index(UInt32(value));

    if (index < 0 || (index >= range.base && index < range.base + range.count)) { return; }
    if (seen.lookup(UInt32(value)) != 0) { return; }

    sparse.append(value);
    seen.put(UInt32(value), sparse.length());
}

func a64_sparse_values(ref program: WirModule, order: Vector(WirBlockID), range: A64ValueRange) -> Vector(WirValueID) {
    let sparse: Vector(WirValueID) = [];
    let seen: Dict(UInt32, Int) = Dict();

    if (order.length() == 0) { return sparse; }

    let function_id: WirFuncID = program.arena.blocks[wir_id_index(UInt32(order[0]))].function;
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let i: Int = 0;

    while (i < function.parameters.length()) {
        a64_sparse_add(ref sparse, seen, range, function.parameters[i]);
        i++;
    }

    let block_index: Int = 0;
    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];
        i = 0;

        while (i < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[i]))];
            let operand_index: Int = 0;

            while (operand_index < instruction.operands.length()) {
                a64_sparse_add(ref sparse, seen, range, instruction.operands[operand_index]);
                operand_index++;
            }

            let edge_index: Int = 0;
            while (edge_index < instruction.edges.length()) {
                let argument_index: Int = 0;

                while (argument_index < instruction.edges[edge_index].arguments.length()) {
                    a64_sparse_add(ref sparse, seen, range, instruction.edges[edge_index].arguments[argument_index]);
                    argument_index++;
                }
                edge_index++;
            }
            i++;
        }
        block_index++;
    }

    return sparse;
}

func a64_new_use_table(base: Int, dense_count: Int, sparse: Vector(WirValueID)) -> A64UseTable {
    let queues: Vector(A64UseQueue) = [];
    let indices: Dict(UInt32, Int) = Dict();
    let i: Int = 0;

    while (i < dense_count + sparse.length()) {
        queues.append(A64UseQueue(positions=[], cursor=0));
        i++;
    }

    i = 0;
    while (i < sparse.length()) {
        indices.put(UInt32(sparse[i]), dense_count + i + 1);
        i++;
    }

    return A64UseTable(base=base, dense_count=dense_count, sparse_indices=indices, queues=queues);
}

func a64_use_index(ref table: A64UseTable, value: WirValueID) -> Int {
    let index: Int = wir_id_index(UInt32(value));

    if (index >= table.base && index < table.base + table.dense_count) {
        return index - table.base;
    }

    return table.sparse_indices.lookup(UInt32(value)) - 1;
}

func a64_record_use(ref table: A64UseTable, value: WirValueID, position: Int) -> Void {
    let index: Int = a64_use_index(ref table, value);

    if (index < 0 || index >= table.queues.length()) {
        return;
    }

    let queue: A64UseQueue = table.queues[index];
    queue.positions.append(position);
    table.queues[index] = queue;
}

func a64_collect_uses(ref program: WirModule, order: Vector(WirBlockID)) -> A64UseTable {
    let range: A64ValueRange = a64_function_value_range(ref program, order);
    let sparse: Vector(WirValueID) = a64_sparse_values(ref program, order, range);
    let table: A64UseTable = a64_new_use_table(range.base, range.count, sparse);
    let position: Int = 0;
    let block_index: Int = 0;

    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];
        let instruction_index: Int = 0;

        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[
                wir_id_index(UInt32(block.instructions[instruction_index]))
            ];
            let operand_index: Int = 0;

            while (operand_index < instruction.operands.length()) {
                a64_record_use(ref table, instruction.operands[operand_index], position);
                operand_index++;
            }

            let edge_index: Int = 0;
            while (edge_index < instruction.edges.length()) {
                let argument_index: Int = 0;

                while (argument_index < instruction.edges[edge_index].arguments.length()) {
                    a64_record_use(ref table, instruction.edges[edge_index].arguments[argument_index], position);
                    argument_index++;
                }
                edge_index++;
            }
            position++;
            instruction_index++;
        }
        block_index++;
    }

    return table;
}

func a64_next_use(ref table: A64UseTable, value: WirValueID, position: Int) -> Int {
    let index: Int = a64_use_index(ref table, value);

    if (index < 0 || index >= table.queues.length()) { return A64_NO_NEXT_USE; }

    let queue: A64UseQueue = table.queues[index];
    let cursor: Int = queue.cursor;

    while (cursor < queue.positions.length() && queue.positions[cursor] <= position) {
        cursor++;
    }

    if (cursor >= queue.positions.length()) { return A64_NO_NEXT_USE; }

    return queue.positions[cursor];
}

func a64_consume_use(ref table: A64UseTable, value: WirValueID, position: Int) -> Void {
    let index: Int = a64_use_index(ref table, value);

    if (index < 0 || index >= table.queues.length()) {
        return;
    }

    let queue: A64UseQueue = table.queues[index];
    while (queue.cursor < queue.positions.length() && queue.positions[queue.cursor] <= position) {
        queue.cursor++;
    }
    table.queues[index] = queue;
}

func a64_finish_instruction(ref values: A64ValueMap, instruction: WirInstruction) -> Void {
    let i: Int = 0;

    while (i < instruction.operands.length()) {
        a64_consume_use(ref values.uses, instruction.operands[i], values.position);
        i++;
    }

    i = 0;
    while (i < instruction.edges.length()) {
        let j: Int = 0;

        while (j < instruction.edges[i].arguments.length()) {
            a64_consume_use(ref values.uses, instruction.edges[i].arguments[j], values.position);
            j++;
        }
        i++;
    }

    i = 0;
    while (i < values.bindings.length()) {
        let binding: A64RegisterBinding = values.bindings[i];

        if (binding.held || (binding.value != NO_WIR_VALUE &&
            a64_next_use(ref values.uses, binding.value, values.position) == A64_NO_NEXT_USE)) {
            a64_release_binding(ref values, i);
        }
        i++;
    }

    values.position++;
}

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

func a64_new_value_map(ref program: WirModule, order: Vector(WirBlockID)) -> A64ValueMap {
    let registers: Vector(A64Register) = [];
    let wide_high: Vector(A64Register) = [];
    let bindings: Vector(A64RegisterBinding) = [];
    let i: Int = 0;

    while (i < program.arena.values.length()) {
        registers.append(A64Register.None);
        wide_high.append(A64Register.None);
        i++;
    }

    i = 0;
    while (i < 7) {
        bindings.append(A64RegisterBinding(register=a64_work_register(i), value=NO_WIR_VALUE, held=false, dirty=false, wide=false));
        i++;
    }

    i = 0;
    while (i < 7) {
        bindings.append(A64RegisterBinding(register=a64_float_work_register(i), value=NO_WIR_VALUE, held=false, dirty=false, wide=false));
        i++;
    }

    return A64ValueMap(
        registers=registers,
        wide_high=wide_high,
        bindings=bindings,
        uses=a64_collect_uses(ref program, order),
        position=0,
        next_register=0,
        next_float_register=0
    );
}

func a64_binding_index(ref values: A64ValueMap, register: A64Register) -> Int {
    let i: Int = 0;

    while (i < values.bindings.length()) {
        if (values.bindings[i].register == register) { return i; }
        i++;
    }

    return -1;
}

func a64_release_binding(ref values: A64ValueMap, index: Int) -> Void {
    if (index < 0 || index >= values.bindings.length()) { return; }

    let binding: A64RegisterBinding = values.bindings[index];
    if (binding.value != NO_WIR_VALUE) {
        let value_index: Int = wir_id_index(UInt32(binding.value));

        if (value_index >= 0 && value_index < values.registers.length()) {
            if (binding.wide) {
                let low: A64Register = values.registers[value_index];
                let high: A64Register = values.wide_high[value_index];
                let low_index: Int = a64_binding_index(ref values, low);
                let high_index: Int = a64_binding_index(ref values, high);

                values.registers[value_index] = A64Register.None;
                values.wide_high[value_index] = A64Register.None;

                if (low_index >= 0) {
                    values.bindings[low_index] = A64RegisterBinding(register=low, value=NO_WIR_VALUE, held=false, dirty=false, wide=false);
                }
                if (high_index >= 0) {
                    values.bindings[high_index] = A64RegisterBinding(register=high, value=NO_WIR_VALUE, held=false, dirty=false, wide=false);
                }
                return;
            }

            if (values.registers[value_index] == binding.register) {
                values.registers[value_index] = A64Register.None;
            }
        }
    }

    values.bindings[index] = A64RegisterBinding(
        register=binding.register,
        value=NO_WIR_VALUE,
        held=false,
        dirty=false,
        wide=false
    );
}

func a64_clobber_register(ref values: A64ValueMap, register: A64Register) -> Void {
    a64_release_binding(ref values, a64_binding_index(ref values, register));
}

func a64_clear_bindings(ref values: A64ValueMap) -> Void {
    let i: Int = 0;

    while (i < values.bindings.length()) {
        a64_release_binding(ref values, i);
        i++;
    }
}

func a64_reset_temporaries(ref values: A64ValueMap) -> Void {
    a64_clear_bindings(ref values);
    values.next_register = 0;
    values.next_float_register = 0;
}

func a64_select_register(ref values: A64ValueMap, floating: Bool) -> Int {
// Keep the choice local and bounded. Go's SSA allocator makes the same basic
// trade: prefer a free register, otherwise evict the value used farthest away.
    let first: Int = 0;
    let end: Int = 7;
    if floating {
        first = 7;
        end = 14;
    }

    let selected: Int = -1;
    let farthest: Int = -1;
    let i: Int = first;

    while (i < end) {
        let binding: A64RegisterBinding = values.bindings[i];
        if (!binding.held) {
            if (binding.value == NO_WIR_VALUE) {
                selected = i;
                break;
            }

            let next: Int = a64_next_use(ref values.uses, binding.value, values.position - 1);
            if (next == A64_NO_NEXT_USE) {
                selected = i;
                break;
            }
            if (next > farthest) {
                farthest = next;
                selected = i;
            }
        }
        i++;
    }

    if (selected < 0) {
        // A few 128-bit sequences need more scratch names than this small
        // bank contains. They were written to tolerate the old rotating
        // aliases, keep that fallback until wide values get pair allocation.
        if floating {
            selected = 7 + (values.next_float_register % 7);
            values.next_float_register++;
        } else {
            selected = values.next_register % 7;
            values.next_register++;
        }
    }

    return selected;
}

func a64_claim_register(ref values: A64ValueMap, index: Int) -> A64Register {
    if (index < 0 || index >= values.bindings.length()) {
        return A64Register.None;
    }

    let register: A64Register = values.bindings[index].register;
    a64_release_binding(ref values, index);
    values.bindings[index] = A64RegisterBinding(register=register, value=NO_WIR_VALUE, held=true, dirty=false, wide=false);

    return register;
}

func a64_bind_value(ref values: A64ValueMap, value_id: WirValueID, register: A64Register, dirty: Bool) -> Bool {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= values.registers.length()) { return false; }

    let binding_index: Int = a64_binding_index(ref values, register);
    if (binding_index < 0) {
        values.registers[index] = A64Register.None;
        return true;
    }

    let previous: A64Register = values.registers[index];
    if (previous != A64Register.None && previous != register) {
        a64_clobber_register(ref values, previous);
    }

    a64_release_binding(ref values, binding_index);
    values.registers[index] = register;
    values.wide_high[index] = A64Register.None;
    values.bindings[binding_index] = A64RegisterBinding(register=register, value=value_id, held=false, dirty=dirty, wide=false);

    return true;
}

func a64_mapped_register(ref values: A64ValueMap, value_id: WirValueID) -> A64Register {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= values.registers.length()) { return A64Register.None; }

    return values.registers[index];
}

func a64_bind_register_pair(
    ref values: A64ValueMap,
    value_id: WirValueID,
    low: A64Register,
    high: A64Register,
    dirty: Bool
) -> Bool {
    let value_index: Int = wir_id_index(UInt32(value_id));
    let low_index: Int = a64_binding_index(ref values, low);
    let high_index: Int = a64_binding_index(ref values, high);
    if (value_index < 0 || value_index >= values.registers.length() ||
        low_index < 0 || high_index < 0 || low_index == high_index) {
        return false;
    }

    a64_release_binding(ref values, low_index);
    a64_release_binding(ref values, high_index);

    values.registers[value_index] = low;
    values.wide_high[value_index] = high;
    values.bindings[low_index] = A64RegisterBinding(register=low, value=value_id, held=false, dirty=dirty, wide=true);
    values.bindings[high_index] = A64RegisterBinding(register=high, value=value_id, held=false, dirty=dirty, wide=true);
    return true;
}

func a64_mapped_register_pair(ref values: A64ValueMap, value_id: WirValueID) -> A64RegisterPair {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= values.registers.length() ||
        values.registers[index] == A64Register.None || values.wide_high[index] == A64Register.None) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    return A64RegisterPair(low=values.registers[index], high=values.wide_high[index]);
}
