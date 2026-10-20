// src/compiler/machine/x86_64/allocator.wl
import * from "model.wl"
import * from "../allocator.wl"
import * from "../spill.wl"
import * from "../../wir/model.wl"


const X86_NO_NEXT_USE: Int = 2147483647;

// next-use allocation keeps this pass cheap. Record every use once, then spill
// the value needed farthest in the future. This loses some opportunities that a
// graph allocator would find, but it does not build or color an interference graph.

struct X86UseQueue(
    positions: Vector(Int),
    cursor: Int,
    preferred: X86Register,
    incoming: X86Register
)

struct X86UseTable(
    base: Int,
    dense_count: Int,
    sparse: Vector(WirValueID),
    sparse_indices: Dict(UInt32, Int),
    queues: Vector(X86UseQueue)
)

struct X86ValueRange(base: Int, count: Int)

struct X86RegisterPair(low: X86Register, high: X86Register)

struct X86RegisterBinding(
    register: X86Register,
    value: WirValueID,
    dirty: Bool,
    wide: Bool
)

struct X86RegisterChoice(
    register: X86Register,
    evicted: WirValueID
)

struct X86RegisterPlan(
    uses: X86UseTable,
    bindings: Vector(X86RegisterBinding),
    // pair halves belong to bindings, edge snapshots only copy the register bank.
    wide_low: Vector(X86Register),
    wide_high: Vector(X86Register)
)

struct X86SpillBinding(
    offset: Int,
    value: WirValueID
)

struct X86SpillPlan(
    // indices store binding + 1, zero means the value has no spill home.
    // values outside the function's dense ID range use the sparse map.
    bindings: Vector(X86SpillBinding),
    base: Int,
    dense_count: Int,
    indices: Vector(Int),
    sparse_indices: Dict(UInt32, Int),
    free: Vector(Int),
    free_count: Int
)

func x86_include_value(value: WirValueID, ref first: Int, ref last: Int) -> Void {
    let index: Int = wir_id_index(UInt32(value));

    if (index < 0) {
        return;
    }

    if (first < 0 || index < first) { first = index; }
    if (index > last) { last = index; }
}

func x86_function_value_range(ref program: WirModule, order: Vector(WirBlockID)) -> X86ValueRange {
    if (order.length() == 0) {
        return X86ValueRange(base=0, count=0);
    }

    let first: Int = -1;
    let last: Int = -1;
    let i: Int = 0;
    let block_index: Int = 0;

    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];
        i = 0;
        while (i < block.parameters.length()) {
            x86_include_value(block.parameters[i], ref first, ref last);
            i++;
        }
        i = 0;
        while (i < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[i]))];

            if (instruction.result != NO_WIR_VALUE) {
                x86_include_value(instruction.result, ref first, ref last);
            }
            i++;
        }
        block_index++;
    }

    if (first < 0) {
        return X86ValueRange(base=0, count=0);
    }

    return X86ValueRange(base=first, count=last - first + 1);
}

func x86_sparse_add(ref sparse: Vector(WirValueID), seen: Dict(UInt32, Int), range: X86ValueRange, value: WirValueID) -> Void {
    let index: Int = wir_id_index(UInt32(value));

    if (index < 0 || (index >= range.base && index < range.base + range.count)) { return; }
    if (seen.lookup(UInt32(value)) != 0) {
        return;
    }
    sparse.append(value);
    seen.put(UInt32(value), sparse.length());
}

