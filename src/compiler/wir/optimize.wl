// compiler/wir/optimize.wl

import * from "model.wl"

struct WirOptimizationStats(instructions: Int, blocks: Int, branches: Int, jumps: Int, constants: Int, copies: Int, checks: Int, loads: Int, stores: Int, slots: Int, parameters: Int)

struct WirOptimizationPlan(forwarding_distance: Int, extra_scans: Int, code_growth_percent: Int, inline_size: Int)

func wir_optimization_plan(level: String) -> WirOptimizationPlan {
    if (level == "-O1") { return WirOptimizationPlan(forwarding_distance=2, extra_scans=1, code_growth_percent=0, inline_size=0); }
    if (level == "-O3") { return WirOptimizationPlan(forwarding_distance=-1, extra_scans=8, code_growth_percent=30, inline_size=64); }
    if (level == "-Os") { return WirOptimizationPlan(forwarding_distance=8, extra_scans=3, code_growth_percent=0, inline_size=12); }
    if (level == "-Oz") { return WirOptimizationPlan(forwarding_distance=-1, extra_scans=3, code_growth_percent=0, inline_size=6); }
    return WirOptimizationPlan(forwarding_distance=8, extra_scans=3, code_growth_percent=10, inline_size=24);
}

// keep the default optimizer bounded. Self-hosting spends most of its time in
// the frontend, adding a fixed point loop here made small improvements rather
// expensive. The order still matters, forwarding exposes constants and aliases,
// then reachability and the backwards live walk clean up the result.

func wir_scalar_slot(ref program: WirModule, ref instruction: WirInstruction) -> Bool {
    if (instruction.opcode != WirOpcode.StackAlloc || instruction.result == NO_WIR_VALUE) {
        return false;
    }
    let pointer = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
    if (pointer.kind != WirTypeKind.Pointer) {
        return false;
    }
    let element = program.arena.types[wir_id_index(UInt32(pointer.element))];
    return element.kind == WirTypeKind.BoolType || element.kind == WirTypeKind.SignedInt ||
           element.kind == WirTypeKind.UnsignedInt || element.kind == WirTypeKind.FloatType ||
           element.kind == WirTypeKind.Pointer || element.kind == WirTypeKind.Function;
}

func wir_resolve_alias(value: WirValueID, ref aliases: Vector(WirValueID)) -> WirValueID {
    let result = value;
    while (aliases[wir_id_index(UInt32(result))] != result) {
        result = aliases[wir_id_index(UInt32(result))];
    }
    // compress the chain so repeated users do not walk it again
    let current = value;
    while (current != result) {
        let next = aliases[wir_id_index(UInt32(current))];
        aliases[wir_id_index(UInt32(current))] = result;
        current = next;
    }
    return result;
}

func wir_rewrite_aliases(ref values: Vector(WirValueID), ref aliases: Vector(WirValueID)) -> Vector(WirValueID) {
    let i = 0;
    while (i < values.length() && aliases[wir_id_index(UInt32(values[i]))] == values[i]) {
        i++;
    }
    if (i == values.length()) {
        return values;
    }
    let result: Vector(WirValueID) = [];
    i = 0;
    while (i < values.length()) {
        result.append(wir_resolve_alias(values[i], ref aliases));
        i++;
    }
    return result;
}

func wir_stable_block_argument(ref program: WirModule, value: WirValueID) -> Bool {
    let kind = program.arena.values[wir_id_index(UInt32(value))].kind;
    return kind == WirValueKind.Integer || kind == WirValueKind.FloatValue || kind == WirValueKind.BoolValue ||
           kind == WirValueKind.Null || kind == WirValueKind.FunctionParameter || kind == WirValueKind.Constant ||
           kind == WirValueKind.Global || kind == WirValueKind.Function;
}

func wir_prepare_block_parameters(ref program: WirModule, ref offsets: Vector(Int), ref candidates: Vector(WirValueID), ref states: Vector(Int)) -> Void {
    let i = 0;
    while (i < program.arena.blocks.length()) {
        offsets.append(candidates.length());
        let j = 0;
        while (j < program.arena.blocks[i].parameters.length()) {
            candidates.append(NO_WIR_VALUE);
            states.append(0);
            j++;
        }
        i++;
    }
}

func wir_observe_block_arguments(ref program: WirModule, ref edge: WirEdge, ref offsets: Vector(Int), ref candidates: Vector(WirValueID), ref states: Vector(Int), ref aliases: Vector(WirValueID)) -> Void {
    let ptr target: WirBlock = ref program.arena.blocks[wir_id_index(UInt32(edge.target))];
    let offset = offsets[wir_id_index(UInt32(edge.target))];
    let i = 0;
    while (i < edge.arguments.length()) {
        let parameter: WirValueID = target.parameters[i];
        let value = wir_resolve_alias(edge.arguments[i], ref aliases);
        let state_index: Int = offset + i;
        if (value == parameter || !wir_stable_block_argument(ref program, value)) {
            states[state_index] = 2;
        } else if (states[state_index] == 0) {
            candidates[state_index] = value;
            states[state_index] = 1;
        } else if (candidates[state_index] != value) {
            states[state_index] = 2;
        }
        i++;
    }
}

