// compiler/machine/x86_64/allocator.wl
import * from "model.wl"
import * from "../../wir/model.wl"


const X86_NO_NEXT_USE: Int = 2147483647;

// next-use allocation keeps this pass cheap. Record every use once, then spill
// the value needed farthest in the future. This loses some opportunities that a
// graph allocator would find, but it does not build or color an interference graph.


struct X86UseQueue(
    positions: Vector(Int),
    cursor: Int
)

struct X86UseTable(
    base: Int,
    dense_count: Int,
    sparse: Vector(WirValueID),
    sparse_indices: Dict(UInt32, Int),
    queues: Vector(X86UseQueue)
)

struct X86ValueRange(base: Int, count: Int)

struct X86RegisterBinding(
    register: X86Register,
    value: WirValueID
)

struct X86RegisterChoice(
    register: X86Register,
    evicted: WirValueID
)

struct X86RegisterPlan(
    uses: X86UseTable,
    bindings: Vector(X86RegisterBinding)
)

struct X86SpillBinding(
    offset: Int,
    value: WirValueID
)

struct X86SpillPlan(
    bindings: Vector(X86SpillBinding)
)

func x86_include_value(value: WirValueID, ref first: Int, ref last: Int) -> Void {
    let index: Int = wir_id_index(UInt32(value));
    if (index < 0) {
        return;
    }
    if (first < 0 || index < first) {
        first = index;
    }
    if (index > last) {
        last = index; 
    }
}

func x86_function_value_range(program: WirModule, order: Vector(WirBlockID)) -> X86ValueRange {
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
    if (seen.lookup(UInt32(value)) != 0) { return; }
    sparse.append(value);
    seen.put(UInt32(value), sparse.length());
}

