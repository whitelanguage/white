// src/compiler/machine/x86_64/stack.wl
import * from "model.wl"
import * from "../../wir/model.wl"
import * from "encoder.wl"
import * from "allocator.wl"
import x86_call_frame from "abi.wl"
import X86SysVCallLayout, x86_plan_sysv_call from "abi/sysv.wl"
import * from "flow.wl"
import * from "types.wl"
import * from "../homes.wl"


struct X86StackSlot(
    value: WirValueID,
    offset: Int,
    size: Int
)

struct X86StackIndex(
    base: Int,
    dense_count: Int,
    sparse: Dict(UInt32, Int),
    offsets: Vector(Int),
    sizes: Vector(Int)
)

struct X86CallStorage(arguments: Vector(Int), result: Int, size: Int)

func x86_const_homes(ref program: WirModule, order: Vector(WirBlockID)) -> Vector(WirValueID) {
// edge operands live outside the ordinary result range, reserve each constant once
    let values: Vector(WirValueID) = [];
    let seen: Dict(UInt32, Bool) = null;
    for (let b = 0; b < order.length(); b++) {
        let block = program.arena.blocks[wir_id_index(UInt32(order[b]))];
        for (let i = 0; i < block.instructions.length(); i++) {
            let inst = program.arena.instructions[wir_id_index(UInt32(block.instructions[i]))];
            for (let e = -1; e < inst.edges.length(); e++) {
                let operands = inst.operands;
                if (e >= 0) { operands = inst.edges[e].arguments; }
                for (let j = 0; j < operands.length(); j++) {
                    let id = operands[j];
                    let value = program.arena.values[wir_id_index(UInt32(id))];
                    if (value.kind == WirValueKind.Constant && x86_aggregate_type(ref program, value.type_id) &&
                        (program.arena.constants[wir_id_index(value.owner)].kind == WirConstKind.Aggregate ||
                         program.arena.constants[wir_id_index(value.owner)].kind == WirConstKind.Bytes) &&
                        (seen is null || !seen.lookup(UInt32(id)))) {
                        if (seen is null) { seen = Dict(); }
                        values.append(id);
                        seen.put(UInt32(id), true);
                    }
                }
            }
        }
    }

    return values;
}

func x86_add_const_slots(ref program: WirModule, values: Vector(WirValueID), layouts: Vector(WirTypeLayout), ref slots: Vector(X86StackSlot)) -> Bool {
    let offset = x86_stack_slots_end(slots);
    for (let i = 0; i < values.length(); i++) {
        let value = program.arena.values[wir_id_index(UInt32(values[i]))];
        let layout = layouts[wir_id_index(UInt32(value.type_id))];
        if (!layout.valid || layout.size > 2147483632UL) {
            return false;
        }

        let size = Int(layout.size);
        if (size == 0) {
            size = 1;
        }

        if (size > 2147483647 - offset - (layout.alignment - 1)) {
            return false;
        }

        offset = x86_align_frame_offset(offset + size, layout.alignment);
        slots.append(X86StackSlot(value=values[i], offset=offset, size=size));
    }

    return true;
}

struct X86FunctionAnalysis(
    message: String,
    located_values: Int,
    edge_scratch: Int,
    home_parameters: Bool,
    has_float: Bool,
    integer_division: Bool,
    u64_cast: Bool,
    float_negate: Bool,
    wide_operation: Bool,
    call_frame: Int
)

func x86_align_frame_offset(value: Int, alignment: Int) -> Int {
    if (alignment <= 1) { return value; }

    let remainder: Int = value % alignment;
    if (remainder == 0) { return value; }

    return value + alignment - remainder;
}

func x86_collect_stack_slots(
    ref program: WirModule,
    function: WirFunction,
    order: Vector(WirBlockID),
    home_parameters: Bool,
    cross: X86ValueFlags,
    layouts: Vector(WirTypeLayout)
) -> Vector(X86StackSlot) {
    return x86_stack_slots_with_uses(ref program, function, order, home_parameters, cross, layouts, x86_collect_uses(ref program, order));
}