func wir_apply_block_parameter_aliases(ref program: WirModule, ref reachable: Vector(Bool), ref offsets: Vector(Int), ref candidates: Vector(WirValueID), ref states: Vector(Int), ref aliases: Vector(WirValueID), ref stats: WirOptimizationStats) -> Void {
    let i = 0;
    while (i < program.arena.blocks.length()) {
        if (!reachable[i]) {
            i++;
            continue;
        }
        let ptr block: WirBlock = ref program.arena.blocks[i];
        let j = 0;
        while (j < block.parameters.length()) {
            let parameter: WirValueID = block.parameters[j];
            let state_index = offsets[i] + j;
            if (states[state_index] == 1) {
                aliases[wir_id_index(UInt32(parameter))] = candidates[state_index];
                stats.parameters++;
            }
            j++;
        }
        i++;
    }
}

func wir_forward_stack_slots(ref program: WirModule, ref removed: Vector(Bool), ref stats: WirOptimizationStats, max_distance: Int) -> Vector(WirValueID) {
    let slots: Vector(WirValueID) = [];
    let slot_of_value: Vector(Int) = [];
    let safe: Vector(Bool) = [];
    let first_block: Vector(WirBlockID) = [];
    let multiple_blocks: Vector(Bool) = [];
    let unresolved_load: Vector(Bool) = [];
    let aliases: Vector(WirValueID) = [];
    let stores: Vector(WirInstID) = [];
    let store_slots: Vector(Int) = [];
    let i = 0;
    while (i < program.arena.values.length()) {
        slot_of_value.append(-1);
        aliases.append(WirValueID(UInt32(i + 1)));
        i++;
    }
    i = 0;
    while (i < program.arena.instructions.length()) {
        let ptr instruction: WirInstruction = ref program.arena.instructions[i];
        if (wir_scalar_slot(ref program, ref program.arena.instructions[i])) {
            let slot: Int = slots.length();
            slots.append(instruction.result);
            slot_of_value[wir_id_index(UInt32(instruction.result))] = slot;
            safe.append(true);
            first_block.append(NO_WIR_BLOCK);
            multiple_blocks.append(false);
            unresolved_load.append(false);
        }
        i++;
    }
    if (slots.length() == 0) { return aliases; }

    // do not forward a slot after its address escapes. Calls and block arguments
    // can keep the pointer and change memory where this pass cannot see it.
    i = 0;
    while (i < program.arena.blocks.length()) {
        let block_id = WirBlockID(UInt32(i + 1));
        let block = program.arena.blocks[i];
        let j = 0;
        while (j < block.instructions.length()) {
            let ptr instruction: WirInstruction = ref program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
            let k = 0;
            while (k < instruction.operands.length()) {
                let value_index: Int = wir_id_index(UInt32(instruction.operands[k]));
                let slot: Int = slot_of_value[value_index];
                if (slot >= 0) {
                    let memory_use = (instruction.opcode == WirOpcode.Load && k == 0) ||
                                     (instruction.opcode == WirOpcode.Store && k == 1);
                    if (!memory_use) {
                        safe[slot] = false;
                    }
                    if (first_block[slot] == NO_WIR_BLOCK) {
                        first_block[slot] = block_id;
                    } else if (first_block[slot] != block_id) {
                        multiple_blocks[slot] = true;
                    }
                }
                k++;
            }
            k = 0;
            while (k < instruction.edges.length()) {
                let edge: WirEdge = instruction.edges[k];
                let n = 0;
                while (n < edge.arguments.length()) {
                    let slot: Int = slot_of_value[wir_id_index(UInt32(edge.arguments[n]))];
                    if (slot >= 0) { safe[slot] = false; }
                    n++;
                }
                k++;
            }
            j++;
        }
        i++;
    }

    let current: Vector(WirValueID) = [];
    let generation: Vector(Int) = [];
    let stored_at: Vector(Int) = [];
    i = 0;
    while (i < slots.length()) {
        current.append(NO_WIR_VALUE);
        generation.append(0);
        stored_at.append(-1);
        i++;
    }
    i = 0;
    while (i < program.arena.blocks.length()) {
        let block_generation: Int = i + 1;
        let block = program.arena.blocks[i];
        let j = 0;
        while (j < block.instructions.length()) {
            let id: WirInstID = block.instructions[j];
            let index: Int = wir_id_index(UInt32(id));
            let ptr instruction: WirInstruction = ref program.arena.instructions[index];
            let active_slot = -1;
            if (instruction.opcode == WirOpcode.Store && instruction.operands.length() == 2) {
                active_slot = slot_of_value[wir_id_index(UInt32(instruction.operands[1]))];
                if (active_slot >= 0 && safe[active_slot]) {
                    current[active_slot] = wir_resolve_alias(instruction.operands[0], ref aliases);
                    generation[active_slot] = block_generation;
                    stored_at[active_slot] = j;
                    stores.append(id);
                    store_slots.append(active_slot);
                }
            } else if (instruction.opcode == WirOpcode.Load && instruction.operands.length() == 1) {
                active_slot = slot_of_value[wir_id_index(UInt32(instruction.operands[0]))];
                if (active_slot >= 0 && safe[active_slot]) {
                    if (generation[active_slot] == block_generation &&
                        (max_distance < 0 || j - stored_at[active_slot] <= max_distance)) {
                        aliases[wir_id_index(UInt32(instruction.result))] = current[active_slot];
                        removed[index] = true;
                        stats.loads++;
                    } else {
                        unresolved_load[active_slot] = true;
                    }
                }
            }
            j++;
        }
        i++;
    }

    // only delete the alloca and stores when every load was replaced. A slot used
    // in another block stays in memory, this pass does not build memory SSA.
    i = 0;
    while (i < slots.length()) {
        if (safe[i] && !multiple_blocks[i] && !unresolved_load[i]) {
            let value = program.arena.values[wir_id_index(UInt32(slots[i]))];
            removed[wir_id_index(value.owner)] = true;
            stats.slots++;
        }
        i++;
    }
    i = 0;
    while (i < stores.length()) {
        let slot: Int = store_slots[i];
        if (safe[slot] && !multiple_blocks[slot] && !unresolved_load[slot]) {
            removed[wir_id_index(UInt32(stores[i]))] = true;
            stats.stores++;
        }
        i++;
    }
    return aliases;
}

