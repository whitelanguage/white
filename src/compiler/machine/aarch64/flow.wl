// src/compiler/machine/aarch64/flow.wl
import * from "model.wl"
import * from "../../wir/model.wl"
import * from "encoder.wl"
import * from "allocator.wl"
import a64_scalar_float from "fp.wl"
import * from "types.wl"


struct A64BlockOffset(block: WirBlockID, offset: Int)

struct A64BranchFixup(
    offset: Int,
    target: WirBlockID,
    condition: A64Condition,
    conditional: Bool
)

func a64_mark_edge_registers(ref program: WirModule, order: Vector(WirBlockID), ref uses: A64UseTable) -> Void {
// every predecessor agrees on the entry registers, back edges keep their parallel stack copies
    let last_pred: Dict(UInt32, Int) = Dict();
    let i = 0;
    while (i < order.length()) {
        let block = program.arena.blocks[wir_id_index(UInt32(order[i]))];
        if (block.instructions.length() != 0) {
            let term = program.arena.instructions[wir_id_index(UInt32(block.instructions[block.instructions.length() - 1]))];
            let j = 0;
            while (j < term.edges.length()) {
                last_pred.put(UInt32(term.edges[j].target), i + 1);
                j++;
            }
        }
        i++;
    }

    i = 1;
    while (i < order.length()) {
        let block = program.arena.blocks[wir_id_index(UInt32(order[i]))];
        let pred = 0;
        pred = last_pred.get(UInt32(order[i]))?;
        catch(err) { pred = 0; }
        if (pred == 0 || pred > i || block.parameters.length() == 0 || block.parameters.length() > 14) {
            i++;
            continue;
        }

        let assigned: Vector(A64Register) = [];
        let integers = 0;
        let floats = 0;
        let j = 0;
        while (j < block.parameters.length()) {
            let type = program.arena.values[wir_id_index(UInt32(block.parameters[j]))].type_id;
            if (a64_scalar_width(ref program, type) == 0) { break; }
            let reg = A64Register.None;
            if (a64_scalar_float(ref program, type)) {
                reg = a64_float_work_register(floats);
                floats++;
            } else {
                reg = a64_work_register(integers);
                integers++;
            }
            if (reg == A64Register.None) { break; }
            assigned.append(reg);
            j++;
        }

        // partial contracts complicate cycles between registers and homes.
        // Fall back as a block if its parameters do not fit the volatile banks.
        if (assigned.length() == block.parameters.length()) {
            j = 0;
            while (j < assigned.length()) {
                let index = a64_use_index(ref uses, block.parameters[j]);
                let queue = uses.queues[index];
                queue.incoming = assigned[j];
                uses.queues[index] = queue;
                j++;
            }
        }
        i++;
    }
}

func a64_patch_branches(ref output: A64CodeBuffer, offsets: Vector(A64BlockOffset), fixups: Vector(A64BranchFixup)) -> Bool {
// one offset index serves every branch, zero is a valid code offset
    let targets: Dict(UInt32, Int) = Dict();
    let i: Int = 0;

    while (i < offsets.length()) {
        targets.put(UInt32(offsets[i].block), offsets[i].offset + 1);
        i++;
    }
    i = 0;

    while (i < fixups.length()) {
        let fixup: A64BranchFixup = fixups[i];
        let target: Int = 0;
        target = targets.get(UInt32(fixup.target))?;
        catch(err) { target = 0; }
        target--;
        if (target < 0 || !a64_patch_branch(ref output, fixup.offset, target, fixup.condition, fixup.conditional)) {
            return false;
        }
        i++;
    }

    return true;
}