func x86_function_sparse_values(program: WirModule, order: Vector(WirBlockID), range: X86ValueRange) -> Vector(WirValueID) {
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
        queues.append(X86UseQueue(positions=[], cursor=0));
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

func x86_use_index(table: X86UseTable, value: WirValueID) -> Int {
    let index: Int = wir_id_index(UInt32(value));
    if (index >= table.base && index < table.base + table.dense_count) { return index - table.base; }
    return table.sparse_indices.lookup(UInt32(value)) - 1;
}

func x86_record_use(table: X86UseTable, value: WirValueID, position: Int) -> Void {
    let index: Int = x86_use_index(table, value);
    if (index < 0 || index >= table.queues.length()) { return; }
    let queue: X86UseQueue = table.queues[index];
    queue.positions.append(position);
    table.queues[index] = queue;
}

func x86_collect_uses(program: WirModule, order: Vector(WirBlockID)) -> X86UseTable {
    let range: X86ValueRange = x86_function_value_range(program, order);
    let sparse: Vector(WirValueID) = x86_function_sparse_values(program, order, range);
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
                x86_record_use(table, instruction.operands[operand_index], position);
                operand_index++;
            }

            let edge_index = 0;
            while (edge_index < instruction.edges.length()) {
                let argument_index = 0;
                while (argument_index < instruction.edges[edge_index].arguments.length()) {
                    x86_record_use(table, instruction.edges[edge_index].arguments[argument_index], position);
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

func x86_next_use(table: X86UseTable, value: WirValueID, position: Int) -> Int {
    let index: Int = x86_use_index(table, value);
    if (index < 0 || index >= table.queues.length()) {
        return X86_NO_NEXT_USE;
    }

    // x86_consume_uses moves the cursor as instructions are emitted, so this
    // search never starts again at the beginning of a long-lived value.
    let queue: X86UseQueue = table.queues[index];
    let cursor: Int = queue.cursor;
    while (cursor < queue.positions.length() && queue.positions[cursor] <= position) {
        cursor++;
    }

    if (cursor >= queue.positions.length()) {
        return X86_NO_NEXT_USE;
    }

    return queue.positions[cursor];
}

func x86_pending_use(table: X86UseTable, value: WirValueID, position: Int) -> Int {
    // an operand stays live until the whole instruction has consumed it
    return x86_next_use(table, value, position - 1);
}

func x86_consume_uses(table: X86UseTable, value: WirValueID, position: Int) -> Void {
    let index: Int = x86_use_index(table, value);
    if (index < 0 || index >= table.queues.length()) {
        return;
    }

    let queue: X86UseQueue = table.queues[index];
    while (queue.cursor < queue.positions.length() && queue.positions[queue.cursor] <= position) {
        queue.cursor++;
    }

    table.queues[index] = queue;
}

func x86_consume_instruction(table: X86UseTable, instruction: WirInstruction, position: Int) -> Void {
    let i = 0;
    while (i < instruction.operands.length()) {
        x86_consume_uses(table, instruction.operands[i], position);
        i++;
    }

    i = 0;
    while (i < instruction.edges.length()) {
        let j = 0;
        while (j < instruction.edges[i].arguments.length()) {
            x86_consume_uses(table, instruction.edges[i].arguments[j], position);
            j++;
        }
        i++;
    }
}

func x86_allocatable_registers() -> Vector(X86Register) {
    // argument registers stay untouched until call lowering can preserve them
    return [X86Register.RAX, X86Register.R10, X86Register.R11];
}

func x86_register_plan(uses: X86UseTable) -> X86RegisterPlan {
    let bindings: Vector(X86RegisterBinding) = [];
    let registers: Vector(X86Register) = x86_allocatable_registers();

    let i = 0;
    while (i < registers.length()) {
        bindings.append(X86RegisterBinding(register=registers[i], value=NO_WIR_VALUE));
        i++;
    }
    // XMM0..3 remain reserved for incoming and outgoing arguments
    bindings.append(X86RegisterBinding(register=X86Register.XMM4, value=NO_WIR_VALUE));
    bindings.append(X86RegisterBinding(register=X86Register.XMM5, value=NO_WIR_VALUE));
    return X86RegisterPlan(uses=uses, bindings=bindings);
}

func x86_new_register_plan(program: WirModule, order: Vector(WirBlockID)) -> X86RegisterPlan {
    return x86_register_plan(x86_collect_uses(program, order));
}

func x86_register_for(plan: X86RegisterPlan, value: WirValueID) -> X86Register {
    let i = 0;
    while (i < plan.bindings.length()) {
        if (plan.bindings[i].value == value) {
            return plan.bindings[i].register;
        }

        i++;
    }

    return X86Register.None;
}

func x86_bind_register(plan: X86RegisterPlan, register: X86Register, value: WirValueID) -> Void {
    let i = 0;
    while (i < plan.bindings.length()) {
        let binding: X86RegisterBinding = plan.bindings[i];
        if (binding.value == value) {
            binding.value = NO_WIR_VALUE;
            plan.bindings[i] = binding;
        }
        i++;
    }

    i = 0;
    while (i < plan.bindings.length()) {
        let binding: X86RegisterBinding = plan.bindings[i];
        if (binding.register == register) {
            binding.value = value;
            plan.bindings[i] = binding;
            return;
        }
        i++;
    }
}

func x86_clear_register(plan: X86RegisterPlan, register: X86Register) -> Void {
    x86_bind_register(plan, register, NO_WIR_VALUE);
}

func x86_forget_register_value(plan: X86RegisterPlan, value: WirValueID) -> Void {
    let i: Int = 0;
    while (i < plan.bindings.length()) {
        let binding: X86RegisterBinding = plan.bindings[i];
        if (binding.value == value) {
            binding.value = NO_WIR_VALUE;
            plan.bindings[i] = binding;
        }
        i++;
    }
}

func x86_reset_registers(plan: X86RegisterPlan) -> Void {
    let i = 0;
    while (i < plan.bindings.length()) {
        let binding: X86RegisterBinding = plan.bindings[i];
        binding.value = NO_WIR_VALUE;
        plan.bindings[i] = binding;
        i++;
    }
}

func x86_release_dead_registers(plan: X86RegisterPlan, position: Int) -> Void {
    let i = 0;
    while (i < plan.bindings.length()) {
        let binding: X86RegisterBinding = plan.bindings[i];
        if (binding.value != NO_WIR_VALUE &&
            x86_next_use(plan.uses, binding.value, position) == X86_NO_NEXT_USE) {

            binding.value = NO_WIR_VALUE;
            plan.bindings[i] = binding;
        }

        i++;
    }
}

func x86_new_spill_plan(offsets: Vector(Int)) -> X86SpillPlan {
    let bindings: Vector(X86SpillBinding) = [];

    let i = 0;
    while (i < offsets.length()) {
        bindings.append(X86SpillBinding(offset=offsets[i], value=NO_WIR_VALUE));
        i++;
    }

    return X86SpillPlan(bindings=bindings);
}

func x86_spill_offset(plan: X86SpillPlan, value: WirValueID) -> Int {
    let i = 0;
    while (i < plan.bindings.length()) {
        if (plan.bindings[i].value == value) {
            return plan.bindings[i].offset;
        }

        i++;
    }

    return 0;
}

func x86_claim_spill(plan: X86SpillPlan, value: WirValueID) -> Int {
    let existing: Int = x86_spill_offset(plan, value);
    if (existing != 0) {
        return existing;
    }

    let i = 0;
    while (i < plan.bindings.length()) {
        if (plan.bindings[i].value == NO_WIR_VALUE) {
            let binding: X86SpillBinding = plan.bindings[i];
            binding.value = value;

            plan.bindings[i] = binding;
            return binding.offset;
        }

        i++;
    }
    return 0;
}

func x86_release_dead_spills(plan: X86SpillPlan, uses: X86UseTable, position: Int) -> Void {
    let i = 0;
    while (i < plan.bindings.length()) {
        let binding: X86SpillBinding = plan.bindings[i];
        if (binding.value != NO_WIR_VALUE && x86_next_use(uses, binding.value, position) == X86_NO_NEXT_USE) {
            binding.value = NO_WIR_VALUE;
            plan.bindings[i] = binding;
        }

        i++;
    }
}

func x86_forget_spill_value(plan: X86SpillPlan, value: WirValueID) -> Void {
    let i: Int = 0;
    while (i < plan.bindings.length()) {
        let binding: X86SpillBinding = plan.bindings[i];
        if (binding.value == value) {
            binding.value = NO_WIR_VALUE;
            plan.bindings[i] = binding;
        }
        i++;
    }
}

func x86_reset_spills(plan: X86SpillPlan) -> Void {
    let i = 0;
    while (i < plan.bindings.length()) {
        let binding: X86SpillBinding = plan.bindings[i];
        binding.value = NO_WIR_VALUE;
        plan.bindings[i] = binding;

        i++;
    }
}


func x86_mark_live_interval(ref before_changes: Vector(Int), ref after_changes: Vector(Int), start: Int, last: Int) -> Void {
    if (start >= last) {
        return;
    }

    if (start + 1 <= last) {
        before_changes[start + 1] = before_changes[start + 1] + 1;
        before_changes[last + 1] = before_changes[last + 1] - 1;
    }

    after_changes[start] = after_changes[start] + 1;
    after_changes[last] = after_changes[last] - 1;
}

func x86_spill_capacity(program: WirModule, order: Vector(WirBlockID), uses: X86UseTable, register_count: Int) -> Int {
    // turn every value lifetime into +1/-1 events. The largest prefix sum is the
    // number of simultaneous spill homes, so frame space does not grow with the
    // total number of values in a function.
    let instruction_count = 0;
    let block_index = 0;
    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];
        instruction_count += block.instructions.length();
        block_index++;
    }

    if (instruction_count == 0) {
        return 0;
    }

    let before_changes: Vector(Int) = [];
    let after_changes: Vector(Int) = [];
    let call_changes: Vector(Int) = [];
    let i = 0;
    while (i <= instruction_count) {
        before_changes.append(0);
        after_changes.append(0);
        call_changes.append(0);
        i++;
    }

    let function_id: WirFuncID = program.arena.blocks[wir_id_index(UInt32(order[0]))].function;
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    i = 0;
    while (i < function.parameters.length()) {
        let value_index: Int = x86_use_index(uses, function.parameters[i]);
        if (value_index >= 0 && value_index < uses.queues.length() && !x86_rematerializable(program, function.parameters[i])) {
            let queue: X86UseQueue = uses.queues[value_index];
            if (queue.positions.length() != 0) {
                let last: Int = queue.positions[queue.positions.length() - 1];
                x86_mark_live_interval(ref before_changes, ref after_changes, 0, last);
                call_changes[0] = call_changes[0] + 1;
                call_changes[last + 1] = call_changes[last + 1] - 1;
            }
        }

        i++;
    }

    let position = 0;
    block_index = 0;
    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];
        let block_start: Int = position;
        i = 0;
        while (i < block.parameters.length()) {
            let value_index: Int = x86_use_index(uses, block.parameters[i]);
            if (value_index >= 0 && value_index < uses.queues.length() && !x86_rematerializable(program, block.parameters[i])) {
                let queue: X86UseQueue = uses.queues[value_index];
                if (queue.positions.length() != 0) {
                    let last: Int = queue.positions[queue.positions.length() - 1];
                    x86_mark_live_interval(ref before_changes, ref after_changes, block_start, last);
                    call_changes[block_start] = call_changes[block_start] + 1;
                    call_changes[last + 1] = call_changes[last + 1] - 1;
                }
            }

            i++;
        }
        let instruction_index = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[
                wir_id_index(UInt32(block.instructions[instruction_index]))
            ];

            // count SSA results, not an opcode whitelist that can miss new conversions
            if (instruction.result != NO_WIR_VALUE && !x86_rematerializable(program, instruction.result)) {
                let value_index: Int = x86_use_index(uses, instruction.result);
                if (value_index >= 0 && value_index < uses.queues.length()) {
                    let queue: X86UseQueue = uses.queues[value_index];
                    if (queue.positions.length() != 0) {
                        let last: Int = queue.positions[queue.positions.length() - 1];
                        x86_mark_live_interval(ref before_changes, ref after_changes, position, last);
                        if (position < last) {
                            call_changes[position + 1] = call_changes[position + 1] + 1;
                            call_changes[last + 1] = call_changes[last + 1] - 1;
                        }
                    }
                }
            }
            position++;
            instruction_index++;
        }
        block_index++;
    }

    let before = 0;
    let after = 0;
    let peak = 0;
    let live_before_call = 0;
    let call_peak = 0;
    let scan_position = 0;
    block_index = 0;
    i = 0;
    while (i < instruction_count) {
        before += before_changes[i];
        after += after_changes[i];
        live_before_call += call_changes[i];
        if (before > peak) { peak = before; }
        if (after > peak) { peak = after; }
        while (block_index < order.length()) {
            let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];
            if (i < scan_position + block.instructions.length()) {
                let instruction: WirInstruction = program.arena.instructions[
                    wir_id_index(UInt32(block.instructions[i - scan_position]))
                ];
                let saves_register_bank: Bool = instruction.opcode == WirOpcode.Call || instruction.opcode == WirOpcode.Retain ||
                                                instruction.opcode == WirOpcode.Release ||
                                                (instruction.opcode == WirOpcode.AtomicRmw &&
                                                (instruction.atomic_op == WirAtomicOp.BitAnd || instruction.atomic_op == WirAtomicOp.BitOr ||
                                                instruction.atomic_op == WirAtomicOp.BitXor));
                if (saves_register_bank && live_before_call > call_peak) {
                    call_peak = live_before_call;
                }

                // memory operations and edge staging need a temporary before their inputs die
                let temporary = instruction.opcode == WirOpcode.Store || instruction.opcode == WirOpcode.Load ||
                                instruction.opcode == WirOpcode.StructValue || instruction.opcode == WirOpcode.ArrayValue ||
                                instruction.opcode == WirOpcode.Field || instruction.opcode == WirOpcode.Index;
                let edge_index = 0;
                while (!temporary && edge_index < instruction.edges.length()) {
                    temporary = instruction.edges[edge_index].arguments.length() != 0;
                    edge_index++;
                }

                if (temporary && before + 1 > peak) {
                    peak = before + 1;
                }
                if (instruction.opcode == WirOpcode.IndexAddress || instruction.opcode == WirOpcode.FieldAddress) {
                    // LEA keeps its inputs alive while claiming a separate destination
                    let extra = 1;
                    let inputs = 1;
                    if (instruction.opcode == WirOpcode.IndexAddress) {
                        inputs = instruction.operands.length();
                    }

                    let operand_index = 0;
                    while (operand_index < inputs) {
                        if (x86_rematerializable(program, instruction.operands[operand_index])) { extra++; }
                        operand_index++;
                    }
                    if (before + extra > peak) {
                        peak = before + extra;
                    }
                }

                break;
            }
            scan_position += block.instructions.length();
            block_index++;
        }
        i++;
    }
    let required = 0;
    if (peak > register_count) {
        required = peak - register_count;
    }

    if (call_peak > required) {
        required = call_peak;
    }

    return required;
}

