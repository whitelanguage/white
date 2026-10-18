// src/compiler/machine/x86_64/flow.wl
import * from "model.wl"
import * from "../../wir/model.wl"
import * from "encoder.wl"
import * from "allocator.wl"
import * from "types.wl"


struct X86ValueFlags(base: Int, values: Vector(Bool))

struct X86BlockOffset(
    block: WirBlockID,
    offset: Int
)

struct X86BranchFixup(
    offset: Int,
    target: WirBlockID
)

func x86_mark_return_registers(ref program: WirModule, order: Vector(WirBlockID), ref uses: X86UseTable) -> Void {
    let block_index: Int = 0;
    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];
        let instruction_index: Int = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];
            if (instruction.opcode == WirOpcode.Return && instruction.operands.length() == 1) {
                let value_id: WirValueID = instruction.operands[0];
                let ptr value: WirValue = ref program.arena.values[wir_id_index(UInt32(value_id))];
                if (x86_scalar_size(ref program, value.type_id) != 0) {
                    let preferred: X86Register = X86Register.RAX;
                    if (x86_scalar_float(ref program, value.type_id)) { preferred = X86Register.XMM0; }
                    x86_prefer_register(ref uses, value_id, preferred);
                }
            }
            instruction_index++;
        }
        block_index++;
    }
}

func x86_mark_edge_registers(ref program: WirModule, order: Vector(WirBlockID), ref uses: X86UseTable) -> Void {
// only forward joins get an entry contract. A back edge or reordered block
    // keeps the old homes, no loop liveness iteration is needed for this pass.
    // indices are local to this function, not sized to the whole module arena.
    let last_pred: Dict(UInt32, Int) = Dict();
    let i = 0;
    while (i < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[i]))];
        if (block.instructions.length() != 0) {
            let term: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[block.instructions.length() - 1]))];
            let j = 0;
            while (j < term.edges.length()) {
                last_pred.put(UInt32(term.edges[j].target), i + 1);
                j++;
            }
        }
        i++;
    }

    let integers: Vector(X86Register) = x86_allocatable_registers();
    let floats: Vector(X86Register) = [X86Register.XMM0, X86Register.XMM1, X86Register.XMM2, X86Register.XMM3, X86Register.XMM4, X86Register.XMM5];
    i = 1;
    while (i < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[i]))];
        let pred: Int = last_pred.lookup(UInt32(order[i]));
        if (pred == 0 || pred > i || block.parameters.length() == 0 || block.parameters.length() > integers.length() + floats.length()) {
            i++;
            continue;
        }

        let assigned: Vector(X86Register) = [];
        let used: UInt64 = 0UL;
        let j = 0;
        while (j < block.parameters.length()) {
            let param: WirValueID = block.parameters[j];
            let type_id: WirTypeID = program.arena.values[wir_id_index(UInt32(param))].type_id;
            if (x86_scalar_size(ref program, type_id) == 0) {
                break;
            }
            let floating: Bool = x86_scalar_float(ref program, type_id);
            let bank: Vector(X86Register) = integers;
            if floating { bank = floats; }
            let reg: X86Register = x86_preferred_register(ref uses, param);
            if (reg == X86Register.None || !x86_allocatable_register(reg) || x86_is_xmm(reg) != floating ||
                (used & x86_register_clobber(reg)) != 0UL) {
                reg = X86Register.None;
                let k = 0;
                while (k < bank.length()) {
                    if ((used & x86_register_clobber(bank[k])) == 0UL) {
                        reg = bank[k];
                        break;
                    }
                    k++;
                }
            }
            if (reg == X86Register.None) {
                break;
            }
            assigned.append(reg);
            used |= x86_register_clobber(reg);
            j++;
        }
        if (assigned.length() == block.parameters.length()) {
            j = 0;
            while (j < assigned.length()) {
                let index: Int = x86_use_index(ref uses, block.parameters[j]);
                let queue: X86UseQueue = uses.queues[index];
                queue.incoming = assigned[j];
                queue.preferred = assigned[j];
                uses.queues[index] = queue;
                j++;
            }
        }
        i++;
    }

    // one hint per producer is enough. Conflicting edges can repair their own
    // copies, and return-value preferences stay stronger than an edge hint.
    i = 0;
    while (i < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[i]))];
        if (block.instructions.length() != 0) {
            let term: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[block.instructions.length() - 1]))];
            let j = 0;
            while (j < term.edges.length()) {
                let edge: WirEdge = term.edges[j];
                let target: WirBlock = program.arena.blocks[wir_id_index(UInt32(edge.target))];
                let k = 0;
                while (k < edge.arguments.length() && k < target.parameters.length()) {
                    let reg: X86Register = x86_incoming_register(ref uses, target.parameters[k]);
                    let arg: WirValueID = edge.arguments[k];
                    if (reg != X86Register.None && x86_preferred_register(ref uses, arg) == X86Register.None &&
                        program.arena.values[wir_id_index(UInt32(arg))].kind == WirValueKind.Instruction) {
                        x86_prefer_register(ref uses, arg, reg);
                    }
                    k++;
                }
                j++;
            }
        }
        i++;
    }
}