func x86_stack_slots_with_uses(
    ref program: WirModule,
    function: WirFunction,
    order: Vector(WirBlockID),
    home_parameters: Bool,
    cross: X86ValueFlags,
    layouts: Vector(WirTypeLayout),
    uses: X86UseTable
) -> Vector(X86StackSlot) {
    let slots: Vector(X86StackSlot) = [];
    let pool = StackHomes(size=0, regions=[], free=null, ends=[]);
    let offset = 0;
    if home_parameters {
        let param_index = 0;
        while (param_index < function.parameters.length()) {
            let parameter: WirValue = program.arena.values[wir_id_index(UInt32(function.parameters[param_index]))];
            let size: Int = x86_abi_size(ref program, parameter.type_id, layouts);
            let alignment = size;

            if (x86_native_sysv_abi(function.abi) && x86_memory_value(ref program, parameter.type_id)) {
                let layout: WirTypeLayout = layouts[wir_id_index(UInt32(parameter.type_id))];
                if (!layout.valid || layout.size > 2147483632UL) {
                    return [];
                }

                size = Int(layout.size);
                if (size == 0) { size = 1; }
                alignment = layout.alignment;
            } else if (x86_indirect_argument(ref program, parameter.type_id, layouts, function.abi)) {
                let layout: WirTypeLayout = layouts[wir_id_index(UInt32(parameter.type_id))];
                if (!layout.valid || layout.size > 2147483632UL) {
                    return [];
                }

                size = Int(layout.size);
                if (size < 8) { size = 8; }

                alignment = 16;
            }
            if (size == 0) {
                return [];
            }
            if (size > 2147483647 - offset - (alignment - 1)) {
                return [];
            }

            offset = x86_align_frame_offset(offset + size, alignment);
            slots.append(X86StackSlot(value=function.parameters[param_index], offset=offset, size=size));
            param_index++;
        }
    }

    let position: Int = 0;
    let block_index = 0;
    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];
        let block_start = position;
        pool.ends = [];

        let i = 0;
        while (i < block.instructions.length()) {
            if (pool.ends.length() != 0) { stack_expire(ref pool, i); }
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[i]))];
            if (instruction.opcode == WirOpcode.StackAlloc && instruction.result != NO_WIR_VALUE) {
                let pointer: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
                if (pointer.kind != WirTypeKind.Pointer) {
                    return [];
                }

                let layout: WirTypeLayout = layouts[wir_id_index(UInt32(pointer.element))];
                if (!layout.valid || layout.size == 0UL || layout.size > 2147483647UL) {
                    return [];
                }

                offset = x86_align_frame_offset(offset + Int(layout.size), layout.alignment);
                slots.append(X86StackSlot(value=instruction.result, offset=offset, size=Int(layout.size)));
            } else if (instruction.result != NO_WIR_VALUE && x86_memory_value(ref program, instruction.type_id)) {
                let layout: WirTypeLayout = layouts[wir_id_index(UInt32(instruction.type_id))];
                if (!layout.valid || layout.size > 2147483647UL) { return []; }
                let size = Int(layout.size);
                if (size == 0) { size = 1; }
                let last_use: Int = position;
                let value_index: Int = x86_use_index(ref uses, instruction.result);
                if (value_index >= 0 && value_index < uses.queues.length()) {
                    let queue: X86UseQueue = uses.queues[value_index];
                    if (queue.positions.length() != 0) {
                        last_use = queue.positions[queue.positions.length() - 1];
                    }
                }

                if (!x86_flag(cross, instruction.result)) {
                    pool.size = offset;
                    if (pool.ends.length() == 0) { stack_begin_block(ref pool, block.instructions.length()); }
                    let home = stack_reuse(ref pool, size, layout.alignment, last_use - block_start, true);
                    if (home < 0) { return []; }
                    offset = pool.size;
                    slots.append(X86StackSlot(value=instruction.result, offset=home, size=size));
                } else {
                    if (size > 2147483647 - offset - (layout.alignment - 1)) {
                        return [];
                    }
                    offset = x86_align_frame_offset(offset + size, layout.alignment);
                    slots.append(X86StackSlot(value=instruction.result, offset=offset, size=size));
                }
            } else if (instruction.result != NO_WIR_VALUE && x86_flag(cross, instruction.result)) {
                let size: Int = x86_scalar_size(ref program, instruction.type_id);
                if (size == 0) {
                    return [];
                }
                offset = x86_align_frame_offset(offset + size, size);
                slots.append(X86StackSlot(value=instruction.result, offset=offset, size=size));
            }
            position++;
            i++;
        }
        if (pool.ends.length() != 0) { stack_expire(ref pool, block.instructions.length()); }

        i = 0;
        while (i < block.parameters.length()) {
            let parameter: WirValue = program.arena.values[wir_id_index(UInt32(block.parameters[i]))];
            let size: Int = x86_scalar_size(ref program, parameter.type_id);
            let alignment = size;
            if (x86_memory_value(ref program, parameter.type_id)) {
                let layout = layouts[wir_id_index(UInt32(parameter.type_id))];
                if (!layout.valid || layout.size > 2147483647UL) {
                    return [];
                }
                size = Int(layout.size);
                if (size == 0) { size = 1; }
                alignment = layout.alignment;
            }
            if (size == 0 || size > 2147483647 - offset - (alignment - 1)) {
                return [];
            }
            offset = x86_align_frame_offset(offset + size, alignment);
            slots.append(X86StackSlot(value=block.parameters[i], offset=offset, size=size));
            i++;
        }

        block_index++;
    }
    return slots;
}