func x86_rematerializable(program: WirModule, value: WirValueID) -> Bool {
    let index: Int = wir_id_index(UInt32(value));
    if (index < 0 || index >= program.arena.values.length()) {
        return false;
    }

    let kind: WirValueKind = program.arena.values[index].kind;
    if (kind == WirValueKind.Constant) {
        let owner: Int = wir_id_index(program.arena.values[index].owner);
        if (owner < 0 || owner >= program.arena.constants.length()) { return false; }
        let constant: WirConstant = program.arena.constants[owner];
        return constant.kind == WirConstKind.Zero || constant.kind == WirConstKind.Address;
    }
    if (kind == WirValueKind.Instruction) {
        let owner: Int = wir_id_index(program.arena.values[index].owner);
        return owner >= 0 && owner < program.arena.instructions.length() && program.arena.instructions[owner].opcode == WirOpcode.StackAlloc;
    }
    return kind == WirValueKind.Integer || kind == WirValueKind.FloatValue || kind == WirValueKind.BoolValue ||
           kind == WirValueKind.Null    || kind == WirValueKind.Global     || kind == WirValueKind.Function;
}

func x86_choose_register(program: WirModule, plan: X86RegisterPlan, position: Int) -> X86RegisterChoice {
    return x86_choose_register_except(program, plan, position, X86Register.None);
}