func wir_integer_mask(ref program: WirModule, type_id: WirTypeID) -> UInt128 {
    let type = program.arena.types[wir_id_index(UInt32(type_id))];
    let bits = type.bits;
    if (type.kind == WirTypeKind.BoolType) { bits = 1; }
    if (bits <= 0 || bits >= 128) { return ~UInt128(0U); }
    return (UInt128(1U) << UInt128(bits)) - UInt128(1U);
}

func wir_integer_is(ref program: WirModule, value: WirValueID, expected: UInt128) -> Bool {
    let constant = program.arena.values[wir_id_index(UInt32(value))];
    if (constant.kind != WirValueKind.Integer && constant.kind != WirValueKind.BoolValue) {
        return false;
    }
    let mask = wir_integer_mask(ref program, constant.type_id);
    return (constant.integer & mask) == (expected & mask);
}

func wir_copy_source(ref program: WirModule, ref instruction: WirInstruction, ref aliases: Vector(WirValueID)) -> WirValueID {
    if (instruction.result == NO_WIR_VALUE || instruction.operands.length() == 0) {
        return NO_WIR_VALUE;
    }

    let left = wir_resolve_alias(instruction.operands[0], ref aliases);
    let left_type = program.arena.values[wir_id_index(UInt32(left))].type_id;
    if (left_type != instruction.type_id) { return NO_WIR_VALUE; }

    if (instruction.operands.length() != 2) { return NO_WIR_VALUE; }

    let right = wir_resolve_alias(instruction.operands[1], ref aliases);
    let right_type = program.arena.values[wir_id_index(UInt32(right))].type_id;
    if (right_type != instruction.type_id) { return NO_WIR_VALUE; }

    let op = instruction.opcode;
    if ((op == WirOpcode.Add || op == WirOpcode.BitOr || op == WirOpcode.BitXor) && wir_integer_is(ref program, right, UInt128(0U))) {
        return left;
    }
    if ((op == WirOpcode.Add || op == WirOpcode.BitOr || op == WirOpcode.BitXor) && wir_integer_is(ref program, left, UInt128(0U))) {
        return right;
    }
    if (op == WirOpcode.Subtract && wir_integer_is(ref program, right, UInt128(0U))) {
        return left;
    }
    if (op == WirOpcode.Multiply && wir_integer_is(ref program, right, UInt128(1U))) {
        return left;
    }
    if (op == WirOpcode.Multiply && wir_integer_is(ref program, left, UInt128(1U))) {
        return right;
    }
    if ((op == WirOpcode.ShiftLeft || op == WirOpcode.SignedShiftRight || op == WirOpcode.UnsignedShiftRight) &&
        wir_integer_is(ref program, right, UInt128(0U))) {
        return left;
    }
    if (op == WirOpcode.BitAnd && wir_integer_is(ref program, right, wir_integer_mask(ref program, instruction.type_id))) {
        return left;
    }
    if (op == WirOpcode.BitAnd && wir_integer_is(ref program, left, wir_integer_mask(ref program, instruction.type_id))) {
        return right;
    }
    return NO_WIR_VALUE;
}