func x86_stack_slots_end(slots: Vector(X86StackSlot)) -> Int {
    let end: Int = 0;
    let i: Int = 0;
    while (i < slots.length()) {
        if (slots[i].offset > end) { end = slots[i].offset; }
        i++;
    }
    return end;
}

func x86_stack_index(slots: Vector(X86StackSlot), range: X86ValueRange) -> X86StackIndex {
    let offsets: Vector(Int) = [];
    let sizes: Vector(Int) = [];
    let sparse: Dict(UInt32, Int) = null;
    let count = stack_index_count(range.count, slots.length());
    let i = 0;
    while (i < count) {
        offsets.append(0);
        sizes.append(0);
        i++;
    }
    i = 0;
    while (i < slots.length()) {
        let index: Int = wir_id_index(UInt32(slots[i].value));
        let local: Int = index - range.base;
        if (local < 0 || local >= count) {
            local = offsets.length();
            if (sparse is null) { sparse = Dict(); }
            let previous = sparse.lookup(UInt32(slots[i].value));
            if (previous != 0) { local = previous - 1; }
            else {
                sparse.put(UInt32(slots[i].value), local + 1);
                offsets.append(0);
                sizes.append(0);
            }
        }
        offsets[local] = 0 - slots[i].offset;
        sizes[local] = slots[i].size;
        i++;
    }
    return X86StackIndex(base=range.base, dense_count=count, sparse=sparse, offsets=offsets, sizes=sizes);
}

func x86_stack_index_of(ref stack: X86StackIndex, value: WirValueID) -> Int {
    let index: Int = wir_id_index(UInt32(value));
    if (index >= stack.base && index < stack.base + stack.dense_count) { return index - stack.base; }
    if (stack.sparse is !null) { return stack.sparse.lookup(UInt32(value)) - 1; }
    return -1;
}

func x86_stack_offset(ref stack: X86StackIndex, value: WirValueID) -> Int {
    let index: Int = x86_stack_index_of(ref stack, value);
    if (index < 0 || index >= stack.offsets.length()) { return 0; }
    return stack.offsets[index];
}

func x86_stack_size(ref stack: X86StackIndex, value: WirValueID) -> Int {
    let index: Int = x86_stack_index_of(ref stack, value);
    if (index < 0 || index >= stack.sizes.length()) { return 0; }
    return stack.sizes[index];
}