func x86_choose_register_except(program: WirModule, plan: X86RegisterPlan, position: Int, avoid: X86Register) -> X86RegisterChoice {
    return x86_choose_register_class(program, plan, position, avoid, false);
}

func x86_choose_register_class(program: WirModule, plan: X86RegisterPlan, position: Int, avoid: X86Register, floating: Bool) -> X86RegisterChoice {
    let i = 0;
    while (i < plan.bindings.length()) {
        if (plan.bindings[i].register != avoid && x86_is_xmm(plan.bindings[i].register) == floating && plan.bindings[i].value == NO_WIR_VALUE) {
            return X86RegisterChoice(register=plan.bindings[i].register, evicted=NO_WIR_VALUE);
        }

        i++;
    }

    let selected = 0;
    let selected_use: Int = -1;
    let selected_remat: Bool = false;
    i = 0;
    while (i < plan.bindings.length()) {
        if (plan.bindings[i].register == avoid || x86_is_xmm(plan.bindings[i].register) != floating) {
            i++;
            continue;
        }

        let value: WirValueID = plan.bindings[i].value;
        let next_use: Int = x86_pending_use(plan.uses, value, position);
        let remat: Bool = x86_rematerializable(program, value);
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

func x86_choose_register_avoiding(program: WirModule, plan: X86RegisterPlan, position: Int, first: X86Register, second: X86Register) -> X86RegisterChoice {
    let i = 0;
    while (i < plan.bindings.length()) {
        let binding: X86RegisterBinding = plan.bindings[i];
        if (!x86_is_xmm(binding.register) && binding.register != first && binding.register != second && binding.value == NO_WIR_VALUE) {
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
        if (!x86_is_xmm(binding.register) && binding.register != first && binding.register != second) {
            let next_use: Int = x86_pending_use(plan.uses, binding.value, position);
            let remat: Bool = x86_rematerializable(program, binding.value);
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