func wir_propagate_copies(ref program: WirModule, ref removed: Vector(Bool), ref aliases: Vector(WirValueID), ref stats: WirOptimizationStats) -> Void {
    // WIR has no copy opcode. Simple integer identities still leave copy-shaped
    // instructions behind, so record those in the same alias
    // table used by stack forwarding and remove them during the final compaction.
    let i = 0;
    while (i < program.arena.instructions.length()) {
        if (!removed[i]) {
            let ptr instruction: WirInstruction = ref program.arena.instructions[i];
            let source = wir_copy_source(ref program, ref program.arena.instructions[i], ref aliases);
            if (source != NO_WIR_VALUE) {
                aliases[wir_id_index(UInt32(instruction.result))] = source;
                removed[i] = true;
                stats.copies++;
            }
        }
        i++;
    }
}

func wir_refold_aliases(ref program: WirModule, ref removed: Vector(Bool), ref aliases: Vector(WirValueID), ref stats: WirOptimizationStats) -> Void {
    // stack forwarding often exposes a constant after the first fold scan. One
    // ordered pass catches that case without turning the optimizer into a fixed
    // point loop.
    let i = 0;
    while (i < program.arena.instructions.length()) {
        if (!removed[i]) {
            let ptr instruction: WirInstruction = ref program.arena.instructions[i];
            instruction.operands = wir_rewrite_aliases(ref instruction.operands, ref aliases);
            if (wir_fold_scalar(ref program, ref program.arena.instructions[i])) {
                removed[i] = true;
                stats.constants++;
            }
        }
        i++;
    }
}

func wir_check_pair(left: WirValueID, right: WirValueID) -> UInt64 {
    return (UInt64(UInt32(left)) << 32UL) | UInt64(UInt32(right));
}

func wir_known_nonnull(ref program: WirModule, value_id: WirValueID) -> Bool {
    let value = program.arena.values[wir_id_index(UInt32(value_id))];
    if (value.kind == WirValueKind.Global || value.kind == WirValueKind.Function) { return true; }
    if (value.kind == WirValueKind.Instruction) {
        let owner = wir_id_index(value.owner);
        return owner >= 0 && owner < program.arena.instructions.length() &&
               program.arena.instructions[owner].opcode == WirOpcode.StackAlloc;
    }
    if (value.kind != WirValueKind.Constant) { return false; }
    let owner = wir_id_index(value.owner);
    return owner >= 0 && owner < program.arena.constants.length() &&
           program.arena.constants[owner].kind == WirConstKind.Address;
}

func wir_known_bounds_pass(ref program: WirModule, index_id: WirValueID, length_id: WirValueID) -> Bool {
    let index_value = program.arena.values[wir_id_index(UInt32(index_id))];
    let length_value = program.arena.values[wir_id_index(UInt32(length_id))];
    if (index_value.kind != WirValueKind.Integer || length_value.kind != WirValueKind.Integer ||
        index_value.type_id != length_value.type_id) {
        return false;
    }
    let type = program.arena.types[wir_id_index(UInt32(index_value.type_id))];
    if (type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt) { return false; }
    let mask = wir_integer_mask(ref program, index_value.type_id);
    let index = index_value.integer & mask;
    let length = length_value.integer & mask;
    if (type.kind == WirTypeKind.UnsignedInt) { return index < length; }
    let sign = UInt128(1U) << UInt128(type.bits - 1);
    if ((index & sign) != UInt128(0U)) { return false; }
    return (index ^ sign) < (length ^ sign);
}

func wir_eliminate_repeated_checks(ref program: WirModule, ref removed: Vector(Bool), ref aliases: Vector(WirValueID), ref stats: WirOptimizationStats) -> Void {
    let null_generation: Vector(Int) = [];
    let bounds_generation: Dict(UInt64, Int) = Dict();
    let i = 0;
    while (i < program.arena.values.length()) {
        null_generation.append(0);
        i++;
    }

    i = 0;
    while (i < program.arena.blocks.length()) {
        let generation = i + 1;
        let block = program.arena.blocks[i];
        let j = 0;
        while (j < block.instructions.length()) {
            let id = block.instructions[j];
            let index = wir_id_index(UInt32(id));
            if (!removed[index]) {
                let ptr instruction: WirInstruction = ref program.arena.instructions[index];
                if (instruction.opcode == WirOpcode.NullCheck && instruction.operands.length() == 1) {
                    let value = wir_resolve_alias(instruction.operands[0], ref aliases);
                    let value_index = wir_id_index(UInt32(value));
                    if (wir_known_nonnull(ref program, value) || null_generation[value_index] == generation) {
                        removed[index] = true;
                        stats.checks++;
                    } else {
                        null_generation[value_index] = generation;
                    }
                } else if (instruction.opcode == WirOpcode.BoundsCheck && instruction.operands.length() == 2) {
                    let checked = wir_resolve_alias(instruction.operands[0], ref aliases);
                    let length = wir_resolve_alias(instruction.operands[1], ref aliases);
                    let key = wir_check_pair(checked, length);
                    if (wir_known_bounds_pass(ref program, checked, length) || bounds_generation.lookup(key) == generation) {
                        removed[index] = true;
                        stats.checks++;
                    } else {
                        bounds_generation.put(key, generation);
                    }
                }
            }
            j++;
        }
        i++;
    }
}