func x86_function_sparse_values(ref program: WirModule, order: Vector(WirBlockID), range: X86ValueRange) -> Vector(WirValueID) {
    let sparse: Vector(WirValueID) = [];
    let seen: Dict(UInt32, Int) = Dict();

    if (order.length() == 0) { return sparse; }
    let function_id: WirFuncID = program.arena.blocks[wir_id_index(UInt32(order[0]))].function;
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let i: Int = 0;

    while (i < function.parameters.length()) {
        x86_sparse_add(ref sparse, seen, range, function.parameters[i]);
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
                x86_sparse_add(ref sparse, seen, range, instruction.operands[operand_index]);
                operand_index++;
            }

            let edge_index: Int = 0;

            while (edge_index < instruction.edges.length()) {
                let argument_index: Int = 0;

                while (argument_index < instruction.edges[edge_index].arguments.length()) {
                    x86_sparse_add(ref sparse, seen, range, instruction.edges[edge_index].arguments[argument_index]);
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

func x86_new_use_table(base: Int, dense_count: Int, sparse: Vector(WirValueID)) -> X86UseTable {
    let queues: Vector(X86UseQueue) = [];
    let i: Int = 0;

    while (i < dense_count + sparse.length()) {
        queues.append(X86UseQueue(positions=[], cursor=0, preferred=X86Register.None, incoming=X86Register.None));
        i++;
    }

    let indices: Dict(UInt32, Int) = Dict();
    i = 0;
    while (i < sparse.length()) {
        indices.put(UInt32(sparse[i]), dense_count + i + 1);
        i++;
    }

    return X86UseTable(base=base, dense_count=dense_count, sparse=sparse, sparse_indices=indices, queues=queues);
}

func x86_use_index(ref table: X86UseTable, value: WirValueID) -> Int {
    let index: Int = wir_id_index(UInt32(value));

    if (index >= table.base && index < table.base + table.dense_count) {
        return index - table.base;
    }

    return table.sparse_indices.lookup(UInt32(value)) - 1;
}

func x86_record_use(ref table: X86UseTable, value: WirValueID, position: Int) -> Void {
    let index: Int = x86_use_index(ref table, value);

    if (index < 0 || index >= table.queues.length()) {
        return;
    }

    let ptr queue: X86UseQueue = ref table.queues[index];
    queue.positions.append(position);
}

func x86_prefer_register(ref table: X86UseTable, value: WirValueID, register: X86Register) -> Void {
    let index: Int = x86_use_index(ref table, value);

    if (index < 0 || index >= table.queues.length()) {
        return;
    }

    let ptr queue: X86UseQueue = ref table.queues[index];
    queue.preferred = register;
}

func x86_preferred_register(ref table: X86UseTable, value: WirValueID) -> X86Register {
    let index: Int = x86_use_index(ref table, value);

    if (index < 0 || index >= table.queues.length()) { return X86Register.None; }

    return table.queues[index].preferred;
}

func x86_incoming_register(ref table: X86UseTable, value: WirValueID) -> X86Register {
    let index: Int = x86_use_index(ref table, value);

    if (index < 0 || index >= table.queues.length()) { return X86Register.None; }

    return table.queues[index].incoming;
}

func x86_collect_uses(ref program: WirModule, order: Vector(WirBlockID)) -> X86UseTable {
    let range: X86ValueRange = x86_function_value_range(ref program, order);
    let sparse: Vector(WirValueID) = x86_function_sparse_values(ref program, order, range);
    let table: X86UseTable = x86_new_use_table(range.base, range.count, sparse);
    let position = 0;
    let block_index = 0;

    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];

        let instruction_index = 0;

        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[
                wir_id_index(UInt32(block.instructions[instruction_index]))
            ];

            let operand_index = 0;

            while (operand_index < instruction.operands.length()) {
                x86_record_use(ref table, instruction.operands[operand_index], position);
                operand_index++;
            }

            let edge_index = 0;

            while (edge_index < instruction.edges.length()) {
                let argument_index = 0;

                while (argument_index < instruction.edges[edge_index].arguments.length()) {
                    x86_record_use(ref table, instruction.edges[edge_index].arguments[argument_index], position);
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

func x86_next_use(ref table: X86UseTable, value: WirValueID, position: Int) -> Int {
    let index: Int = x86_use_index(ref table, value);

    if (index < 0 || index >= table.queues.length()) { return X86_NO_NEXT_USE; }

    // x86_consume_uses moves the cursor as instructions are emitted, so this
    // search never starts again at the beginning of a long-lived value.
    let ptr queue: X86UseQueue = ref table.queues[index];
    let cursor: Int = queue.cursor;

    while (cursor < queue.positions.length() && queue.positions[cursor] <= position) {
        cursor++;
    }

    if (cursor >= queue.positions.length()) { return X86_NO_NEXT_USE; }

    return queue.positions[cursor];
}

func x86_pending_use(ref table: X86UseTable, value: WirValueID, position: Int) -> Int {
// an operand stays live until the whole instruction has consumed it
    return x86_next_use(ref table, value, position - 1);
}

func x86_consume_uses(ref table: X86UseTable, value: WirValueID, position: Int) -> Void {
    let index: Int = x86_use_index(ref table, value);

    if (index < 0 || index >= table.queues.length()) {
        return;
    }

    let ptr queue: X86UseQueue = ref table.queues[index];

    while (queue.cursor < queue.positions.length() && queue.positions[queue.cursor] <= position) {
        queue.cursor++;
    }

}

func x86_consume_instruction(ref table: X86UseTable, instruction: WirInstruction, position: Int) -> Void {
    let i = 0;

    while (i < instruction.operands.length()) {
        x86_consume_uses(ref table, instruction.operands[i], position);
        i++;
    }

    i = 0;
    while (i < instruction.edges.length()) {
        let j = 0;

        while (j < instruction.edges[i].arguments.length()) {
            x86_consume_uses(ref table, instruction.edges[i].arguments[j], position);
            j++;
        }
        i++;
    }
}

func x86_allocatable_registers() -> Vector(X86Register) {
    return [X86Register.RAX, X86Register.R10, X86Register.R11, X86Register.R8, X86Register.R9];
}

func x86_allocatable_register(register: X86Register) -> Bool {
    return register == X86Register.RAX || register == X86Register.R8 || register == X86Register.R9 ||
           register == X86Register.R10 || register == X86Register.R11 ||
           register == X86Register.XMM0 || register == X86Register.XMM1 || register == X86Register.XMM2 ||
           register == X86Register.XMM3 || register == X86Register.XMM4 || register == X86Register.XMM5;
}

func x86_register_plan(uses: X86UseTable) -> X86RegisterPlan {
    let bindings: Vector(X86RegisterBinding) = [];
    let wide_low: Vector(X86Register) = [];
    let wide_high: Vector(X86Register) = [];
    let registers: Vector(X86Register) = x86_allocatable_registers();

    let i = 0;

    while (i < registers.length()) {
        bindings.append(X86RegisterBinding(register=registers[i], value=NO_WIR_VALUE, dirty=false, wide=false));
        i++;
    }
    // RCX and RDX still belong to shifts, division and the memory emitters.
    // R8/R9 are ordinary caller-saved registers now that those users declare
    // their clobbers instead of borrowing the registers behind the allocator.
    bindings.append(X86RegisterBinding(register=X86Register.RCX, value=NO_WIR_VALUE, dirty=false, wide=false));
    bindings.append(X86RegisterBinding(register=X86Register.RDX, value=NO_WIR_VALUE, dirty=false, wide=false));
    bindings.append(X86RegisterBinding(register=X86Register.XMM0, value=NO_WIR_VALUE, dirty=false, wide=false));
    bindings.append(X86RegisterBinding(register=X86Register.XMM1, value=NO_WIR_VALUE, dirty=false, wide=false));
    bindings.append(X86RegisterBinding(register=X86Register.XMM2, value=NO_WIR_VALUE, dirty=false, wide=false));
    bindings.append(X86RegisterBinding(register=X86Register.XMM3, value=NO_WIR_VALUE, dirty=false, wide=false));
    bindings.append(X86RegisterBinding(register=X86Register.XMM4, value=NO_WIR_VALUE, dirty=false, wide=false));
    bindings.append(X86RegisterBinding(register=X86Register.XMM5, value=NO_WIR_VALUE, dirty=false, wide=false));

    i = 0;
    while (i < bindings.length()) {
        wide_low.append(X86Register.None);
        wide_high.append(X86Register.None);
        i++;
    }

    return X86RegisterPlan(uses=uses, bindings=bindings, wide_low=wide_low, wide_high=wide_high);
}

func x86_new_register_plan(ref program: WirModule, order: Vector(WirBlockID)) -> X86RegisterPlan {
    return x86_register_plan(x86_collect_uses(ref program, order));
}

func x86_register_for(ref plan: X86RegisterPlan, value: WirValueID) -> X86Register {
    let i = 0;

    while (i < plan.bindings.length()) {
        if (plan.bindings[i].value == value) {
            return plan.bindings[i].register;
        }

        i++;
    }

    return X86Register.None;
}

func x86_bind_register(ref plan: X86RegisterPlan, register: X86Register, value: WirValueID) -> Void {
    x86_forget_register_value(ref plan, value);

    let i = 0;
    while (i < plan.bindings.length()) {
        let binding: X86RegisterBinding = plan.bindings[i];

        if (binding.register == register) {
            if (binding.value != NO_WIR_VALUE) {
                x86_forget_register_value(ref plan, binding.value);
            }
            binding = plan.bindings[i];
            binding.value = value;
            binding.dirty = false;
            binding.wide = false;
            plan.bindings[i] = binding;

            return;
        }
        i++;
    }
}

func x86_clear_register(ref plan: X86RegisterPlan, register: X86Register) -> Void {
    let i: Int = 0;
    while (i < plan.bindings.length()) {
        if (plan.bindings[i].register == register) {
            let value: WirValueID = plan.bindings[i].value;
            if (value != NO_WIR_VALUE) {
                x86_forget_register_value(ref plan, value);
            }
            return;
        }
        i++;
    }
}

func x86_forget_register_value(ref plan: X86RegisterPlan, value: WirValueID) -> Void {
    if (value == NO_WIR_VALUE) {
        return;
    }

    let i: Int = 0;

    while (i < plan.bindings.length()) {
        let binding: X86RegisterBinding = plan.bindings[i];

        if (binding.value == value) {
            binding.value = NO_WIR_VALUE;
            binding.dirty = false;
            binding.wide = false;
            plan.bindings[i] = binding;
            plan.wide_low[i] = X86Register.None;
            plan.wide_high[i] = X86Register.None;
        }
        i++;
    }
}

func x86_bind_register_pair(ref plan: X86RegisterPlan, value: WirValueID, low: X86Register, high: X86Register, dirty: Bool) -> Bool {
    if (low == X86Register.None || high == X86Register.None || low == high) {
        return false;
    }

    let low_index: Int = -1;
    let high_index: Int = -1;
    let i: Int = 0;
    while (i < plan.bindings.length()) {
        if (plan.bindings[i].register == low) { low_index = i; }
        if (plan.bindings[i].register == high) { high_index = i; }
        i++;
    }
    let value_index: Int = x86_use_index(ref plan.uses, value);
    if (low_index < 0 || high_index < 0 || value_index < 0 || value_index >= plan.uses.queues.length()) {
        return false;
    }

    let low_value: WirValueID = plan.bindings[low_index].value;
    let high_value: WirValueID = plan.bindings[high_index].value;
    if (low_value != NO_WIR_VALUE) { x86_forget_register_value(ref plan, low_value); }
    if (high_value != NO_WIR_VALUE && high_value != low_value) { x86_forget_register_value(ref plan, high_value); }
    x86_forget_register_value(ref plan, value);

    let low_binding: X86RegisterBinding = plan.bindings[low_index];
    low_binding.value = value;
    low_binding.dirty = dirty;
    low_binding.wide = true;
    plan.bindings[low_index] = low_binding;

    let high_binding: X86RegisterBinding = plan.bindings[high_index];
    high_binding.value = value;
    high_binding.dirty = dirty;
    high_binding.wide = true;
    plan.bindings[high_index] = high_binding;

    plan.wide_low[low_index] = low;
    plan.wide_high[low_index] = high;
    plan.wide_low[high_index] = low;
    plan.wide_high[high_index] = high;
    return true;
}

func x86_register_pair_for(ref plan: X86RegisterPlan, value: WirValueID) -> X86RegisterPair {
    let i: Int = 0;
    while (i < plan.bindings.length()) {
        if (plan.bindings[i].value == value && plan.bindings[i].wide) {
            return X86RegisterPair(low=plan.wide_low[i], high=plan.wide_high[i]);
        }
        i++;
    }
    return X86RegisterPair(low=X86Register.None, high=X86Register.None);
}

func x86_register_pair_dirty(ref plan: X86RegisterPlan, value: WirValueID) -> Bool {
    let pair: X86RegisterPair = x86_register_pair_for(ref plan, value);
    if (pair.low == X86Register.None || pair.high == X86Register.None) { return false; }

    let i: Int = 0;
    while (i < plan.bindings.length()) {
        if (plan.bindings[i].register == pair.low) { return plan.bindings[i].dirty; }
        i++;
    }
    return false;
}

func x86_mark_register_pair_clean(ref plan: X86RegisterPlan, value: WirValueID) -> Void {
    let i: Int = 0;
    while (i < plan.bindings.length()) {
        let binding: X86RegisterBinding = plan.bindings[i];
        if (binding.value == value && binding.wide) {
            binding.dirty = false;
            plan.bindings[i] = binding;
        }
        i++;
    }
}

func x86_reset_registers(ref plan: X86RegisterPlan) -> Void {
    let i = 0;

    while (i < plan.bindings.length()) {
        let binding: X86RegisterBinding = plan.bindings[i];
        binding.value = NO_WIR_VALUE;
        binding.dirty = false;
        binding.wide = false;
        plan.bindings[i] = binding;
        i++;
    }

    i = 0;
    while (i < plan.wide_low.length()) {
        plan.wide_low[i] = X86Register.None;
        plan.wide_high[i] = X86Register.None;
        i++;
    }
}

func x86_release_dead_registers(ref plan: X86RegisterPlan, position: Int) -> Void {
    let i = 0;

    while (i < plan.bindings.length()) {
        let binding: X86RegisterBinding = plan.bindings[i];

        if (binding.value != NO_WIR_VALUE &&
            x86_next_use(ref plan.uses, binding.value, position) == X86_NO_NEXT_USE) {
            x86_forget_register_value(ref plan, binding.value);
        }

        i++;
    }
}

func x86_spill_plan_for_range(offsets: Vector(Int), range: X86ValueRange) -> X86SpillPlan {
    let bindings: Vector(X86SpillBinding) = [];
    let indices: Vector(Int) = [];
    let free: Vector(Int) = [];

    let i = 0;

    while (i < offsets.length()) {
        bindings.append(X86SpillBinding(offset=offsets[i], value=NO_WIR_VALUE));
        free.append(offsets.length() - i - 1);
        i++;
    }
    i = 0;
    while (i < range.count) {
        indices.append(0);
        i++;
    }

    return X86SpillPlan(bindings=bindings, base=range.base, dense_count=range.count, indices=indices, sparse_indices=Dict(), free=free, free_count=free.length());
}

func x86_new_spill_plan(offsets: Vector(Int)) -> X86SpillPlan {
    return x86_spill_plan_for_range(offsets, X86ValueRange(base=0, count=0));
}

func x86_copy_spill_plan(ref plan: X86SpillPlan) -> X86SpillPlan {
// each outgoing edge can spill while staging its arguments. Copy the
// bindings and rebuild their indices so the other edge keeps its state.
    let bindings: Vector(X86SpillBinding) = [];
    let indices: Vector(Int) = [];
    let free: Vector(Int) = [];
    let i: Int = 0;

    while (i < plan.dense_count) {
        indices.append(0);
        i++;
    }

    let copy = X86SpillPlan(bindings=bindings, base=plan.base, dense_count=plan.dense_count, indices=indices, sparse_indices=Dict(), free=free, free_count=0);
    i = 0;
    while (i < plan.bindings.length()) {
        let binding: X86SpillBinding = plan.bindings[i];
        copy.bindings.append(binding);
        copy.free.append(0);
        if (binding.value == NO_WIR_VALUE) {
            copy.free[copy.free_count] = i;
            copy.free_count++;
        } else {
            x86_set_spill_index(ref copy, binding.value, i);
        }
        i++;
    }

    return copy;
}

func x86_spill_index(ref plan: X86SpillPlan, value: WirValueID) -> Int {
    let index: Int = wir_id_index(UInt32(value));

    if (index >= plan.base && index < plan.base + plan.dense_count) {
        return plan.indices[index - plan.base] - 1;
    }

    return plan.sparse_indices.lookup(UInt32(value)) - 1;
}

func x86_set_spill_index(ref plan: X86SpillPlan, value: WirValueID, binding: Int) -> Void {
    let index: Int = wir_id_index(UInt32(value));

    if (index >= plan.base && index < plan.base + plan.dense_count) {
        plan.indices[index - plan.base] = binding + 1;

        return;
    }

    if (binding < 0) {
        plan.sparse_indices.remove(UInt32(value));
    } else {
        plan.sparse_indices.put(UInt32(value), binding + 1);
    }
}

func x86_spill_offset(ref plan: X86SpillPlan, value: WirValueID) -> Int {
    let index: Int = x86_spill_index(ref plan, value);

    if (index < 0 || index >= plan.bindings.length()) { return 0; }

    return plan.bindings[index].offset;
}

func x86_claim_spill(ref plan: X86SpillPlan, value: WirValueID) -> Int {
    let existing: Int = x86_spill_index(ref plan, value);

    if (existing >= 0 && existing < plan.bindings.length()) {
        return plan.bindings[existing].offset;
    }

    if (plan.free_count <= 0 || plan.free_count > plan.free.length()) { return 0; }

    // use a stack of vacant bindings, no full slot scan on every eviction.
    plan.free_count--;
    let index: Int = plan.free[plan.free_count];

    if (index < 0 || index >= plan.bindings.length()) { return 0; }
    let binding: X86SpillBinding = plan.bindings[index];
    binding.value = value;
    plan.bindings[index] = binding;
    x86_set_spill_index(ref plan, value, index);

    return binding.offset;
}

func x86_release_dead_spills(ref plan: X86SpillPlan, ref uses: X86UseTable, position: Int) -> Void {
    let i = 0;

    while (i < plan.bindings.length()) {
        let binding: X86SpillBinding = plan.bindings[i];

        if (binding.value != NO_WIR_VALUE && x86_next_use(ref uses, binding.value, position) == X86_NO_NEXT_USE) {
            x86_set_spill_index(ref plan, binding.value, -1);
            binding.value = NO_WIR_VALUE;
            plan.bindings[i] = binding;
            if (plan.free_count < plan.free.length()) {
                plan.free[plan.free_count] = i;
                plan.free_count++;
            }
        }

        i++;
    }
}

func x86_forget_spill_value(ref plan: X86SpillPlan, value: WirValueID) -> Void {
    let index: Int = x86_spill_index(ref plan, value);

    if (index < 0 || index >= plan.bindings.length()) {
        return;
    }

    let binding: X86SpillBinding = plan.bindings[index];
    x86_set_spill_index(ref plan, binding.value, -1);
    binding.value = NO_WIR_VALUE;
    plan.bindings[index] = binding;
    if (plan.free_count < plan.free.length()) {
        plan.free[plan.free_count] = index;
        plan.free_count++;
    }
}

func x86_reset_spills(ref plan: X86SpillPlan) -> Void {
    let i = 0;

    while (i < plan.bindings.length()) {
        let binding: X86SpillBinding = plan.bindings[i];

        if (binding.value != NO_WIR_VALUE) {
            x86_set_spill_index(ref plan, binding.value, -1);
        }
        binding.value = NO_WIR_VALUE;
        plan.bindings[i] = binding;
        plan.free[i] = plan.bindings.length() - i - 1;
        i++;
    }
    plan.free_count = plan.free.length();
}

func x86_spill_capacity(ref program: WirModule, order: Vector(WirBlockID), ref uses: X86UseTable, register_count: Int) -> Int {
    if (order.length() == 0) { return 0; }
    let intervals: Vector(MachineLiveInterval) = [];
    let function = program.arena.functions[wir_id_index(UInt32(program.arena.blocks[wir_id_index(UInt32(order[0]))].function))];
    for (let p = 0; p < function.parameters.length(); p++) {
        let value = function.parameters[p];
        let index = x86_use_index(ref uses, value);
        if (index >= 0 && !machine_rematerializable(ref program, value)) {
            let queue = uses.queues[index];
            if (queue.positions.length() != 0) {
                intervals.append(MachineLiveInterval(start=0, last=queue.positions[queue.positions.length() - 1], input=true));
            }
        }
    }

    let position = 0;
    for (let b = 0; b < order.length(); b++) {
        let block = program.arena.blocks[wir_id_index(UInt32(order[b]))];
        for (let p2 = 0; p2 < block.parameters.length(); p2++) {
            let value = block.parameters[p2];
            let index = x86_use_index(ref uses, value);
            if (index >= 0 && !machine_rematerializable(ref program, value)) {
                let queue = uses.queues[index];
                if (queue.positions.length() != 0) {
                    intervals.append(MachineLiveInterval(start=position, last=queue.positions[queue.positions.length() - 1], input=true));
                }
            }
        }
        for (let j = 0; j < block.instructions.length(); j++) {
            let inst = program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
            let index = x86_use_index(ref uses, inst.result);
            if (inst.result != NO_WIR_VALUE && index >= 0 && !machine_rematerializable(ref program, inst.result)) {
                let queue = uses.queues[index];
                if (queue.positions.length() != 0) {
                    intervals.append(MachineLiveInterval(start=position, last=queue.positions[queue.positions.length() - 1], input=false));
                }
            }
            position++;
        }
    }

    return machine_spill_capacity(ref program, order, intervals, register_count);
}

func x86_choose_register(ref program: WirModule, ref plan: X86RegisterPlan, position: Int) -> X86RegisterChoice {
    return x86_choose_register_except(ref program, ref plan, position, X86Register.None);
}

func x86_choose_register_except(ref program: WirModule, ref plan: X86RegisterPlan, position: Int, avoid: X86Register) -> X86RegisterChoice {
    return x86_choose_register_class(ref program, ref plan, position, avoid, false);
}

func x86_choose_register_class(ref program: WirModule, ref plan: X86RegisterPlan, position: Int, avoid: X86Register, floating: Bool) -> X86RegisterChoice {
    let i = 0;

    while (i < plan.bindings.length()) {
        if (x86_allocatable_register(plan.bindings[i].register) && plan.bindings[i].register != avoid &&
            x86_is_xmm(plan.bindings[i].register) == floating && plan.bindings[i].value == NO_WIR_VALUE) {
            return X86RegisterChoice(register=plan.bindings[i].register, evicted=NO_WIR_VALUE);
        }

        i++;
    }

    let selected = 0;
    let selected_use: Int = -1;
    let selected_remat: Bool = false;
    i = 0;
    while (i < plan.bindings.length()) {
        if (!x86_allocatable_register(plan.bindings[i].register) || plan.bindings[i].register == avoid ||
            x86_is_xmm(plan.bindings[i].register) != floating) {
            i++;
            continue;
        }

        let value: WirValueID = plan.bindings[i].value;
        let next_use: Int = x86_pending_use(ref plan.uses, value, position);
        let remat: Bool = machine_rematerializable(ref program, value);

        if (next_use > selected_use || (next_use == selected_use && remat && !selected_remat)) {
            selected = i;
            selected_use = next_use;
            selected_remat = remat;
        }

        i++;
    }

    if (selected_use < 0) {
        return X86RegisterChoice(register=X86Register.None, evicted=NO_WIR_VALUE);
    }

    return X86RegisterChoice(register=plan.bindings[selected].register, evicted=plan.bindings[selected].value);
}

func x86_choose_register_avoiding(ref program: WirModule, ref plan: X86RegisterPlan, position: Int, first: X86Register, second: X86Register) -> X86RegisterChoice {
    let i = 0;

    while (i < plan.bindings.length()) {
        let binding: X86RegisterBinding = plan.bindings[i];

        if (x86_allocatable_register(binding.register) && !x86_is_xmm(binding.register) &&
            binding.register != first && binding.register != second && binding.value == NO_WIR_VALUE) {
            return X86RegisterChoice(register=binding.register, evicted=NO_WIR_VALUE);
        }

        i++;
    }

    let selected: Int = -1;
    let selected_use: Int = -1;
    let selected_remat: Bool = false;
    i = 0;
    while (i < plan.bindings.length()) {
        let binding: X86RegisterBinding = plan.bindings[i];

        if (x86_allocatable_register(binding.register) && !x86_is_xmm(binding.register) &&
            binding.register != first && binding.register != second) {
            let next_use: Int = x86_pending_use(ref plan.uses, binding.value, position);
            let remat: Bool = machine_rematerializable(ref program, binding.value);

            if (next_use > selected_use || (next_use == selected_use && remat && !selected_remat)) {
                selected = i;
                selected_use = next_use;
                selected_remat = remat;
            }
        }
        i++;
    }

    if (selected < 0) {
        return X86RegisterChoice(register=X86Register.None, evicted=NO_WIR_VALUE);
    }

    return X86RegisterChoice(register=plan.bindings[selected].register, evicted=plan.bindings[selected].value);
}