func x86_edge_scratch(ref program: WirModule, order: Vector(WirBlockID), slots: Vector(X86StackSlot), layouts: Vector(WirTypeLayout), count: Int) -> Vector(Int) {
// reuse staging slots across edges, sized for the largest value at each position
    let sizes: Vector(Int) = [];
    let alignments: Vector(Int) = [];
    let i = 0;
    while (i < count) {
        sizes.append(8);
        alignments.append(8);
        i++;
    }
    let block_index = 0;
    while (block_index < order.length()) {
        let block = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];
        let instruction_index = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];
            let edge_index = 0;
            while (edge_index < instruction.edges.length()) {
                let arguments: Vector(WirValueID) = instruction.edges[edge_index].arguments;
                i = 0;
                while (i < arguments.length()) {
                    let value = program.arena.values[wir_id_index(UInt32(arguments[i]))];
                    if (x86_memory_value(ref program, value.type_id)) {
                        let layout = layouts[wir_id_index(UInt32(value.type_id))];
                        if (!layout.valid || layout.size > 2147483647UL) {
                            return [];
                        }
                        if (Int(layout.size) > sizes[i]) { sizes[i] = Int(layout.size); }
                        if (layout.alignment > alignments[i]) { alignments[i] = layout.alignment; }
                    }
                    i++;
                }
                edge_index++;
            }
            instruction_index++;
        }
        block_index++;
    }
    let offsets: Vector(Int) = [];
    let offset: Int = 0;
    offset = x86_stack_slots_end(slots);

    i = 0;
    while (i < count) {
        if (sizes[i] > 2147483647 - offset - (alignments[i] - 1)) {
            return [];
        }
        offset = x86_align_frame_offset(offset + sizes[i], alignments[i]);
        offsets.append(0 - offset);
        i++;
    }

    return offsets;
}

func x86_spill_locations(slots: Vector(X86StackSlot), scratch: Vector(Int), count: Int) -> Vector(Int) {
    let offsets: Vector(Int) = [];
    let offset: Int = 0;
    offset = x86_stack_slots_end(slots);
    if (scratch.length() != 0 && 0 - scratch[scratch.length() - 1] > offset) {
        offset = 0 - scratch[scratch.length() - 1];
    }

    let i = 0;
    while (i < count) {
        offset = x86_align_frame_offset(offset + 8, 8);
        offsets.append(0 - offset);
        i++;
    }

    return offsets;
}

func x86_stack_frame_size(slots: Vector(X86StackSlot), scratch: Vector(Int), spills: Vector(Int)) -> Int {
    let size: Int = 0;
    size = x86_stack_slots_end(slots);

    if (scratch.length() != 0 && 0 - scratch[scratch.length() - 1] > size) {
        size = 0 - scratch[scratch.length() - 1];
    }
    if (spills.length() != 0 && 0 - spills[spills.length() - 1] > size) {
        size = 0 - spills[spills.length() - 1];
    }
    return x86_align_frame_offset(size, 16);
}