func wir_trivial_jump(ref program: WirModule, block_id: WirBlockID) -> WirInstID {
    let block = program.arena.blocks[wir_id_index(UInt32(block_id))];
    let function = program.arena.functions[wir_id_index(UInt32(block.function))];
    if (function.entry == block_id || block.parameters.length() != 0 || block.instructions.length() != 1) {
        return NO_WIR_INST;
    }
    let id = block.instructions[0];
    let instruction = program.arena.instructions[wir_id_index(UInt32(id))];
    if (instruction.opcode != WirOpcode.Jump || instruction.operands.length() != 0 || instruction.edges.length() != 1) {
        return NO_WIR_INST;
    }
    return id;
}

func wir_thread_trivial_jumps(ref program: WirModule, ref stats: WirOptimizationStats) -> Void {
    let i = 0;
    while (i < program.arena.instructions.length()) {
        let instruction = program.arena.instructions[i];
        let edge_index = 0;
        while (edge_index < instruction.edges.length()) {
            let edge = instruction.edges[edge_index];
            let original = edge.target;
            let target = original;
            let arguments = edge.arguments;
            let steps = 0;
            while (steps < program.arena.blocks.length()) {
                let jump_id = wir_trivial_jump(ref program, target);
                if (jump_id == NO_WIR_INST) { break; }
                let jump = program.arena.instructions[wir_id_index(UInt32(jump_id))];
                let next = jump.edges[0].target;
                if (next == target) { break; }
                target = next;
                arguments = jump.edges[0].arguments;
                steps++;
            }
            if (target != original) {
                edge.target = target;
                edge.arguments = arguments;
                instruction.edges[edge_index] = edge;
                stats.jumps++;
            }
            edge_index++;
        }
        program.arena.instructions[i] = instruction;
        i++;
    }
}

func wir_fold_scalar(ref program: WirModule, ref instruction: WirInstruction) -> Bool {
    if (instruction.result == NO_WIR_VALUE || instruction.operands.length() == 0 || instruction.operands.length() > 2) { return false; }
    let op = instruction.opcode;
    if (op != WirOpcode.BitAnd && op != WirOpcode.BitOr && op != WirOpcode.BitXor && op != WirOpcode.Not &&
        op != WirOpcode.Add && op != WirOpcode.Subtract && op != WirOpcode.Multiply &&
        op != WirOpcode.Equal && op != WirOpcode.NotEqual &&
        op != WirOpcode.SignedLess && op != WirOpcode.SignedLessEqual && op != WirOpcode.SignedGreater && op != WirOpcode.SignedGreaterEqual &&
        op != WirOpcode.UnsignedLess && op != WirOpcode.UnsignedLessEqual && op != WirOpcode.UnsignedGreater && op != WirOpcode.UnsignedGreaterEqual) { return false; }
    let left = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
    if (left.kind != WirValueKind.Integer && left.kind != WirValueKind.BoolValue) { return false; }
    let type = program.arena.types[wir_id_index(UInt32(left.type_id))];
    let width = type.bits;
    if (type.kind == WirTypeKind.BoolType) { width = 1; }
    if (width <= 0 || width > 128) { return false; }
    let mask: UInt128 = ~UInt128(0U);
    if (width < 128) { mask = (UInt128(1U) << UInt128(width)) - UInt128(1U); }
    let lhs: UInt128 = left.integer & mask;
    let rhs: UInt128 = UInt128(0U);
    if (instruction.operands.length() == 2) {
        let right = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))];
        if (right.kind != left.kind || right.type_id != left.type_id) { return false; }
        rhs = right.integer & mask;
    }

    let result: UInt128 = UInt128(0U);
    if (op == WirOpcode.BitAnd) { result = lhs & rhs; }
    else if (op == WirOpcode.BitOr) { result = lhs | rhs; }
    else if (op == WirOpcode.BitXor) { result = lhs ^ rhs; }
    else if (op == WirOpcode.Not) { result = ~lhs & mask; }
    else if (op == WirOpcode.Add || op == WirOpcode.Subtract || op == WirOpcode.Multiply) {
        // evaluate narrow arithmetic in 128 bits, then apply the WIR bit width
        if (width > 64) { return false; }
        if (op == WirOpcode.Add) { result = (lhs + rhs) & mask; }
        else if (op == WirOpcode.Subtract) { result = (lhs + (mask - rhs) + UInt128(1U)) & mask; }
        else { result = (lhs * rhs) & mask; }
    } else {
        let equal = lhs == rhs;
        let less = lhs < rhs;
        if (op == WirOpcode.SignedLess || op == WirOpcode.SignedLessEqual || op == WirOpcode.SignedGreater || op == WirOpcode.SignedGreaterEqual) {
            let sign: UInt128 = UInt128(1U) << UInt128(width - 1);
            less = (lhs ^ sign) < (rhs ^ sign);
        }
        let condition = false;
        if (op == WirOpcode.Equal) { condition = equal; }
        else if (op == WirOpcode.NotEqual) { condition = !equal; }
        else if (op == WirOpcode.SignedLess || op == WirOpcode.UnsignedLess) { condition = less; }
        else if (op == WirOpcode.SignedLessEqual || op == WirOpcode.UnsignedLessEqual) { condition = less || equal; }
        else if (op == WirOpcode.SignedGreater || op == WirOpcode.UnsignedGreater) { condition = !less && !equal; }
        else if (op == WirOpcode.SignedGreaterEqual || op == WirOpcode.UnsignedGreaterEqual) { condition = !less; }
        else { return false; }
        if (condition) { result = UInt128(1U); }
    }

    let index: Int = wir_id_index(UInt32(instruction.result));
    let value = program.arena.values[index];
    value.kind = WirValueKind.Integer;
    if (instruction.type_id == program.bool_type) { value.kind = WirValueKind.BoolValue; }
    value.owner = 0U;
    value.index = -1;
    value.integer = result;
    program.arena.values[index] = value;
    return true;
}

