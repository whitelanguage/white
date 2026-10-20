// src/compiler/machine/spill.wl
import * from "../wir/model.wl"
import machine_rematerializable from "allocator.wl"


struct MachineLiveInterval(start: Int, last: Int, input: Bool)


func machine_mark_live_interval(ref before_changes: Vector(Int), ref after_changes: Vector(Int), start: Int, last: Int) -> Void {
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

func machine_spill_capacity(ref program: WirModule, order: Vector(WirBlockID), intervals: Vector(MachineLiveInterval), register_count: Int) -> Int {
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

    for (let interval = 0; interval < intervals.length(); interval++) {
        let life = intervals[interval];
        if (life.start > life.last) { continue; }
        machine_mark_live_interval(ref before_changes, ref after_changes, life.start, life.last);
        let first = life.start + 1;
        if (life.input) { first = life.start; }
        if (first <= life.last) {
            call_changes[first] = call_changes[first] + 1;
            call_changes[life.last + 1] = call_changes[life.last + 1] - 1;
        }
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

                if (temporary && before + 1 > peak) { peak = before + 1; }
                if (instruction.opcode == WirOpcode.IndexAddress || instruction.opcode == WirOpcode.FieldAddress) {
                    // address formation keeps inputs alive while claiming a separate destination
                    let extra = 1;
                    let inputs = 1;

                    if (instruction.opcode == WirOpcode.IndexAddress) {
                        inputs = instruction.operands.length();
                    }

                    let operand_index = 0;

                    while (operand_index < inputs) {
                        if (machine_rematerializable(ref program, instruction.operands[operand_index])) {
                            extra++;
                        }
                        operand_index++;
                    }

                    if (before + extra > peak) { peak = before + extra; }
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
        // next-use eviction can briefly keep the old value while claiming the result register
        required++;
    }

    if (call_peak > required) { required = call_peak; }

    return required;
}