func x86_call_storage(ref program: WirModule, signature: WirType, layouts: Vector(WirTypeLayout)) -> X86CallStorage {
    let hidden: Bool = x86_indirect_return(ref program, signature.result, layouts, signature.abi);
    if (x86_native_sysv_abi(signature.abi)) {
        let call_layout: X86SysVCallLayout = X86SysVCallLayout(hidden=X86Register.None, arguments=[], stack_size=0);
        x86_plan_sysv_call(ref program, signature, layouts, hidden, ref call_layout);
        let size: Int = x86_align_frame_offset(call_layout.stack_size, 16);
        let arguments: Vector(Int) = [];
        let i: Int = 0;
        while (i < signature.parameters.length()) {
            let layout: WirTypeLayout = layouts[wir_id_index(UInt32(signature.parameters[i]))];
            if (!layout.valid || layout.size > 2147483632UL || Int(layout.size) > 2147483632 - size) {
                return X86CallStorage(arguments=[], result=-1, size=-1);
            }
            arguments.append(size);
            let extent: Int = Int(layout.size);
            if (extent == 0) { extent = 1; }
            size = x86_align_frame_offset(size + extent, 8);
            i++;
        }

        let result: Int = -1;
        if hidden {
            let layout: WirTypeLayout = layouts[wir_id_index(UInt32(signature.result))];
            if (!layout.valid || layout.size > 2147483632UL || Int(layout.size) > 2147483632 - size) {
                return X86CallStorage(arguments=[], result=-1, size=-1);
            }
            result = size;
            let extent: Int = Int(layout.size);
            if (extent == 0) { extent = 1; }
            size = x86_align_frame_offset(size + extent, 16);
        }
        return X86CallStorage(arguments=arguments, result=result, size=size);
    }

    let count: Int = signature.parameters.length();
    if hidden { count++; }
    let size: Int = x86_call_frame(count);
    let arguments: Vector(Int) = [];
    let result = -1;
    let i = 0;
    while (i <= signature.parameters.length()) {
        let type_id: WirTypeID = signature.result;
        let indirect: Bool = hidden;
        if (i < signature.parameters.length()) {
            type_id = signature.parameters[i];
            indirect = x86_indirect_argument(ref program, type_id, layouts, signature.abi);
        }
        let offset = -1;
        if indirect {
            let layout: WirTypeLayout = layouts[wir_id_index(UInt32(type_id))];
            if (!layout.valid || layout.size > 2147483632UL || Int(layout.size) > 2147483632 - size) {
                return X86CallStorage(arguments=[], result=-1, size=-1);
            }
            offset = size;
            let extent = Int(layout.size);
            if (extent == 0) { extent = 1; }
            size = x86_align_frame_offset(size + extent, 16);
        }
        if (i < signature.parameters.length()) {
            arguments.append(offset);
        }
        else {
            result = offset;
        }
        i++;
    }
    return X86CallStorage(arguments=arguments, result=result, size=size);
}