func wir_discardable(ref program: WirModule, ref instruction: WirInstruction) -> Bool {
    // an unused result is not enough: loads, division, checks and calls can still fault
    let op = instruction.opcode;
    if (op == WirOpcode.StackAlloc || op == WirOpcode.StructValue || op == WirOpcode.ArrayValue || op == WirOpcode.Field || op == WirOpcode.FieldAddress) { return true; }
    if (op == WirOpcode.Truncate || op == WirOpcode.SignExtend || op == WirOpcode.ZeroExtend || op == WirOpcode.Bitcast || op == WirOpcode.PointerToInt || op == WirOpcode.IntToPointer) { return true; }
    if (op == WirOpcode.BitAnd || op == WirOpcode.BitOr || op == WirOpcode.BitXor || op == WirOpcode.Not || op == WirOpcode.Negate) { return true; }
    if (op == WirOpcode.Add || op == WirOpcode.Subtract || op == WirOpcode.Multiply) {
        let type = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        return type.kind == WirTypeKind.SignedInt || type.kind == WirTypeKind.UnsignedInt;
    }
    return false;
}

func wir_mark_instruction(id: WirInstID, ref live: Vector(Bool), ref queue: Vector(WirInstID)) -> Void {
    let index: Int = wir_id_index(UInt32(id));
    if (!live[index]) {
        live[index] = true;
        queue.append(id);
    }
}

func wir_mark_definition(ref program: WirModule, id: WirValueID, ref live: Vector(Bool), ref queue: Vector(WirInstID)) -> Void {
    let ptr value: WirValue = ref program.arena.values[wir_id_index(UInt32(id))];
    if (value.kind == WirValueKind.Instruction) {
        wir_mark_instruction(WirInstID(value.owner), ref live, ref queue);
    }
}

func wir_remap_values(ref values: Vector(WirValueID), ref mapping: Vector(WirValueID)) -> Vector(WirValueID) {
    // most cleanup removes void instructions; their removal does not renumber values
    let i = 0;
    while (i < values.length() && values[i] == mapping[wir_id_index(UInt32(values[i]))]) { i++; }
    if (i == values.length()) { return values; }
    let result: Vector(WirValueID) = [];
    i = 0;
    while (i < values.length()) {
        result.append(mapping[wir_id_index(UInt32(values[i]))]);
        i++;
    }
    return result;
}

