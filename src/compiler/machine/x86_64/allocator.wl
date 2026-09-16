// compiler/machine/x86_64/allocator.wl
import * from "model.wl"
import * from "../../wir/model.wl"


const X86_NO_NEXT_USE: Int = 2147483647;

/*
this is a next-use allocator, not graph coloring. Uses are collected in emission
order and every register remembers the SSA value it currently holds. When all
registers are occupied, the value used farthest in the future is the cheapest one
to evict. Dead bindings and spill slots are returned immediately.

the important property here is compile time: use collection is linear and each
queue only moves forward. It will miss some coalescing opportunities that a graph
allocator can find, but it does not build an interference graph or iterate over
one. That trade is intentional for the normal White build path.
*/


struct X86UseQueue(
    positions: Vector(Int),
    cursor: Int
)

struct X86UseTable(
    queues: Vector(X86UseQueue)
)

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


func x86_new_use_table(value_count: Int) -> X86UseTable {
    let queues: Vector(X86UseQueue) = [];

    let i = 0;
    while (i < value_count) {
        queues.append(X86UseQueue(positions=[], cursor=0));
        i++;
    }

    return X86UseTable(queues=queues);
}

func x86_record_use(table: X86UseTable, value: WirValueID, position: Int) -> Void {
    let index: Int = wir_id_index(UInt32(value));
    if (index < 0 || index >= table.queues.length()) {
        return;
    }

    let queue: X86UseQueue = table.queues[index];
    queue.positions.append(position);
    table.queues[index] = queue;
}

func x86_collect_uses(program: WirModule, order: Vector(WirBlockID)) -> X86UseTable {
    let table: X86UseTable = x86_new_use_table(program.arena.values.length());
    let position = 0;
    let block_index = 0;
    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];

        let instruction_index = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];

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
    let index: Int = wir_id_index(UInt32(value));
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

func x86_consume_uses(table: X86UseTable, value: WirValueID, position: Int) -> Void {
    let index: Int = wir_id_index(UInt32(value));
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

func x86_reset_spills(plan: X86SpillPlan) -> Void {
    let i = 0;
    while (i < plan.bindings.length()) {
        let binding: X86SpillBinding = plan.bindings[i];
        binding.value = NO_WIR_VALUE;
        plan.bindings[i] = binding;

        i++;
    }
}

func x86_register_value(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.Load     || opcode == WirOpcode.Add || 
           opcode == WirOpcode.Subtract || opcode == WirOpcode.Multiply;
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

    let i = 0;
    while (i <= instruction_count) {
        before_changes.append(0);
        after_changes.append(0);
        i++;
    }

    let position = 0;
    block_index = 0;
    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];

        let instruction_index = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[
                wir_id_index(UInt32(block.instructions[instruction_index]))
            ];

            if (instruction.result != NO_WIR_VALUE && x86_register_value(instruction.opcode)) {
                let value_index: Int = wir_id_index(UInt32(instruction.result));
                if (value_index >= 0 && value_index < uses.queues.length()) {
                    let queue: X86UseQueue = uses.queues[value_index];
                    if (queue.positions.length() != 0) {
                        let last: Int = queue.positions[queue.positions.length() - 1];
                        if (position+1 <= last) {
                            before_changes[position+1] = before_changes[position+1] + 1;
                            before_changes[last+1] = before_changes[last+1] - 1;
                        }
                        if (position < last) {
                            after_changes[position] = after_changes[position] + 1;
                            after_changes[last] = after_changes[last] - 1;
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
    i = 0;
    while (i < instruction_count) {
        before += before_changes[i];
        after += after_changes[i];
        if (before > peak) { peak = before; }
        if (after > peak) { peak = after; }
        i++;
    }

    if (peak <= register_count) {
        return 0;
    }

    return peak - register_count;
}

func x86_rematerializable(program: WirModule, value: WirValueID) -> Bool {
    let index: Int = wir_id_index(UInt32(value));
    if (index < 0 || index >= program.arena.values.length()) {
        return false;
    }

    let kind: WirValueKind = program.arena.values[index].kind;
    return kind == WirValueKind.Integer || kind == WirValueKind.FloatValue || kind == WirValueKind.BoolValue ||
           kind == WirValueKind.Null    || kind == WirValueKind.Global     || kind == WirValueKind.Function;
}

func x86_choose_register(program: WirModule, plan: X86RegisterPlan, position: Int) -> X86RegisterChoice {
    return x86_choose_register_except(program, plan, position, X86Register.None);
}

func x86_choose_register_except(program: WirModule, plan: X86RegisterPlan, position: Int, avoid: X86Register) -> X86RegisterChoice {
    let i = 0;
    while (i < plan.bindings.length()) {
        if (plan.bindings[i].register != avoid && plan.bindings[i].value == NO_WIR_VALUE) {
            return X86RegisterChoice(register=plan.bindings[i].register, evicted=NO_WIR_VALUE);
        }

        i++;
    }

    let selected = 0;
    let selected_use: Int = -1;
    let selected_remat: Bool = false;
    i = 0;
    while (i < plan.bindings.length()) {
        if (plan.bindings[i].register == avoid) {
            i++;
            continue;
        }

        let value: WirValueID = plan.bindings[i].value;
        let next_use: Int = x86_next_use(plan.uses, value, position);
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
        if (binding.register != first && binding.register != second && binding.value == NO_WIR_VALUE) {
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
        if (binding.register != first && binding.register != second) {
            let next_use: Int = x86_next_use(plan.uses, binding.value, position);
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