func x86_analyze_function(ref program: WirModule, function_id: WirFuncID, function: WirFunction, order: Vector(WirBlockID), layouts: Vector(WirTypeLayout)) -> X86FunctionAnalysis {
// collect frame requirements together. These queries used to walk the
    // same instruction list separately before register allocation could start.
    let result = X86FunctionAnalysis(
        message="",
        located_values=0,
        edge_scratch=0,
        home_parameters=false,
        has_float=false,
        integer_division=false,
        u64_cast=false,
        float_negate=false,
        wide_operation=false,
        call_frame=0
    );
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    result.has_float = x86_scalar_float(ref program, signature.result);

    let i: Int = 0;
    while (i < function.parameters.length()) {
        let parameter: WirValue = program.arena.values[wir_id_index(UInt32(function.parameters[i]))];
        if (x86_memory_value(ref program, parameter.type_id)) { result.home_parameters = true; }
        if (x86_scalar_float(ref program, parameter.type_id)) { result.has_float = true; }
        i++;
    }

    let block_index: Int = 0;
    while (block_index < order.length()) {
        let index: Int = wir_id_index(UInt32(order[block_index]));
        if (index < 0 || index >= program.arena.blocks.length()) {
            result.message = "function refers to an unknown basic block";
            return result;
        }

        let block: WirBlock = program.arena.blocks[index];
        if (block.function != function_id) {
            result.message = "function refers to a basic block owned by another function";
            return result;
        }
        if (block.instructions.length() == 0) {
            result.message = "the x86_64 lowering requires every basic block to have a terminator";
            return result;
        }

        result.located_values += block.parameters.length();
        i = 0;
        while (i < block.parameters.length()) {
            let parameter: WirValue = program.arena.values[wir_id_index(UInt32(block.parameters[i]))];
            if (x86_memory_value(ref program, parameter.type_id)) { result.home_parameters = true; }
            i++;
        }

        let instruction_index: Int = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];
            let opcode: WirOpcode = instruction.opcode;
            if (opcode == WirOpcode.StackAlloc) { result.located_values++; }

            if (x86_memory_value(ref program, instruction.type_id) ||
                (opcode == WirOpcode.Store && instruction.operands.length() == 2 &&
                 x86_memory_value(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id))) {
                // aggregate copy loops borrow RCX, save incoming arguments before that happens
                result.home_parameters = true;
            }
            if (opcode == WirOpcode.Call || opcode == WirOpcode.Retain || opcode == WirOpcode.Release ||
                opcode == WirOpcode.AtomicRmw || opcode == WirOpcode.SignedDivide ||
                opcode == WirOpcode.UnsignedDivide || opcode == WirOpcode.SignedRemainder ||
                opcode == WirOpcode.UnsignedRemainder || opcode == WirOpcode.ShiftLeft ||
                opcode == WirOpcode.SignedShiftRight || opcode == WirOpcode.UnsignedShiftRight) {
                result.home_parameters = true;
            }

            if (x86_scalar_float(ref program, instruction.type_id)) { result.has_float = true; }
            let operand_index: Int = 0;
            while (operand_index < instruction.operands.length()) {
                let operand: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[operand_index]))];
                if (x86_scalar_float(ref program, operand.type_id)) { result.has_float = true; }
                operand_index++;
            }

            let division: Bool = opcode == WirOpcode.SignedDivide || opcode == WirOpcode.UnsignedDivide ||
                                 opcode == WirOpcode.SignedRemainder || opcode == WirOpcode.UnsignedRemainder;
            if division { result.integer_division = true; }
            if (opcode == WirOpcode.FloatToUnsignedInt && x86_scalar_size(ref program, instruction.type_id) == 8) {
                result.u64_cast = true;
            }
            if (opcode == WirOpcode.FloatNegate) { result.float_negate = true; }

            let wide_result: Bool = x86_wide_integer(ref program, instruction.type_id);
            let wide_operand: Bool = instruction.operands.length() != 0 &&
                                     x86_wide_integer(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id);
            if ((wide_result && (opcode == WirOpcode.Add || opcode == WirOpcode.Subtract || opcode == WirOpcode.Multiply ||
                 opcode == WirOpcode.BitAnd || opcode == WirOpcode.BitOr || opcode == WirOpcode.BitXor ||
                 opcode == WirOpcode.Negate || opcode == WirOpcode.Not || opcode == WirOpcode.ShiftLeft ||
                 opcode == WirOpcode.SignedShiftRight || opcode == WirOpcode.UnsignedShiftRight || division)) ||
                (wide_operand && x86_comparison_opcode(opcode) != X86Opcode.Invalid)) {
                result.wide_operation = true;
            }

            let edge_index: Int = 0;
            while (edge_index < instruction.edges.length()) {
                if (instruction.edges[edge_index].arguments.length() > result.edge_scratch) {
                    result.edge_scratch = instruction.edges[edge_index].arguments.length();
                }
                edge_index++;
            }

            let required: Int = 0;
            if (opcode == WirOpcode.Call && instruction.call_type != NO_WIR_TYPE) {
                let call_signature: WirType = program.arena.types[wir_id_index(UInt32(instruction.call_type))];
                if (call_signature.kind == WirTypeKind.Function) {
                    required = x86_call_storage(ref program, call_signature, layouts).size;
                    if (required < 0) {
                        let callee_name: String = "indirect call";
                        if (instruction.operands.length() != 0) {
                            let callee: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
                            if (callee.kind == WirValueKind.Function) {
                                callee_name = program.arena.functions[wir_id_index(callee.owner)].name;
                            }
                        }
                        result.message = "cannot plan outgoing storage for '" + callee_name + "'";
                        result.call_frame = -1;
                        return result;
                    }
                }
            } else if (opcode == WirOpcode.Retain || opcode == WirOpcode.Release) {
                required = x86_call_frame(1);
            } else if (opcode == WirOpcode.NullCheck || opcode == WirOpcode.BoundsCheck) {
                required = x86_call_frame(0);
            }
            if (required > result.call_frame) { result.call_frame = required; }

            instruction_index++;
        }
        block_index++;
    }

    return result;
}