func wir_compact_instructions(ref program: WirModule, ref live: Vector(Bool), ref aliases: Vector(WirValueID)) -> Void {
    // compact once, after marking. keep function and block ids stable for metadata
    let inst_map: Vector(WirInstID) = [];
    let instructions: Vector(WirInstruction) = [];
    let i = 0;
    while (i < program.arena.instructions.length()) {
        let id = NO_WIR_INST;
        if (live[i]) {
            instructions.append(program.arena.instructions[i]);
            id = WirInstID(UInt32(instructions.length()));
        }
        inst_map.append(id);
        i++;
    }

    let value_map: Vector(WirValueID) = [];
    let values: Vector(WirValue) = [];
    i = 0;
    while (i < program.arena.values.length()) {
        let value = program.arena.values[i];
        let keep = true;
        if (value.kind == WirValueKind.Instruction) {
            value.owner = UInt32(inst_map[wir_id_index(value.owner)]);
            keep = value.owner != 0U;
        } else if (value.kind == WirValueKind.BlockParameter && aliases[i] != WirValueID(UInt32(i + 1))) {
            keep = false;
        }
        let id = NO_WIR_VALUE;
        if (keep) {
            values.append(value);
            id = WirValueID(UInt32(values.length()));
        }
        value_map.append(id);
        i++;
    }
    i = 0;
    while (i < program.arena.values.length()) {
        if (value_map[i] == NO_WIR_VALUE && aliases[i] != WirValueID(UInt32(i + 1))) {
            value_map[i] = value_map[wir_id_index(UInt32(wir_resolve_alias(WirValueID(UInt32(i + 1)), ref aliases)))];
        }
        i++;
    }

    i = 0;
    while (i < instructions.length()) {
        let instruction: WirInstruction = instructions[i];
        if (instruction.result != NO_WIR_VALUE) { instruction.result = value_map[wir_id_index(UInt32(instruction.result))]; }
        instruction.operands = wir_remap_values(ref instruction.operands, ref value_map);
        if (instruction.edges.length() != 0) {
            let edges: Vector(WirEdge) = [];
            let j = 0;
            while (j < instruction.edges.length()) {
                let edge: WirEdge = instruction.edges[j];
                let parameters = program.arena.blocks[wir_id_index(UInt32(edge.target))].parameters;
                let arguments: Vector(WirValueID) = [];
                let argument_index = 0;
                while (argument_index < edge.arguments.length()) {
                    let parameter: WirValueID = parameters[argument_index];
                    if (aliases[wir_id_index(UInt32(parameter))] == parameter) {
                        arguments.append(value_map[wir_id_index(UInt32(edge.arguments[argument_index]))]);
                    }
                    argument_index++;
                }
                edge.arguments = arguments;
                edges.append(edge);
                j++;
            }
            instruction.edges = edges;
        }
        instructions[i] = instruction;
        i++;
    }
    i = 0;
    while (i < program.arena.blocks.length()) {
        let block = program.arena.blocks[i];
        let kept: Vector(WirInstID) = [];
        let j = 0;
        while (j < block.instructions.length()) {
            let id: WirInstID = inst_map[wir_id_index(UInt32(block.instructions[j]))];
            if (id != NO_WIR_INST) { kept.append(id); }
            j++;
        }
        block.instructions = kept;
        let parameters: Vector(WirValueID) = [];
        j = 0;
        while (j < block.parameters.length()) {
            let parameter: WirValueID = block.parameters[j];
            if (aliases[wir_id_index(UInt32(parameter))] == parameter) {
                let remapped: WirValueID = value_map[wir_id_index(UInt32(parameter))];
                values[wir_id_index(UInt32(remapped))].index = parameters.length();
                parameters.append(remapped);
            }
            j++;
        }
        block.parameters = parameters;
        program.arena.blocks[i] = block;
        i++;
    }
    i = 0;
    while (i < program.arena.functions.length()) {
        let function = program.arena.functions[i];
        function.address = value_map[wir_id_index(UInt32(function.address))];
        function.parameters = wir_remap_values(ref function.parameters, ref value_map);
        program.arena.functions[i] = function;
        i++;
    }
    i = 0;
    while (i < program.arena.globals.length()) {
        let global = program.arena.globals[i];
        global.address = value_map[wir_id_index(UInt32(global.address))];
        if (global.initializer != NO_WIR_VALUE) { global.initializer = value_map[wir_id_index(UInt32(global.initializer))]; }
        program.arena.globals[i] = global;
        i++;
    }
    i = 0;
    while (i < program.arena.constants.length()) {
        let constant = program.arena.constants[i];
        constant.elements = wir_remap_values(ref constant.elements, ref value_map);
        if (constant.target != NO_WIR_VALUE) { constant.target = value_map[wir_id_index(UInt32(constant.target))]; }
        program.arena.constants[i] = constant;
        i++;
    }
    program.arena.instructions = instructions;
    program.arena.values = values;
}