func x86_block_order(function: WirFunction) -> Vector(WirBlockID) {
    let order: Vector(WirBlockID) = [];
    if (function.entry != NO_WIR_BLOCK) {
        order.append(function.entry);
    }

    let i = 0;
    while (i < function.blocks.length()) {
        if (function.blocks[i] != function.entry) {
            order.append(function.blocks[i]);
        }

        i++;
    }

    return order;
}

func x86_predecessor_counts(ref program: WirModule, order: Vector(WirBlockID)) -> Dict(UInt32, Int) {
// block IDs belong to the module, keep only this function's incoming edges
    let counts: Dict(UInt32, Int) = Dict();
    let i: Int = 0;

    let block_index: Int = 0;
    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];
        i = 0;
        while (i < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[i]))];
            let edge_index: Int = 0;
            while (edge_index < instruction.edges.length()) {
                let target: UInt32 = UInt32(instruction.edges[edge_index].target);
                counts.put(target, counts.lookup(target) + 1);
                edge_index++;
            }
            i++;
        }
        block_index++;
    }
    return counts;
}

func x86_carry_registers_to_next(ref program: WirModule, order: Vector(WirBlockID), predecessors: Dict(UInt32, Int), block_index: Int) -> Bool {
    if (block_index + 1 >= order.length()) { return false; }
    let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];
    if (block.instructions.length() == 0) { return false; }

    let terminator: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[block.instructions.length() - 1]))];
    if (terminator.opcode != WirOpcode.Jump || terminator.edges.length() != 1 || terminator.edges[0].arguments.length() != 0 ||
        terminator.edges[0].target != order[block_index + 1]) {
        return false;
    }

    let target_index: Int = wir_id_index(UInt32(terminator.edges[0].target));
    if (target_index < 0 || target_index >= program.arena.blocks.length() || predecessors.lookup(UInt32(terminator.edges[0].target)) != 1) {
        return false;
    }
    return program.arena.blocks[target_index].parameters.length() == 0;
}

func x86_flag_index(flags: X86ValueFlags, value: WirValueID) -> Int {
    return wir_id_index(UInt32(value)) - flags.base;
}

func x86_flag(flags: X86ValueFlags, value: WirValueID) -> Bool {
    let index: Int = x86_flag_index(flags, value);
    return index >= 0 && index < flags.values.length() && flags.values[index];
}

func x86_mark_cross_uses(ref program: WirModule, block: WirBlockID, values: Vector(WirValueID), base: Int, definitions: Vector(UInt32), cross: X86ValueFlags) -> Void {
    let i = 0;
    while (i < values.length()) {
        let index: Int = wir_id_index(UInt32(values[i])) - base;
        if (index >= 0 && index < definitions.length() && definitions[index] != 0U && definitions[index] != UInt32(block) && !x86_rematerializable(ref program, values[i])) {
            cross.values[index] = true;
        }

        i++;
    }
}

func x86_cross_block_values(ref program: WirModule, order: Vector(WirBlockID)) -> X86ValueFlags {
// definitions and uses are indexed once, block emission order is irrelevant
    let range: X86ValueRange = x86_function_value_range(ref program, order);
    let definitions: Vector(UInt32) = [];
    let cross: Vector(Bool) = [];

    let i = 0;
    while (i < range.count) {
        definitions.append(0U);
        cross.append(false);
        i++;
    }

    let block_index = 0;
    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];

        i = 0;
        while (i < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[i]))];
            if (instruction.result != NO_WIR_VALUE) {
                definitions[wir_id_index(UInt32(instruction.result)) - range.base] = UInt32(order[block_index]);
            }

            i++;
        }

        block_index++;
    }

    block_index = 0;
    while (block_index < order.length()) {
        let block_id: WirBlockID = order[block_index];
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];

        i = 0;
        while (i < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[i]))];
            x86_mark_cross_uses(ref program, block_id, instruction.operands, range.base, definitions, X86ValueFlags(base=range.base, values=cross));

            let edge_index = 0;
            while (edge_index < instruction.edges.length()) {
                x86_mark_cross_uses(ref program, block_id, instruction.edges[edge_index].arguments, range.base, definitions, X86ValueFlags(base=range.base, values=cross));
                edge_index++;
            }
            i++;
        }
        block_index++;
    }
    return X86ValueFlags(base=range.base, values=cross);
}

func x86_patch_branches(ref output: X86CodeBuffer, offsets: Vector(X86BlockOffset), fixups: Vector(X86BranchFixup)) -> Bool {
    let targets: Dict(UInt32, Int) = Dict();
    let i = 0;
    while (i < offsets.length()) {
        targets.put(UInt32(offsets[i].block), offsets[i].offset + 1);
        i++;
    }
    i = 0;
    while (i < fixups.length()) {
        let target: Int = targets.lookup(UInt32(fixups[i].target)) - 1;
        if (target < 0) { return false; }

        let displacement: Int = target - (fixups[i].offset + 4);
        if (displacement < -2147483648 || displacement > 2147483647) { return false; }

        if (!x86_patch_i32(ref output, fixups[i].offset, displacement)) { return false; }

        i++;
    }

    return true;
}