func optimize_wir(ref program: WirModule, level: String) -> WirOptimizationStats {
    let stats = WirOptimizationStats(instructions=0, blocks=0, branches=0, jumps=0, constants=0, copies=0, checks=0, loads=0, stores=0, slots=0, parameters=0);
    if (level == "-O0") {
        return stats;
    }

    // one reachability walk and one backwards use walk, no repeated module scan
    let reachable: Vector(Bool) = [];
    let blocks: Vector(WirBlockID) = [];
    let live: Vector(Bool) = [];
    let folded: Vector(Bool) = [];
    let queue: Vector(WirInstID) = [];
    let parameter_offsets: Vector(Int) = [];
    let parameter_candidates: Vector(WirValueID) = [];
    let parameter_states: Vector(Int) = [];
    let i = 0;
    wir_prepare_block_parameters(ref program, ref parameter_offsets, ref parameter_candidates, ref parameter_states);
    while (i < program.arena.blocks.length()) { reachable.append(false); i++; }
    i = 0;
    while (i < program.arena.instructions.length()) {
        live.append(false);
        let constant = wir_fold_scalar(ref program, ref program.arena.instructions[i]);
        folded.append(constant);
        if (constant) { stats.constants++; }
        i++;
    }
    let plan = wir_optimization_plan(level);
    let aliases = wir_forward_stack_slots(ref program, ref folded, ref stats, plan.forwarding_distance);
    wir_propagate_copies(ref program, ref folded, ref aliases, ref stats);
    if (plan.extra_scans > 0) {
        wir_eliminate_repeated_checks(ref program, ref folded, ref aliases, ref stats);
    }
    if (plan.extra_scans > 1) {
        wir_thread_trivial_jumps(ref program, ref stats);
    }
    if (plan.extra_scans > 2) {
        wir_refold_aliases(ref program, ref folded, ref aliases, ref stats);
    }
    i = 0;
    while (i < program.arena.functions.length()) {
        let entry = program.arena.functions[i].entry;
        if (entry != NO_WIR_BLOCK) {
            reachable[wir_id_index(UInt32(entry))] = true;
            blocks.append(entry);
        }
        i++;
    }

    i = 0;
    while (i < blocks.length()) {
        let block = program.arena.blocks[wir_id_index(UInt32(blocks[i]))];
        let j = 0;
        while (j < block.instructions.length()) {
            let id: WirInstID = block.instructions[j];
            let instruction = program.arena.instructions[wir_id_index(UInt32(id))];
            instruction.operands = wir_rewrite_aliases(ref instruction.operands, ref aliases);
            let alias_edge = 0;
            while (alias_edge < instruction.edges.length()) {
                instruction.edges[alias_edge].arguments = wir_rewrite_aliases(ref instruction.edges[alias_edge].arguments, ref aliases);
                alias_edge++;
            }
            program.arena.instructions[wir_id_index(UInt32(id))] = instruction;
            if (instruction.opcode == WirOpcode.Branch) {
                let condition = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
                if (condition.kind == WirValueKind.BoolValue) {
                    let edge = 0;
                    if (condition.integer == UInt128(0U)) { edge = 1; }
                    instruction.opcode = WirOpcode.Jump;
                    instruction.operands = [];
                    instruction.edges = [instruction.edges[edge]];
                    program.arena.instructions[wir_id_index(UInt32(id))] = instruction;
                    stats.branches++;
                }
            }
            if (!folded[wir_id_index(UInt32(id))] &&
                !wir_discardable(ref program, ref program.arena.instructions[wir_id_index(UInt32(id))])) {
                wir_mark_instruction(id, ref live, ref queue);
            }
            let edge = 0;
            while (edge < instruction.edges.length()) {
                wir_observe_block_arguments(ref program, ref instruction.edges[edge], ref parameter_offsets, ref parameter_candidates, ref parameter_states, ref aliases);
                let target: WirBlockID = instruction.edges[edge].target;
                let index: Int = wir_id_index(UInt32(target));
                if (!reachable[index]) {
                    reachable[index] = true;
                    blocks.append(target);
                }
                edge++;
            }
            j++;
        }
        i++;
    }

    wir_apply_block_parameter_aliases(ref program, ref reachable, ref parameter_offsets, ref parameter_candidates, ref parameter_states, ref aliases, ref stats);
    if (stats.parameters != 0) {
        i = 0;
        while (i < blocks.length()) {
            let ptr block: WirBlock = ref program.arena.blocks[wir_id_index(UInt32(blocks[i]))];
            let j = 0;
            while (j < block.instructions.length()) {
                let ptr instruction: WirInstruction = ref program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
                instruction.operands = wir_rewrite_aliases(ref instruction.operands, ref aliases);
                let edge_index = 0;
                while (edge_index < instruction.edges.length()) {
                    instruction.edges[edge_index].arguments = wir_rewrite_aliases(ref instruction.edges[edge_index].arguments, ref aliases);
                    edge_index++;
                }
                j++;
            }
            i++;
        }
    }

    i = 0;
    while (i < queue.length()) {
        let ptr instruction: WirInstruction = ref program.arena.instructions[wir_id_index(UInt32(queue[i]))];
        let j = 0;
        while (j < instruction.operands.length()) {
            wir_mark_definition(ref program, instruction.operands[j], ref live, ref queue);
            j++;
        }
        j = 0;
        while (j < instruction.edges.length()) {
            let arguments: Vector(WirValueID) = instruction.edges[j].arguments;
            let k = 0;
            while (k < arguments.length()) {
                wir_mark_definition(ref program, arguments[k], ref live, ref queue);
                k++;
            }
            j++;
        }
        i++;
    }

    i = 0;
    while (i < program.arena.functions.length()) {
        let function = program.arena.functions[i];
        let kept: Vector(WirBlockID) = [];
        let j = 0;
        while (j < function.blocks.length()) {
            let block: WirBlockID = function.blocks[j];
            if (reachable[wir_id_index(UInt32(block))]) { kept.append(block); }
            else { stats.blocks++; }
            j++;
        }
        function.blocks = kept;
        program.arena.functions[i] = function;
        i++;
    }
    i = 0;
    while (i < live.length()) {
        if (!live[i]) { stats.instructions++; }
        i++;
    }
    if (stats.instructions != 0 || stats.parameters != 0) {
        wir_compact_instructions(ref program, ref live, ref aliases);
    }
    return stats;
}
