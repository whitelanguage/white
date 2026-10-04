// compiler/machine/x86_64/lowering.wl
import * from "model.wl"
import * from "encoder.wl"
import * from "sse.wl"
import * from "memory.wl"
import * from "abi.wl"
import * from "allocator.wl"
import * from "../../wir/model.wl"
import wir_type_layouts from "../../wir/layout.wl"
import WirReachability, wir_reachable_symbols from "../../wir/reachability.wl"
import x86_emit_globals, x86_address_symbol from "data.wl"


struct X86StackSlot(
    value: WirValueID,
    offset: Int,
    size: Int
)

struct X86StackRegion(
    offset: Int,
    size: Int,
    until: Int
)

struct X86StackIndex(
    base: Int,
    dense_count: Int,
    sparse: Vector(WirValueID),
    offsets: Vector(Int),
    sizes: Vector(Int)
)

struct X86ValueFlags(base: Int, values: Vector(Bool))

struct X86CallStorage(arguments: Vector(Int), result: Int, size: Int)

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

struct X86BlockOffset(
    block: WirBlockID,
    offset: Int
)

struct X86BranchFixup(
    offset: Int,
    target: WirBlockID
)

struct X86CallFixup(
    offset: Int,
    target: WirFuncID
)

struct X86LoweringResult(
    bytes: Vector(Byte),
    errors: Vector(String),
    calls: Vector(X86CallFixup),
    relocations: Vector(X86Relocation)
)

struct X86FunctionCode(
    function: WirFuncID,
    offset: Int,
    bytes: Vector(Byte),
    calls: Vector(X86CallFixup)
)

struct X86ModuleResult(
    bytes: Vector(Byte),
    errors: Vector(String),
    relocations: Vector(X86Relocation),
    symbols: Vector(X86Symbol),
    sections: Vector(X86CodeSection)
)

struct X86BlockState(
    accumulator: WirValueID,
    flags_value: WirValueID,
    flags_opcode: X86Opcode,
    registers: X86RegisterPlan,
    spills: X86SpillPlan,
    stack: X86StackIndex,
    layouts: Vector(WirTypeLayout),
    retain_function: WirFuncID,
    release_function: WirFuncID,
    null_function: WirFuncID,
    bounds_function: WirFuncID,
    return_pointer: Int,
    position: Int,
    message: String
)

struct X86RegisterResult(
    register: X86Register,
    message: String
)

func x86_lowering_error(message: String) -> X86LoweringResult {
    return X86LoweringResult(bytes=[], errors=[message], calls=[], relocations=[]);
}

func x86_module_error(message: String) -> X86ModuleResult {
    return X86ModuleResult(bytes=[], errors=[message], relocations=[], symbols=[], sections=[]);
}

func x86_parameter_index(ref function: WirFunction, value_id: WirValueID) -> Int {
    let i: Int = 0;
    while (i < function.parameters.length()) {
        if (function.parameters[i] == value_id) { return i; }
        i += 1;
    }
    return -1;
}

func x86_find_function(ref program: WirModule, name: String) -> WirFuncID {
    let i: Int = 0;
    while (i < program.arena.functions.length()) {
        if (program.arena.functions[i].name == name) { return WirFuncID(UInt32(i + 1)); }
        i++;
    }
    return NO_WIR_FUNC;
}

func x86_runtime_failure(target: WirFuncID, ref output: X86CodeBuffer, ref calls: Vector(X86CallFixup)) -> Void {
    if (target == NO_WIR_FUNC) {
        x86_trap(ref output);
        return;
    }

    calls.append(X86CallFixup(offset=x86_call_rel32(ref output), target=target));
    x86_trap(ref output);
}

func x86_scalar_size(ref program: WirModule, type_id: WirTypeID) -> Int {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) { return 0; }
    let kind: WirTypeKind = program.arena.types[index].kind;
    let bits: Int = program.arena.types[index].bits;
    if (kind == WirTypeKind.Pointer || kind == WirTypeKind.Function) {
        return 8;
    }
    if (kind == WirTypeKind.BoolType) {
        return 1;
    }
    if (kind == WirTypeKind.FloatType) {
        if (bits == 32) { return 4; }
        if (bits == 64) { return 8; }
        return 0;
    }
    if (kind != WirTypeKind.SignedInt && kind != WirTypeKind.UnsignedInt) {
        return 0;
    }
    if (bits == 8) { return 1; }
    if (bits == 16) { return 2; }
    if (bits == 32) { return 4; }
    if (bits == 64) { return 8; }
    return 0;
}

func x86_scalar_signed(ref program: WirModule, type_id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) { return false; }
    return program.arena.types[index].kind == WirTypeKind.SignedInt;
}

func x86_integer_immediate(value: WirValue, size: Int) -> Bool {
    if (value.kind != WirValueKind.Integer) { return false; }
    if (size <= 4) { return true; }
    // x86-64 sign extends the 32-bit field. Keep negative bit patterns on the
    // register path until WIR has one canonical signed-immediate query.
    return size == 8 && value.integer <= UInt128(2147483647U);
}

func x86_scalar_float(ref program: WirModule, type_id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(type_id));
    return index >= 0 && index < program.arena.types.length() && program.arena.types[index].kind == WirTypeKind.FloatType;
}

func x86_move_scalar(ref output: X86CodeBuffer, destination: X86Register, source: X86Register, size: Int) -> Bool {
    if (x86_is_xmm(destination) && x86_is_xmm(source)) { return x86_sse_register(ref output, 16, destination, source, size); }
    if (x86_is_xmm(destination)) { return x86_sse_bits(ref output, destination, source, size, true); }
    if (x86_is_xmm(source)) { return x86_sse_bits(ref output, source, destination, size, false); }
    if (size == 8) {
        x86_mov_register64(ref output, destination, source);
        return true;
    }
    if (size == 1 || size == 2 || size == 4) {
        x86_mov_register32(ref output, destination, source);
        return true;
    }

    return false;
}

func x86_normalize_scalar(ref output: X86CodeBuffer, register: X86Register, size: Int, signed: Bool) -> Void {
    if (x86_is_xmm(register)) { return; }
    if (size == 1 || size == 2) { x86_extend_register(ref output, register, register, size, signed); }
}

func x86_load_scalar(ref output: X86CodeBuffer, destination: X86Register, base: X86Register, displacement: Int, size: Int, signed: Bool) -> Bool {
    if (x86_is_xmm(destination)) { return x86_sse_memory(ref output, 16, destination, base, displacement, size); }
    if (size != 1 && size != 2 && size != 4 && size != 8) { return false; }
    x86_load_register_base_disp32(ref output, destination, base, displacement, size, signed);
    return true;
}

func x86_store_scalar(ref output: X86CodeBuffer, source: X86Register, base: X86Register, displacement: Int, size: Int) -> Bool {
    if (x86_is_xmm(source)) { return x86_sse_memory(ref output, 17, source, base, displacement, size); }
    if (size != 1 && size != 2 && size != 4 && size != 8) { return false; }
    x86_store_register_base_disp32(ref output, source, base, displacement, size);
    return true;
}

func x86_align_frame_offset(value: Int, alignment: Int) -> Int {
    if (alignment <= 1) {
        return value;
    }

    let remainder: Int = value % alignment;
    if (remainder == 0) {
        return value;
    }

    return value + alignment - remainder;
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

func x86_aggregate_type(ref program: WirModule, type_id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) {
        return false;
    }

    let kind = program.arena.types[index].kind;
    return kind == WirTypeKind.Struct || kind == WirTypeKind.Array;
}

func x86_wide_integer(ref program: WirModule, type_id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) {
        return false;
    }

    let type: WirType = program.arena.types[index];
    return (type.kind == WirTypeKind.SignedInt || type.kind == WirTypeKind.UnsignedInt) && type.bits == 128;
}

func x86_memory_value(ref program: WirModule, type_id: WirTypeID) -> Bool {
    return x86_aggregate_type(ref program, type_id) || x86_wide_integer(ref program, type_id);
}

func x86_abi_size(ref program: WirModule, type_id: WirTypeID, layouts: Vector(WirTypeLayout)) -> Int {
    if (x86_aggregate_type(ref program, type_id)) {
        return x86_win64_aggregate_size(layouts[wir_id_index(UInt32(type_id))]);
    }
    if (x86_wide_integer(ref program, type_id)) {
        return 16;
    }
    return x86_scalar_size(ref program, type_id);
}

func x86_type_layouts(ref program: WirModule) -> Vector(WirTypeLayout) {
    return wir_type_layouts(program);
}

func x86_collect_stack_slots(ref program: WirModule, function: WirFunction, order: Vector(WirBlockID), home_parameters: Bool, cross: X86ValueFlags, layouts: Vector(WirTypeLayout)) -> Vector(X86StackSlot) {
    return x86_stack_slots_with_uses(ref program, function, order, home_parameters, cross, layouts, x86_collect_uses(ref program, order));
}

func x86_stack_slots_with_uses(ref program: WirModule, function: WirFunction, order: Vector(WirBlockID), home_parameters: Bool, cross: X86ValueFlags, layouts: Vector(WirTypeLayout), uses: X86UseTable) -> Vector(X86StackSlot) {
    let slots: Vector(X86StackSlot) = [];
    let regions: Vector(X86StackRegion) = [];
    let offset = 0;
    if home_parameters {
        let param_index = 0;
        while (param_index < function.parameters.length()) {
            let parameter: WirValue = program.arena.values[wir_id_index(UInt32(function.parameters[param_index]))];
            let size: Int = x86_abi_size(ref program, parameter.type_id, layouts);
            let alignment = size;

            if (x86_indirect_argument(ref program, parameter.type_id, layouts)) {
                let layout: WirTypeLayout = layouts[wir_id_index(UInt32(parameter.type_id))];
                if (!layout.valid || layout.size > 2147483632UL) {
                    return [];
                }

                size = Int(layout.size);
                if (size < 8) {
                    size = 8;
                }

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

        let i = 0;
        while (i < block.instructions.length()) {
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
                    if (queue.positions.length() != 0) { last_use = queue.positions[queue.positions.length() - 1]; }
                }

                let selected: Int = -1;
                let selected_size: Int = 2147483647;
                let region_index: Int = 0;
                while (!x86_flag(cross, instruction.result) && region_index < regions.length()) {
                    let region: X86StackRegion = regions[region_index];
                    if (region.until < position && region.size >= size && region.offset % layout.alignment == 0 && region.size < selected_size) {
                        selected = region_index;
                        selected_size = region.size;
                    }
                    region_index++;
                }

                if (selected >= 0) {
                    let region: X86StackRegion = regions[selected];
                    region.until = last_use;
                    regions[selected] = region;
                    slots.append(X86StackSlot(value=instruction.result, offset=region.offset, size=size));
                } else if (!x86_flag(cross, instruction.result)) {
                    if (size > 2147483647 - offset - (layout.alignment - 1)) { return []; }
                    offset = x86_align_frame_offset(offset + size, layout.alignment);
                    regions.append(X86StackRegion(offset=offset, size=size, until=last_use));
                    slots.append(X86StackSlot(value=instruction.result, offset=offset, size=size));
                } else {
                    if (size > 2147483647 - offset - (layout.alignment - 1)) { return []; }
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

        i = 0;
        while (i < block.parameters.length()) {
            let parameter: WirValue = program.arena.values[wir_id_index(UInt32(block.parameters[i]))];
            let size: Int = x86_scalar_size(ref program, parameter.type_id);
            let alignment = size;
            if (x86_memory_value(ref program, parameter.type_id)) {
                let layout = layouts[wir_id_index(UInt32(parameter.type_id))];
                if (!layout.valid || layout.size > 2147483647UL) { return []; }
                size = Int(layout.size);
                if (size == 0) { size = 1; }
                alignment = layout.alignment;
            }
            if (size == 0 || size > 2147483647 - offset - (alignment - 1)) { return []; }
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
    let sparse: Vector(WirValueID) = [];
    let i = 0;
    while (i < range.count) {
        offsets.append(0);
        sizes.append(0);
        i++;
    }
    i = 0;
    while (i < slots.length()) {
        let index: Int = wir_id_index(UInt32(slots[i].value));
        let local: Int = index - range.base;
        if (local < 0 || local >= range.count) {
            local = offsets.length();
            sparse.append(slots[i].value);
            offsets.append(0);
            sizes.append(0);
        }
        offsets[local] = 0 - slots[i].offset;
        sizes[local] = slots[i].size;
        i++;
    }
    return X86StackIndex(base=range.base, dense_count=range.count, sparse=sparse, offsets=offsets, sizes=sizes);
}

func x86_stack_index_of(ref stack: X86StackIndex, value: WirValueID) -> Int {
    let index: Int = wir_id_index(UInt32(value));
    if (index >= stack.base && index < stack.base + stack.dense_count) { return index - stack.base; }
    let i: Int = 0;
    while (i < stack.sparse.length()) {
        if (stack.sparse[i] == value) { return stack.dense_count + i; }
        i++;
    }
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
                        if (!layout.valid || layout.size > 2147483647UL) { return []; }
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
        if (sizes[i] > 2147483647 - offset - (alignments[i] - 1)) { return []; }
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

func x86_indirect_aggregate(ref program: WirModule, type_id: WirTypeID, layouts: Vector(WirTypeLayout)) -> Bool {
    return x86_aggregate_type(ref program, type_id) && x86_abi_size(ref program, type_id, layouts) == 0;
}

func x86_indirect_argument(ref program: WirModule, type_id: WirTypeID, layouts: Vector(WirTypeLayout)) -> Bool {
    return x86_indirect_aggregate(ref program, type_id, layouts) || x86_wide_integer(ref program, type_id);
}

func x86_call_storage(ref program: WirModule, signature: WirType, layouts: Vector(WirTypeLayout)) -> X86CallStorage {
    let hidden: Bool = x86_indirect_aggregate(ref program, signature.result, layouts);
    let count: Int = signature.parameters.length();
    if (hidden) { count++; }
    let size: Int = x86_win64_call_frame(count);
    let arguments: Vector(Int) = [];
    let result = -1;
    let i = 0;
    while (i <= signature.parameters.length()) {
        let type_id: WirTypeID = signature.result;
        let indirect: Bool = hidden;
        if (i < signature.parameters.length()) {
            type_id = signature.parameters[i];
            indirect = x86_indirect_argument(ref program, type_id, layouts);
        }
        let offset = -1;
        if (indirect) {
            let layout: WirTypeLayout = layouts[wir_id_index(UInt32(type_id))];
            if (!layout.valid || layout.size > 2147483632UL || Int(layout.size) > 2147483632 - size) {
                return X86CallStorage(arguments=[], result=-1, size=-1);
            }
            offset = size;
            let extent = Int(layout.size);
            if (extent == 0) { extent = 1; }
            size = x86_align_frame_offset(size + extent, 16);
        }
        if (i < signature.parameters.length()) { arguments.append(offset); }
        else { result = offset; }
        i++;
    }
    return X86CallStorage(arguments=arguments, result=result, size=size);
}

func x86_analyze_function(ref program: WirModule, function_id: WirFuncID, function: WirFunction, order: Vector(WirBlockID), layouts: Vector(WirTypeLayout)) -> X86FunctionAnalysis {
    // collect frame requirements together. These queries used to walk the
    // same instruction list separately before register allocation could start.
    let result = X86FunctionAnalysis(message="", located_values=0, edge_scratch=0, home_parameters=false, has_float=false, integer_division=false, u64_cast=false, float_negate=false, wide_operation=false, call_frame=0);
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    result.has_float = x86_scalar_float(ref program, signature.result);

    let i: Int = 0;
    while (i < function.parameters.length()) {
        let parameter: WirValue = program.arena.values[wir_id_index(UInt32(function.parameters[i]))];
        if (x86_memory_value(ref program, parameter.type_id)) {
            result.home_parameters = true;
        }
        if (x86_scalar_float(ref program, parameter.type_id)) {
            result.has_float = true;
        }
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
            if (x86_memory_value(ref program, parameter.type_id)) {
                result.home_parameters = true;
            }
            i++;
        }

        let instruction_index: Int = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];
            let opcode: WirOpcode = instruction.opcode;
            if (opcode == WirOpcode.StackAlloc) {
                result.located_values++;
            }

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

            if (x86_scalar_float(ref program, instruction.type_id)) {
                result.has_float = true;
            }
            let operand_index: Int = 0;
            while (operand_index < instruction.operands.length()) {
                let operand: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[operand_index]))];
                if (x86_scalar_float(ref program, operand.type_id)) {
                    result.has_float = true;
                }
                operand_index++;
            }

            let division: Bool = opcode == WirOpcode.SignedDivide || opcode == WirOpcode.UnsignedDivide ||
                                 opcode == WirOpcode.SignedRemainder || opcode == WirOpcode.UnsignedRemainder;
            if (division) {
                result.integer_division = true;
            }
            if (opcode == WirOpcode.FloatToUnsignedInt && x86_scalar_size(ref program, instruction.type_id) == 8) {
                result.u64_cast = true;
            }
            if (opcode == WirOpcode.FloatNegate) {
                result.float_negate = true;
            }

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
                        result.call_frame = -1;
                        return result;
                    }
                }
            } else if (opcode == WirOpcode.Retain || opcode == WirOpcode.Release) {
                required = x86_win64_call_frame(1);
            } else if (opcode == WirOpcode.NullCheck || opcode == WirOpcode.BoundsCheck) {
                required = x86_win64_call_frame(0);
            }
            if (required > result.call_frame) {
                result.call_frame = required;
            }

            instruction_index++;
        }
        block_index++;
    }

    return result;
}

func x86_home_parameters(ref program: WirModule, function: WirFunction, stack: X86StackIndex, layouts: Vector(WirTypeLayout), ref output: X86CodeBuffer) -> Bool {
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    let shift = 0;
    if (x86_indirect_aggregate(ref program, signature.result, layouts)) { shift = 1; }
    let parameter_index: Int = 0;
    while (parameter_index < function.parameters.length()) {
        let parameter: WirValue = program.arena.values[wir_id_index(UInt32(function.parameters[parameter_index]))];
        let size: Int = x86_abi_size(ref program, parameter.type_id, layouts);
        if (x86_indirect_argument(ref program, parameter.type_id, layouts)) { size = 8; }
        let offset: Int = x86_stack_offset(ref stack, function.parameters[parameter_index]);
        if (offset == 0 || size == 0) {
            return false;
        }

        let position: Int = parameter_index + shift;
        if (position < 4) {
            let incoming: X86Register = x86_win64_argument_register(position, x86_scalar_float(ref program, parameter.type_id));
            if (incoming == X86Register.None) {
                return false;
            }
            if (!x86_store_scalar(ref output, incoming, X86Register.RBP, offset, size)) {
                return false;
            }
        } else {
            let incoming_offset: Int = x86_win64_stack_param_offset(position);
            if (incoming_offset < 0) {
                return false;
            }
            if (!x86_load_scalar(ref output, X86Register.RAX, X86Register.RBP, incoming_offset, size, x86_scalar_signed(ref program, parameter.type_id))) {
                return false;
            }
            if (!x86_store_scalar(ref output, X86Register.RAX, X86Register.RBP, offset, size)) {
                return false;
            }
        }
        parameter_index += 1;
    }
    // save every incoming register before the copy loop borrows RCX
    parameter_index = 0;
    while (parameter_index < function.parameters.length()) {
        let parameter: WirValue = program.arena.values[wir_id_index(UInt32(function.parameters[parameter_index]))];
        if (x86_indirect_argument(ref program, parameter.type_id, layouts)) {
            let offset = x86_stack_offset(ref stack, function.parameters[parameter_index]);
            let layout: WirTypeLayout = layouts[wir_id_index(UInt32(parameter.type_id))];
            x86_load_scalar(ref output, X86Register.R10, X86Register.RBP, offset, 8, false);
            if (!x86_copy_memory(ref output, X86Register.RBP, offset, X86Register.R10, 0, Int(layout.size), X86Register.RAX)) { return false; }
        }
        parameter_index++;
    }
    return true;
}

func x86_save_live_registers(ref program: WirModule, slots: Vector(X86StackSlot), operands: Vector(WirValueID), ref state: X86BlockState, ref output: X86CodeBuffer) -> String {
    let i: Int = 0;
    while (i < state.registers.bindings.length()) {
        let binding: X86RegisterBinding = state.registers.bindings[i];
        let needed: Bool = x86_next_use(ref state.registers.uses, binding.value, state.position) != X86_NO_NEXT_USE;
        let operand_index: Int = 0;
        while (binding.value != NO_WIR_VALUE && !needed && operand_index < operands.length()) {
            needed = operands[operand_index] == binding.value;
            operand_index++;
        }
        // argument setup may reuse scratch registers before all operands are read
        if (binding.value != NO_WIR_VALUE && needed) {
            if (x86_rematerializable(ref program, binding.value) || x86_stack_offset(ref state.stack, binding.value) != 0) {
                x86_clear_register(ref state.registers, binding.register);
            } else {
                let offset: Int = x86_claim_spill(ref state.spills, binding.value);
                if (offset == 0) { return "x86_64 spill storage is exhausted before a call"; }
                let value: WirValue = program.arena.values[wir_id_index(UInt32(binding.value))];
                let size: Int = x86_scalar_size(ref program, value.type_id);
                if (size == 0 || !x86_store_scalar(ref output, binding.register, X86Register.RBP, offset, size)) { return "x86_64 cannot spill this value before a call"; }
                x86_clear_register(ref state.registers, binding.register);
            }
        }
        i += 1;
    }

    return "";
}

func x86_claim_register_spill(ref state: X86BlockState, value: WirValueID) -> Int {
    let offset: Int = x86_claim_spill(ref state.spills, value);
    if (offset != 0) {
        return offset;
    }

    // a reloaded SSA value can keep its old spill copy until another value needs the slot
    let i = 0;
    while (i < state.spills.bindings.length()) {
        let binding = state.spills.bindings[i];
        if (binding.value != value && x86_register_for(ref state.registers, binding.value) != X86Register.None) {
            x86_forget_spill_value(ref state.spills, binding.value);
            return x86_claim_spill(ref state.spills, value);
        }
        i++;
    }
    return 0;
}

func x86_prepare_register(ref program: WirModule, ref state: X86BlockState, choice: X86RegisterChoice, ref output: X86CodeBuffer) -> String {
    if (choice.register == X86Register.None) { return "no x86_64 register is available for this value"; }
    if (choice.evicted == NO_WIR_VALUE) { return ""; }

    let next_use: Int = x86_pending_use(ref state.registers.uses, choice.evicted, state.position);
    if (next_use == X86_NO_NEXT_USE || x86_rematerializable(ref program, choice.evicted) || x86_stack_offset(ref state.stack, choice.evicted) != 0) {
        x86_clear_register(ref state.registers, choice.register);
        return "";
    }

    if (x86_spill_offset(ref state.spills, choice.evicted) != 0) {
        x86_clear_register(ref state.registers, choice.register);
        return "";
    }

    let offset: Int = x86_claim_register_spill(ref state, choice.evicted);
    if (offset == 0) {
        return "x86_64 spill storage is exhausted";
    }

    let value: WirValue = program.arena.values[wir_id_index(UInt32(choice.evicted))];
    let size: Int = x86_scalar_size(ref program, value.type_id);
    if (size == 0 || !x86_store_scalar(ref output, choice.register, X86Register.RBP, offset, size)) {
        return "x86_64 cannot spill this value";
    }
    x86_clear_register(ref state.registers, choice.register);

    return "";
}

func x86_bound_value(plan: X86RegisterPlan, register: X86Register) -> WirValueID {
    let i: Int = 0;
    while (i < plan.bindings.length()) {
        if (plan.bindings[i].register == register) { return plan.bindings[i].value; }
        i += 1;
    }
    return NO_WIR_VALUE;
}

func x86_prepare_fixed_register(ref program: WirModule, ref state: X86BlockState, register: X86Register, ref output: X86CodeBuffer) -> String {
    return x86_prepare_register(ref program, ref state, X86RegisterChoice(register=register, evicted=x86_bound_value(state.registers, register)), ref output);
}

func x86_overwrite_operand(ref program: WirModule, ref state: X86BlockState, register: X86Register, ref output: X86CodeBuffer) -> String {
    // the in-place operand is already available; preserve it only for later uses
    let value: WirValueID = x86_bound_value(state.registers, register);
    if (x86_next_use(ref state.registers.uses, value, state.position) == X86_NO_NEXT_USE) {
        x86_clear_register(ref state.registers, register);
        return "";
    }
    return x86_prepare_fixed_register(ref program, ref state, register, ref output);
}

func x86_materialize_register_except(ref program: WirModule, ref function: WirFunction, value_id: WirValueID, slots: Vector(X86StackSlot), ref state: X86BlockState, avoid: X86Register, ref output: X86CodeBuffer) -> X86RegisterResult {
    let allocated: X86Register = x86_register_for(ref state.registers, value_id);
    if (allocated != X86Register.None) {
        return X86RegisterResult(register=allocated, message="");
    }

    let value: WirValue = program.arena.values[wir_id_index(UInt32(value_id))];
    let floating: Bool = x86_scalar_float(ref program, value.type_id);
    let choice: X86RegisterChoice = x86_choose_register_class(ref program, ref state.registers, state.position, avoid, floating);
    let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
    if (prepare_error.length() != 0) {
        return X86RegisterResult(register=X86Register.None, message=prepare_error);
    }

    let size: Int = x86_scalar_size(ref program, value.type_id);
    if (size == 0) { return X86RegisterResult(register=X86Register.None, message="the x86_64 allocator cannot materialize this value type"); }
    let signed: Bool = x86_scalar_signed(ref program, value.type_id);
    let home: Int = x86_stack_offset(ref state.stack, value_id);
    let spill: Int = x86_spill_offset(ref state.spills, value_id);
    if (home != 0 && !x86_rematerializable(ref program, value_id)) {
        x86_load_scalar(ref output, choice.register, X86Register.RBP, home, size, signed);
    } else if (spill != 0) {
        x86_load_scalar(ref output, choice.register, X86Register.RBP, spill, size, signed);
    } else if (value.kind == WirValueKind.FloatValue || (floating && value.kind == WirValueKind.Constant && program.arena.constants[wir_id_index(value.owner)].kind == WirConstKind.Zero)) {
        let bits: UInt64 = value.float_bits;
        if (value.kind == WirValueKind.Constant) { bits = 0UL; }
        let integer: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, avoid);
        let integer_error: String = x86_prepare_register(ref program, ref state, integer, ref output);
        if (integer_error.length() != 0) { return X86RegisterResult(register=X86Register.None, message=integer_error); }
        if (size == 8) { x86_mov_register_imm64(ref output, integer.register, bits); }
        else { x86_mov_register_imm32(ref output, integer.register, UInt32(bits)); }
        x86_move_scalar(ref output, choice.register, integer.register, size);
    } else if (value.kind == WirValueKind.Integer) {
        if (size == 8) {
            x86_mov_register_imm64(ref output, choice.register, UInt64(value.integer));
        } else {
            x86_mov_register_imm32(ref output, choice.register, UInt32(value.integer));
        }

        x86_normalize_scalar(ref output, choice.register, size, signed);
    } else if (value.kind == WirValueKind.BoolValue || value.kind == WirValueKind.Null) {
        x86_mov_register_imm32(ref output, choice.register, UInt32(value.integer));
    } else if (value.kind == WirValueKind.Global || value.kind == WirValueKind.Function) {
        if (!x86_lea_symbol(ref output, choice.register, x86_address_symbol(ref program, value_id), 0L)) {
            return X86RegisterResult(register=X86Register.None, message="value has no linkable address symbol");
        }
    } else if (value.kind == WirValueKind.Constant) {
        let constant: WirConstant = program.arena.constants[wir_id_index(value.owner)];
        if (constant.kind == WirConstKind.Zero) {
            x86_mov_register_imm32(ref output, choice.register, 0U);
        } else if (constant.kind == WirConstKind.Address) {
            if (!x86_lea_symbol(ref output, choice.register, x86_address_symbol(ref program, constant.target), constant.addend)) {
                return X86RegisterResult(register=X86Register.None, message="address constant exceeds the x86_64 RIP-relative displacement range");
            }
        } else {
            return X86RegisterResult(register=X86Register.None, message="aggregate constants cannot be materialized in an integer register");
        }
    } else if (value.kind == WirValueKind.Instruction && x86_rematerializable(ref program, value_id)) {
        let offset: Int = x86_stack_offset(ref state.stack, value_id);
        if (offset == 0 || !x86_lea(ref output, choice.register, X86Register.RBP, X86Register.None, 1, offset)) {
            return X86RegisterResult(register=X86Register.None, message="stack allocation has no addressable storage");
        }
    } else if (value.kind == WirValueKind.FunctionParameter) {
        let saved_offset: Int = x86_stack_offset(ref state.stack, value_id);
        if (saved_offset != 0) {
            x86_load_scalar(ref output, choice.register, X86Register.RBP, saved_offset, size, signed);
            x86_bind_register(ref state.registers, choice.register, value_id);

            return X86RegisterResult(register=choice.register, message="");
        }
        let index: Int = x86_parameter_index(ref function, value_id);
        if (index < 4) {
            let incoming: X86Register = x86_win64_argument_register(index, floating);
            if (incoming == X86Register.None) {
                return X86RegisterResult(register=X86Register.None, message="the x86_64 ABI has no register for this function parameter");
            }

            x86_move_scalar(ref output, choice.register, incoming, size);
            x86_normalize_scalar(ref output, choice.register, size, signed);
        } else {
            let incoming_offset: Int = x86_win64_stack_param_offset(index);
            if (incoming_offset < 0) {
                return X86RegisterResult(register=X86Register.None, message="the x86_64 ABI has no stack location for this function parameter");
            }

            x86_load_scalar(ref output, choice.register, X86Register.RBP, incoming_offset, size, signed);
        }
    } else if (value.kind == WirValueKind.BlockParameter) {
        let offset: Int = x86_stack_offset(ref state.stack, value_id);
        if (offset == 0) {
            return X86RegisterResult(register=X86Register.None, message="block parameter has no assigned stack location");
        }

        x86_load_scalar(ref output, choice.register, X86Register.RBP, offset, size, signed);
    } else {
        return X86RegisterResult(register=X86Register.None, message="the x86_64 allocator cannot restore value %" + UInt32(value_id));
    }

    x86_bind_register(ref state.registers, choice.register, value_id);
    return X86RegisterResult(register=choice.register, message="");
}

func x86_materialize_register(ref program: WirModule, ref function: WirFunction, value_id: WirValueID, slots: Vector(X86StackSlot), ref state: X86BlockState, ref output: X86CodeBuffer) -> X86RegisterResult {
    return x86_materialize_register_except(ref program, ref function, value_id, slots, ref state, X86Register.None, ref output);
}

func x86_comparison_opcode(opcode: WirOpcode) -> X86Opcode {
    if (opcode == WirOpcode.Equal) { return X86Opcode.Je; }
    if (opcode == WirOpcode.NotEqual) { return X86Opcode.Jne; }
    if (opcode == WirOpcode.SignedLess) { return X86Opcode.Jl; }
    if (opcode == WirOpcode.SignedLessEqual) { return X86Opcode.Jle; }
    if (opcode == WirOpcode.SignedGreater) { return X86Opcode.Jg; }
    if (opcode == WirOpcode.SignedGreaterEqual) { return X86Opcode.Jge; }
    if (opcode == WirOpcode.UnsignedLess) { return X86Opcode.Jb; }
    if (opcode == WirOpcode.UnsignedLessEqual) { return X86Opcode.Jbe; }
    if (opcode == WirOpcode.UnsignedGreater) { return X86Opcode.Ja; }
    if (opcode == WirOpcode.UnsignedGreaterEqual) { return X86Opcode.Jae; }
    return X86Opcode.Invalid;
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
        if (target < 0) {
            return false;
        }

        let displacement: Int = target - (fixups[i].offset + 4);
        if (displacement < -2147483648 || displacement > 2147483647) {
            return false;
        }

        if (!x86_patch_i32(ref output, fixups[i].offset, displacement)) {
            return false;
        }

        i++;
    }

    return true;
}

func x86_patch_calls(ref program: WirModule, ref output: X86CodeBuffer, codes: Vector(X86FunctionCode)) -> Bool {
    let offsets: Vector(Int) = [];
    let i: Int = 0;
    while (i < program.arena.functions.length()) {
        offsets.append(-1);
        i++;
    }
    i = 0;
    while (i < codes.length()) {
        offsets[wir_id_index(UInt32(codes[i].function))] = codes[i].offset;
        i++;
    }

    let code_index: Int = 0;
    while (code_index < codes.length()) {
        let code: X86FunctionCode = codes[code_index];

        let call_index: Int = 0;
        while (call_index < code.calls.length()) {
            let call: X86CallFixup = code.calls[call_index];
            let target_index: Int = wir_id_index(UInt32(call.target));
            if (target_index < 0 || target_index >= program.arena.functions.length()) {
                return false;
            }
            if (program.arena.functions[target_index].linkage == WirLinkage.External) {
                call_index += 1;
                continue;
            }
            let target_offset: Int = offsets[target_index];
            if (target_offset < 0) {
                return false;
            }

            let patch_offset: Int = code.offset + call.offset;
            let displacement: Int = target_offset - (patch_offset + 4);
            if (displacement < -2147483648 || displacement > 2147483647) {
                return false;
            }

            if (!x86_patch_i32(ref output, patch_offset, displacement)) {
                return false;
            }

            call_index++;
        }

        code_index++;
    }

    return true;
}

func x86_emit_edge_moves(ref program: WirModule, ref function: WirFunction, edge: WirEdge, slots: Vector(X86StackSlot), scratch: Vector(Int), state: X86BlockState, ref output: X86CodeBuffer) -> String {
    let target_index: Int = wir_id_index(UInt32(edge.target));
    if (target_index < 0 || target_index >= program.arena.blocks.length()) {
        return "edge refers to an unknown basic block";
    }

    let target: WirBlock = program.arena.blocks[target_index];
    if (target.parameters.length() != edge.arguments.length()) {
        return "edge argument count does not match the target block";
    }

    if (edge.arguments.length() > scratch.length()) {
        return "edge transfer exceeds the reserved scratch area";
    }
    if (edge.arguments.length() == 0) {
        return "";
    }

    // both arms start with the same bindings. A spill made in one arm does not
    // magically exist when lowering the other arm.
    let registers: Vector(X86RegisterBinding) = [];
    let binding_index = 0;
    while (binding_index < state.registers.bindings.length()) {
        registers.append(state.registers.bindings[binding_index]);
        binding_index++;
    }
    state.registers = X86RegisterPlan(uses=state.registers.uses, bindings=registers);
    state.spills = x86_copy_spill_plan(ref state.spills);

    // read every source first, writing a target early breaks swaps and loop values
    let i = 0;
    while (i < edge.arguments.length()) {
        let message = x86_store_value(ref program, ref function, edge.arguments[i], X86Register.RBP, scratch[i], slots, ref state, ref output);
        if (message.length() != 0) { return message; }
        i++;
    }

    i = 0;
    while (i < target.parameters.length()) {
        let offset: Int = x86_stack_offset(ref state.stack, target.parameters[i]);
        if (offset == 0) {
            return "target block parameter has no assigned location";
        }

        let target_value: WirValue = program.arena.values[wir_id_index(UInt32(target.parameters[i]))];
        let size: Int = x86_scalar_size(ref program, target_value.type_id);
        if (x86_memory_value(ref program, target_value.type_id)) {
            let layout = state.layouts[wir_id_index(UInt32(target_value.type_id))];
            if (!x86_copy_memory(ref output, X86Register.RBP, offset, X86Register.RBP, scratch[i], Int(layout.size), X86Register.RAX)) {
                return "cannot copy aggregate block parameter";
            }
        } else {
            if (size == 0) { return "target block parameter is not a supported scalar value"; }
            x86_load_scalar(ref output, X86Register.RAX, X86Register.RBP, scratch[i], size, x86_scalar_signed(ref program, target_value.type_id));
            x86_store_scalar(ref output, X86Register.RAX, X86Register.RBP, offset, size);
        }
        i++;
    }
    return "";
}

func x86_store_value(ref program: WirModule, ref function: WirFunction, value_id: WirValueID, base: X86Register, offset: Int, slots: Vector(X86StackSlot), ref state: X86BlockState, ref output: X86CodeBuffer) -> String {
    let value: WirValue = program.arena.values[wir_id_index(UInt32(value_id))];
    if (!x86_memory_value(ref program, value.type_id)) {
        let stored: X86RegisterResult = x86_materialize_register_except(ref program, ref function, value_id, slots, ref state, base, ref output);
        if (stored.message.length() != 0) { return stored.message; }
        if (!x86_store_scalar(ref output, stored.register, base, offset, x86_scalar_size(ref program, value.type_id))) { return "unsupported aggregate member type"; }
        return "";
    }
    let layout: WirTypeLayout = state.layouts[wir_id_index(UInt32(value.type_id))];
    if (!layout.valid || layout.size > 2147483647UL) { return "aggregate has no addressable layout"; }
    let temporary: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, base);
    let prepare_error = x86_prepare_register(ref program, ref state, temporary, ref output);
    if (prepare_error.length() != 0) { return prepare_error; }
    let home = x86_stack_offset(ref state.stack, value_id);
    if (home != 0) {
        if (!x86_copy_memory(ref output, base, offset, X86Register.RBP, home, Int(layout.size), temporary.register)) { return "cannot encode aggregate copy"; }
    } else if (x86_wide_integer(ref program, value.type_id) && value.kind == WirValueKind.Integer) {
        x86_mov_register_imm64(ref output, temporary.register, UInt64(value.integer & UInt128(18446744073709551615UL)));
        x86_store_scalar(ref output, temporary.register, base, offset, 8);
        x86_mov_register_imm64(ref output, temporary.register, UInt64(value.integer >> UInt128(64U)));
        x86_store_scalar(ref output, temporary.register, base, offset + 8, 8);
    } else if (value.kind == WirValueKind.Constant && program.arena.constants[wir_id_index(value.owner)].kind == WirConstKind.Zero) {
        if (!x86_zero_memory(ref output, base, offset, Int(layout.size), temporary.register)) { return "cannot encode aggregate zero initialization"; }
    } else {
        return "aggregate value has no storage in the machine lowering";
    }
    return "";
}

func x86_materialize_abi_value(ref program: WirModule, ref function: WirFunction, value_id: WirValueID, slots: Vector(X86StackSlot), ref state: X86BlockState, ref output: X86CodeBuffer) -> X86RegisterResult {
    let value = program.arena.values[wir_id_index(UInt32(value_id))];
    if (!x86_aggregate_type(ref program, value.type_id)) { return x86_materialize_register(ref program, ref function, value_id, slots, ref state, ref output); }
    let size = x86_abi_size(ref program, value.type_id, state.layouts);
    if (size == 0) { return X86RegisterResult(register=X86Register.None, message="indirect aggregate arguments are not implemented in the machine backend"); }
    let choice: X86RegisterChoice = x86_choose_register(ref program, ref state.registers, state.position);
    let message = x86_prepare_register(ref program, ref state, choice, ref output);
    if (message.length() != 0) { return X86RegisterResult(register=X86Register.None, message=message); }
    let home = x86_stack_offset(ref state.stack, value_id);
    if (home != 0) {
        x86_load_scalar(ref output, choice.register, X86Register.RBP, home, size, false);
    } else if (value.kind == WirValueKind.Constant && program.arena.constants[wir_id_index(value.owner)].kind == WirConstKind.Zero) {
        x86_mov_register_imm32(ref output, choice.register, 0U);
    } else {
        return X86RegisterResult(register=X86Register.None, message="aggregate ABI operand has no storage");
    }
    // this is a transient bit-pattern load, not a scalar binding for the aggregate SSA value
    return X86RegisterResult(register=choice.register, message="");
}

func x86_load_wide_half(ref program: WirModule, value_id: WirValueID, high: Bool, destination: X86Register, ref state: X86BlockState, ref output: X86CodeBuffer) -> String {
    let value: WirValue = program.arena.values[wir_id_index(UInt32(value_id))];
    if (!x86_wide_integer(ref program, value.type_id)) { return "value is not a 128-bit integer"; }
    let offset = x86_stack_offset(ref state.stack, value_id);
    if (offset != 0) {
        if (high) { offset += 8; }
        if (!x86_load_scalar(ref output, destination, X86Register.RBP, offset, 8, false)) { return "cannot load a 128-bit integer half"; }
        return "";
    }
    if (value.kind == WirValueKind.Integer) {
        let bits: UInt64 = UInt64(value.integer & UInt128(18446744073709551615UL));
        if (high) { bits = UInt64(value.integer >> UInt128(64U)); }
        x86_mov_register_imm64(ref output, destination, bits);
        return "";
    }
    if (value.kind == WirValueKind.Constant && program.arena.constants[wir_id_index(value.owner)].kind == WirConstKind.Zero) {
        x86_mov_register_imm32(ref output, destination, 0U);
        return "";
    }
    return "128-bit integer value has no storage";
}

func x86_store_wide_pair(value_id: WirValueID, low: X86Register, high: X86Register, ref state: X86BlockState, ref output: X86CodeBuffer) -> Bool {
    let offset = x86_stack_offset(ref state.stack, value_id);
    if (offset == 0) { return false; }
    return x86_store_scalar(ref output, low, X86Register.RBP, offset, 8) &&
           x86_store_scalar(ref output, high, X86Register.RBP, offset + 8, 8);
}

func x86_prepare_wide_scratch(ref program: WirModule, ref state: X86BlockState, ref output: X86CodeBuffer) -> String {
    let message = x86_prepare_fixed_register(ref program, ref state, X86Register.RAX, ref output);
    if (message.length() != 0) { return message; }
    message = x86_prepare_fixed_register(ref program, ref state, X86Register.R10, ref output);
    if (message.length() != 0) { return message; }
    return x86_prepare_fixed_register(ref program, ref state, X86Register.R11, ref output);
}

func x86_shift_wide_immediate(ref output: X86CodeBuffer, opcode: WirOpcode, amount: Int) -> Void {
    amount &= 127;
    if (amount < 64) {
        if (opcode == WirOpcode.ShiftLeft) {
            x86_shift_double_imm8(ref output, X86Register.R10, X86Register.RAX, Byte(amount), true);
            x86_shift_register_imm8(ref output, X86Register.RAX, Byte(amount), 4, true);
        } else {
            x86_shift_double_imm8(ref output, X86Register.RAX, X86Register.R10, Byte(amount), false);
            let group: Int = 5;
            if (opcode == WirOpcode.SignedShiftRight) { group = 7; }
            x86_shift_register_imm8(ref output, X86Register.R10, Byte(amount), group, true);
        }
        return;
    }
    let remaining: Byte = Byte(amount - 64);
    if (opcode == WirOpcode.ShiftLeft) {
        x86_mov_register64(ref output, X86Register.R10, X86Register.RAX);
        x86_shift_register_imm8(ref output, X86Register.R10, remaining, 4, true);
        x86_mov_register_imm32(ref output, X86Register.RAX, 0U);
    } else {
        x86_mov_register64(ref output, X86Register.RAX, X86Register.R10);
        let group: Int = 5;
        if (opcode == WirOpcode.SignedShiftRight) { group = 7; }
        x86_shift_register_imm8(ref output, X86Register.RAX, remaining, group, true);
        if (opcode == WirOpcode.SignedShiftRight) { x86_shift_register_imm8(ref output, X86Register.R10, Byte(63), 7, true); }
        else { x86_mov_register_imm32(ref output, X86Register.R10, 0U); }
    }
}

func x86_shift_wide_variable(ref output: X86CodeBuffer, opcode: WirOpcode) -> Bool {
    x86_bitwise_register_imm32(ref output, X86Register.RCX, 127U, 4);
    x86_test_register_width(ref output, X86Register.RCX, X86Register.RCX, true);
    let zero: Int = x86_jump_if_rel32(ref output, X86Opcode.Je);
    x86_mov_register64(ref output, X86Register.R11, X86Register.RCX);
    x86_bitwise_register_imm32(ref output, X86Register.R11, 64U, 4);
    x86_test_register_width(ref output, X86Register.R11, X86Register.R11, true);
    let large: Int = x86_jump_if_rel32(ref output, X86Opcode.Jne);
    if (opcode == WirOpcode.ShiftLeft) {
        x86_shift_double_cl(ref output, X86Register.R10, X86Register.RAX, true);
        x86_shift_register_cl(ref output, X86Register.RAX, 4, true);
    } else {
        x86_shift_double_cl(ref output, X86Register.RAX, X86Register.R10, false);
        let group: Int = 5;
        if (opcode == WirOpcode.SignedShiftRight) { group = 7; }
        x86_shift_register_cl(ref output, X86Register.R10, group, true);
    }
    let done: Int = x86_jump_rel32(ref output);
    if (!x86_patch_i32(ref output, large, output.bytes.length() - (large + 4))) { return false; }
    if (opcode == WirOpcode.ShiftLeft) {
        x86_mov_register64(ref output, X86Register.R10, X86Register.RAX);
        x86_shift_register_cl(ref output, X86Register.R10, 4, true);
        x86_mov_register_imm32(ref output, X86Register.RAX, 0U);
    } else {
        x86_mov_register64(ref output, X86Register.RAX, X86Register.R10);
        let group: Int = 5;
        if (opcode == WirOpcode.SignedShiftRight) { group = 7; }
        x86_shift_register_cl(ref output, X86Register.RAX, group, true);
        if (opcode == WirOpcode.SignedShiftRight) { x86_shift_register_imm8(ref output, X86Register.R10, Byte(63), 7, true); }
        else { x86_mov_register_imm32(ref output, X86Register.R10, 0U); }
    }
    if (!x86_patch_i32(ref output, done, output.bytes.length() - (done + 4))) { return false; }
    return x86_patch_i32(ref output, zero, output.bytes.length() - (zero + 4));
}

func x86_wide_low_comparison(opcode: WirOpcode) -> X86Opcode {
    if (opcode == WirOpcode.SignedLess || opcode == WirOpcode.UnsignedLess) { return X86Opcode.Jb; }
    if (opcode == WirOpcode.SignedLessEqual || opcode == WirOpcode.UnsignedLessEqual) { return X86Opcode.Jbe; }
    if (opcode == WirOpcode.SignedGreater || opcode == WirOpcode.UnsignedGreater) { return X86Opcode.Ja; }
    if (opcode == WirOpcode.SignedGreaterEqual || opcode == WirOpcode.UnsignedGreaterEqual) { return X86Opcode.Jae; }
    return X86Opcode.Invalid;
}

func x86_wide_high_comparison(opcode: WirOpcode) -> X86Opcode {
    if (opcode == WirOpcode.SignedLess || opcode == WirOpcode.SignedLessEqual) { return X86Opcode.Jl; }
    if (opcode == WirOpcode.SignedGreater || opcode == WirOpcode.SignedGreaterEqual) { return X86Opcode.Jg; }
    if (opcode == WirOpcode.UnsignedLess || opcode == WirOpcode.UnsignedLessEqual) { return X86Opcode.Jb; }
    if (opcode == WirOpcode.UnsignedGreater || opcode == WirOpcode.UnsignedGreaterEqual) { return X86Opcode.Ja; }
    return X86Opcode.Invalid;
}

func x86_divide_wide_unsigned(ref output: X86CodeBuffer) -> Bool {
    // the 64-bit divisor path uses two hardware divisions; the general path
    // keeps the loop in emitted code instead of unrolling 128 quotient bits
    x86_test_register_width(ref output, X86Register.R9, X86Register.R9, true);
    let general: Int = x86_jump_if_rel32(ref output, X86Opcode.Jne);
    x86_mov_register64(ref output, X86Register.R8, X86Register.RAX);
    x86_mov_register64(ref output, X86Register.RAX, X86Register.R10);
    x86_mov_register_imm32(ref output, X86Register.RDX, 0U);
    x86_div_register_width(ref output, X86Register.R11, true, false);
    x86_mov_register64(ref output, X86Register.R10, X86Register.RAX);
    x86_mov_register64(ref output, X86Register.RAX, X86Register.R8);
    x86_div_register_width(ref output, X86Register.R11, true, false);
    x86_mov_register_imm32(ref output, X86Register.R8, 0U);
    let done: Int = x86_jump_rel32(ref output);

    if (!x86_patch_i32(ref output, general, output.bytes.length() - (general + 4))) { return false; }
    x86_mov_register_imm32(ref output, X86Register.RDX, 0U);
    x86_mov_register_imm32(ref output, X86Register.R8, 0U);
    x86_mov_register_imm32(ref output, X86Register.RCX, 128U);
    let loop: Int = output.bytes.length();
    x86_shift_register_imm8(ref output, X86Register.RAX, Byte(1), 4, true);
    x86_shift_register_imm8(ref output, X86Register.R10, Byte(1), 2, true);
    x86_shift_register_imm8(ref output, X86Register.RDX, Byte(1), 2, true);
    x86_shift_register_imm8(ref output, X86Register.R8, Byte(1), 2, true);
    x86_cmp_register64(ref output, X86Register.R8, X86Register.R9);
    let subtract_high: Int = x86_jump_if_rel32(ref output, X86Opcode.Ja);
    let skip_high: Int = x86_jump_if_rel32(ref output, X86Opcode.Jb);
    x86_cmp_register64(ref output, X86Register.RDX, X86Register.R11);
    let skip_low: Int = x86_jump_if_rel32(ref output, X86Opcode.Jb);
    if (!x86_patch_i32(ref output, subtract_high, output.bytes.length() - (subtract_high + 4))) { return false; }
    x86_sub_register64(ref output, X86Register.RDX, X86Register.R11);
    x86_sbb_register64(ref output, X86Register.R8, X86Register.R9);
    x86_bitwise_register_imm32(ref output, X86Register.RAX, 1U, 1);
    let next: Int = output.bytes.length();
    if (!x86_patch_i32(ref output, skip_high, next - (skip_high + 4)) ||
        !x86_patch_i32(ref output, skip_low, next - (skip_low + 4))) { return false; }
    x86_sub_register_imm32(ref output, X86Register.RCX, 1U);
    let repeat: Int = x86_jump_if_rel32(ref output, X86Opcode.Jne);
    if (!x86_patch_i32(ref output, repeat, loop - (repeat + 4))) { return false; }
    return x86_patch_i32(ref output, done, output.bytes.length() - (done + 4));
}

func x86_apply_wide_sign(ref output: X86CodeBuffer, low: X86Register, high: X86Register, mask: X86Register) -> Void {
    x86_xor_register_width(ref output, low, mask, true);
    x86_xor_register_width(ref output, high, mask, true);
    x86_sub_register64(ref output, low, mask);
    x86_sbb_register64(ref output, high, mask);
}

func x86_lower_instruction(ref program: WirModule,
                           ref function: WirFunction,
                           ref instruction: WirInstruction, slots: Vector(X86StackSlot),
                           scratch: Vector(Int), frame_size: Int, 
                           ref state: X86BlockState,
                           ref output: X86CodeBuffer, 
                           ref fixups: Vector(X86BranchFixup), 
                           ref calls: Vector(X86CallFixup)
                        ) -> String {

    // only an immediately preceding comparison may supply branch flags
    if (instruction.opcode != WirOpcode.Branch) {
        state.flags_value = NO_WIR_VALUE;
        state.flags_opcode = X86Opcode.Invalid;
    }
    if (instruction.opcode == WirOpcode.StackAlloc) {
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (instruction.opcode == WirOpcode.NullCheck) {
        if (instruction.operands.length() != 1 || instruction.result != NO_WIR_VALUE) {
            return "null check requires one operand and no result";
        }
        let value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        let type: WirType = program.arena.types[wir_id_index(UInt32(value.type_id))];
        if (type.kind != WirTypeKind.Pointer) { return "null check requires a pointer operand"; }
        let checked: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (checked.message.length() != 0) { return checked.message; }
        x86_test_register_width(ref output, checked.register, checked.register, true);
        let valid: Int = x86_jump_if_rel32(ref output, X86Opcode.Jne);
        x86_runtime_failure(state.null_function, ref output, ref calls);
        if (!x86_patch_i32(ref output, valid, output.bytes.length() - (valid + 4))) {
            return "cannot resolve null check";
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (instruction.opcode == WirOpcode.BoundsCheck) {
        if (instruction.operands.length() != 2 || instruction.result != NO_WIR_VALUE) {
            return "bounds check requires an index, a limit and no result";
        }
        let index_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        let limit_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))];
        let type: WirType = program.arena.types[wir_id_index(UInt32(index_value.type_id))];
        let size: Int = x86_scalar_size(ref program, index_value.type_id);
        if (index_value.type_id != limit_value.type_id || size == 0 ||
            (type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt)) {
            return "bounds check requires matching integer operands";
        }
        let index: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (index.message.length() != 0) { return index.message; }
        let limit: X86RegisterResult = x86_materialize_register_except(ref program, ref function, instruction.operands[1], slots, ref state, index.register, ref output);
        if (limit.message.length() != 0) { return limit.message; }
        let negative: Int = -1;
        if (type.kind == WirTypeKind.SignedInt) {
            x86_test_register_width(ref output, index.register, index.register, size == 8);
            negative = x86_jump_if_rel32(ref output, X86Opcode.Jl);
        }
        if (size == 8) { x86_cmp_register64(ref output, index.register, limit.register); }
        else { x86_cmp_register32(ref output, index.register, limit.register); }
        let valid_condition: X86Opcode = X86Opcode.Jb;
        if (type.kind == WirTypeKind.SignedInt) { valid_condition = X86Opcode.Jl; }
        let valid: Int = x86_jump_if_rel32(ref output, valid_condition);
        let trap: Int = output.bytes.length();
        x86_runtime_failure(state.bounds_function, ref output, ref calls);
        let continuation: Int = output.bytes.length();
        if ((negative >= 0 && !x86_patch_i32(ref output, negative, trap - (negative + 4))) ||
            !x86_patch_i32(ref output, valid, continuation - (valid + 4))) {
            return "cannot resolve bounds check";
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (instruction.opcode == WirOpcode.AtomicLoad) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
            return "atomic load requires one address and one result";
        }
        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        if (size == 0 || x86_scalar_float(ref program, instruction.type_id)) {
            return "the x86_64 backend supports atomic integer loads up to 64 bits";
        }
        let address: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (address.message.length() != 0) { return address.message; }
        let choice: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, address.register);
        let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        if (!x86_load_scalar(ref output, choice.register, address.register, 0, size, x86_scalar_signed(ref program, instruction.type_id))) {
            return "cannot encode atomic load";
        }
        x86_bind_register(ref state.registers, choice.register, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.AtomicStore) {
        if (instruction.operands.length() != 2 || instruction.result != NO_WIR_VALUE) {
            return "atomic store requires one value, one address and no result";
        }
        let value_id: WirValueID = instruction.operands[0];
        let value: WirValue = program.arena.values[wir_id_index(UInt32(value_id))];
        let size: Int = x86_scalar_size(ref program, value.type_id);
        if (size == 0 || x86_scalar_float(ref program, value.type_id)) {
            return "the x86_64 backend supports atomic integer stores up to 64 bits";
        }
        let stored: X86RegisterResult = x86_materialize_register(ref program, ref function, value_id, slots, ref state, ref output);
        if (stored.message.length() != 0) { return stored.message; }
        let address: X86RegisterResult = x86_materialize_register_except(ref program, ref function, instruction.operands[1], slots, ref state, stored.register, ref output);
        if (address.message.length() != 0) { return address.message; }
        if (instruction.memory_order == WirMemoryOrder.SequentiallyConsistent) {
            let choice: X86RegisterChoice = x86_choose_register_avoiding(ref program, ref state.registers, state.position, stored.register, address.register);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            x86_move_scalar(ref output, choice.register, stored.register, size);
            if (!x86_atomic_exchange(ref output, address.register, choice.register, size)) {
                return "cannot encode sequentially consistent atomic store";
            }
            x86_clear_register(ref state.registers, choice.register);
        } else if (!x86_store_scalar(ref output, stored.register, address.register, 0, size)) {
            return "cannot encode atomic store";
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (instruction.opcode == WirOpcode.AtomicRmw) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "atomic RMW requires one address, one value and one result";
        }
        let value_id: WirValueID = instruction.operands[1];
        let value: WirValue = program.arena.values[wir_id_index(UInt32(value_id))];
        let size: Int = x86_scalar_size(ref program, value.type_id);
        if (size == 0 || x86_scalar_float(ref program, value.type_id)) {
            return "the x86_64 backend supports atomic integer RMW operations up to 64 bits";
        }
        if (instruction.atomic_op == WirAtomicOp.BitAnd || instruction.atomic_op == WirAtomicOp.BitOr || instruction.atomic_op == WirAtomicOp.BitXor) {
            let save_error: String = x86_save_live_registers(ref program, slots, instruction.operands, ref state, ref output);
            if (save_error.length() != 0) { return save_error; }
            let address: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
            if (address.message.length() != 0) { return address.message; }
            let source: X86RegisterResult = x86_materialize_register_except(ref program, ref function, value_id, slots, ref state, address.register, ref output);
            if (source.message.length() != 0) { return source.message; }
            x86_mov_register64(ref output, X86Register.RDX, address.register);
            x86_move_scalar(ref output, X86Register.R8, source.register, size);
            let prepare_error: String = x86_prepare_fixed_register(ref program, ref state, X86Register.RAX, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            if (!x86_load_scalar(ref output, X86Register.RAX, X86Register.RDX, 0, size, x86_scalar_signed(ref program, value.type_id))) {
                return "cannot load an atomic RMW operand";
            }
            let retry: Int = output.bytes.length();
            x86_move_scalar(ref output, X86Register.RCX, X86Register.RAX, size);
            if (instruction.atomic_op == WirAtomicOp.BitAnd) { x86_and_register_width(ref output, X86Register.RCX, X86Register.R8, size == 8); }
            else if (instruction.atomic_op == WirAtomicOp.BitOr) { x86_or_register_width(ref output, X86Register.RCX, X86Register.R8, size == 8); }
            else { x86_xor_register_width(ref output, X86Register.RCX, X86Register.R8, size == 8); }
            if (!x86_atomic_compare_exchange(ref output, X86Register.RDX, X86Register.RCX, size)) {
                return "cannot encode atomic compare-exchange loop";
            }
            let failed: Int = x86_jump_if_rel32(ref output, X86Opcode.Jne);
            if (!x86_patch_i32(ref output, failed, retry - (failed + 4))) {
                return "cannot resolve atomic compare-exchange loop";
            }
            x86_normalize_scalar(ref output, X86Register.RAX, size, x86_scalar_signed(ref program, value.type_id));
            x86_bind_register(ref state.registers, X86Register.RAX, instruction.result);
            state.accumulator = instruction.result;
            return "";
        }
        let address: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (address.message.length() != 0) { return address.message; }
        let source: X86RegisterResult = x86_materialize_register_except(ref program, ref function, value_id, slots, ref state, address.register, ref output);
        if (source.message.length() != 0) { return source.message; }
        let destination: X86Register = source.register;
        if (x86_next_use(ref state.registers.uses, value_id, state.position) != X86_NO_NEXT_USE) {
            let choice: X86RegisterChoice = x86_choose_register_avoiding(ref program, ref state.registers, state.position, source.register, address.register);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            destination = choice.register;
            x86_move_scalar(ref output, destination, source.register, size);
        }
        if (instruction.atomic_op == WirAtomicOp.Subtract) { x86_unary_register(ref output, destination, 3, size == 8); }
        let encoded: Bool = false;
        if (instruction.atomic_op == WirAtomicOp.Exchange) { encoded = x86_atomic_exchange(ref output, address.register, destination, size); }
        else { encoded = x86_atomic_xadd(ref output, address.register, destination, size); }
        if (!encoded) { return "cannot encode atomic RMW operation"; }
        x86_normalize_scalar(ref output, destination, size, x86_scalar_signed(ref program, value.type_id));
        x86_bind_register(ref state.registers, destination, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.Retain || instruction.opcode == WirOpcode.Release) {
        if (instruction.operands.length() != 1 || instruction.result != NO_WIR_VALUE) {
            return "ownership operation requires one pointer and no result";
        }
        let target: WirFuncID = state.retain_function;
        if (instruction.opcode == WirOpcode.Release) { target = state.release_function; }
        if (target == NO_WIR_FUNC) { return "ownership runtime function is missing"; }
        let save_error: String = x86_save_live_registers(ref program, slots, instruction.operands, ref state, ref output);
        if (save_error.length() != 0) { return save_error; }
        let object: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (object.message.length() != 0) { return object.message; }
        if (object.register != X86Register.RCX) { x86_mov_register64(ref output, X86Register.RCX, object.register); }
        calls.append(X86CallFixup(offset=x86_call_rel32(ref output), target=target));
        x86_reset_registers(ref state.registers);
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (x86_wide_integer(ref program, instruction.type_id) &&
        (instruction.opcode == WirOpcode.Add || instruction.opcode == WirOpcode.Subtract || instruction.opcode == WirOpcode.Multiply ||
         instruction.opcode == WirOpcode.BitAnd || instruction.opcode == WirOpcode.BitOr || instruction.opcode == WirOpcode.BitXor)) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "128-bit integer operation requires two operands and a result";
        }
        let prepare_error = x86_prepare_wide_scratch(ref program, ref state, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        let load_error = x86_load_wide_half(ref program, instruction.operands[0], false, X86Register.RAX, ref state, ref output);
        if (load_error.length() == 0) { load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R10, ref state, ref output); }
        if (load_error.length() == 0) { load_error = x86_load_wide_half(ref program, instruction.operands[1], false, X86Register.R11, ref state, ref output); }
        if (load_error.length() == 0) { load_error = x86_load_wide_half(ref program, instruction.operands[1], true, X86Register.RCX, ref state, ref output); }
        if (load_error.length() != 0) { return load_error; }
        if (instruction.opcode == WirOpcode.Add) {
            x86_add_register64(ref output, X86Register.RAX, X86Register.R11);
            x86_adc_register64(ref output, X86Register.R10, X86Register.RCX);
        } else if (instruction.opcode == WirOpcode.Subtract) {
            x86_sub_register64(ref output, X86Register.RAX, X86Register.R11);
            x86_sbb_register64(ref output, X86Register.R10, X86Register.RCX);
        } else if (instruction.opcode == WirOpcode.Multiply) {
            x86_imul_register64(ref output, X86Register.R10, X86Register.R11);
            x86_imul_register64(ref output, X86Register.RCX, X86Register.RAX);
            x86_mul_register64(ref output, X86Register.R11);
            x86_add_register64(ref output, X86Register.RDX, X86Register.R10);
            x86_add_register64(ref output, X86Register.RDX, X86Register.RCX);
            x86_mov_register64(ref output, X86Register.R10, X86Register.RDX);
        } else if (instruction.opcode == WirOpcode.BitAnd) {
            x86_and_register_width(ref output, X86Register.RAX, X86Register.R11, true);
            x86_and_register_width(ref output, X86Register.R10, X86Register.RCX, true);
        } else if (instruction.opcode == WirOpcode.BitOr) {
            x86_or_register_width(ref output, X86Register.RAX, X86Register.R11, true);
            x86_or_register_width(ref output, X86Register.R10, X86Register.RCX, true);
        } else {
            x86_xor_register_width(ref output, X86Register.RAX, X86Register.R11, true);
            x86_xor_register_width(ref output, X86Register.R10, X86Register.RCX, true);
        }
        if (!x86_store_wide_pair(instruction.result, X86Register.RAX, X86Register.R10, ref state, ref output)) {
            return "128-bit integer result has no storage";
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (x86_wide_integer(ref program, instruction.type_id) &&
        (instruction.opcode == WirOpcode.Negate || instruction.opcode == WirOpcode.Not)) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
            return "128-bit unary operation requires one operand and a result";
        }
        let prepare_error = x86_prepare_wide_scratch(ref program, ref state, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        let load_error = x86_load_wide_half(ref program, instruction.operands[0], false, X86Register.RAX, ref state, ref output);
        if (load_error.length() == 0) { load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R10, ref state, ref output); }
        if (load_error.length() != 0) { return load_error; }
        x86_unary_register(ref output, X86Register.RAX, 2, true);
        x86_unary_register(ref output, X86Register.R10, 2, true);
        if (instruction.opcode == WirOpcode.Negate) {
            x86_mov_register_imm32(ref output, X86Register.R11, 1U);
            x86_add_register64(ref output, X86Register.RAX, X86Register.R11);
            x86_mov_register_imm32(ref output, X86Register.R11, 0U);
            x86_adc_register64(ref output, X86Register.R10, X86Register.R11);
        }
        if (!x86_store_wide_pair(instruction.result, X86Register.RAX, X86Register.R10, ref state, ref output)) {
            return "128-bit unary result has no storage";
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (x86_wide_integer(ref program, instruction.type_id) &&
        (instruction.opcode == WirOpcode.ShiftLeft || instruction.opcode == WirOpcode.SignedShiftRight || instruction.opcode == WirOpcode.UnsignedShiftRight)) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "128-bit shift requires two operands and a result";
        }
        let prepare_error = x86_prepare_wide_scratch(ref program, ref state, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        let load_error = x86_load_wide_half(ref program, instruction.operands[0], false, X86Register.RAX, ref state, ref output);
        if (load_error.length() == 0) { load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R10, ref state, ref output); }
        if (load_error.length() != 0) { return load_error; }
        let amount: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))];
        if (amount.kind == WirValueKind.Integer) {
            x86_shift_wide_immediate(ref output, instruction.opcode, Int(amount.integer & UInt128(127U)));
        } else {
            load_error = x86_load_wide_half(ref program, instruction.operands[1], false, X86Register.RCX, ref state, ref output);
            if (load_error.length() != 0) { return load_error; }
            if (!x86_shift_wide_variable(ref output, instruction.opcode)) { return "cannot encode 128-bit variable shift"; }
        }
        if (!x86_store_wide_pair(instruction.result, X86Register.RAX, X86Register.R10, ref state, ref output)) {
            return "128-bit shift result has no storage";
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (x86_comparison_opcode(instruction.opcode) != X86Opcode.Invalid && instruction.operands.length() == 2 &&
        x86_wide_integer(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id)) {
        if (instruction.result == NO_WIR_VALUE || instruction.type_id != program.bool_type) {
            return "128-bit comparison requires a Bool result";
        }
        let prepare_error = x86_prepare_wide_scratch(ref program, ref state, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        let load_error = x86_load_wide_half(ref program, instruction.operands[0], false, X86Register.RAX, ref state, ref output);
        if (load_error.length() == 0) { load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R10, ref state, ref output); }
        if (load_error.length() == 0) { load_error = x86_load_wide_half(ref program, instruction.operands[1], false, X86Register.R11, ref state, ref output); }
        if (load_error.length() == 0) { load_error = x86_load_wide_half(ref program, instruction.operands[1], true, X86Register.RCX, ref state, ref output); }
        if (load_error.length() != 0) { return load_error; }
        if (instruction.opcode == WirOpcode.Equal || instruction.opcode == WirOpcode.NotEqual) {
            let condition: X86Opcode = X86Opcode.Je;
            if (instruction.opcode == WirOpcode.NotEqual) { condition = X86Opcode.Jne; }
            x86_cmp_register64(ref output, X86Register.RAX, X86Register.R11);
            x86_set_condition_register(ref output, X86Register.RAX, condition);
            x86_cmp_register64(ref output, X86Register.R10, X86Register.RCX);
            x86_set_condition_register(ref output, X86Register.R11, condition);
            if (instruction.opcode == WirOpcode.Equal) { x86_and_register_width(ref output, X86Register.RAX, X86Register.R11, false); }
            else { x86_or_register_width(ref output, X86Register.RAX, X86Register.R11, false); }
        } else {
            let high_condition: X86Opcode = x86_wide_high_comparison(instruction.opcode);
            let low_condition: X86Opcode = x86_wide_low_comparison(instruction.opcode);
            x86_cmp_register64(ref output, X86Register.RAX, X86Register.R11);
            x86_set_condition_register(ref output, X86Register.RAX, low_condition);
            x86_cmp_register64(ref output, X86Register.R10, X86Register.RCX);
            x86_set_condition_register(ref output, X86Register.R11, high_condition);
            x86_set_condition_register(ref output, X86Register.RCX, X86Opcode.Je);
            x86_and_register_width(ref output, X86Register.RAX, X86Register.RCX, false);
            x86_or_register_width(ref output, X86Register.RAX, X86Register.R11, false);
        }
        x86_bind_register(ref state.registers, X86Register.RAX, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (x86_wide_integer(ref program, instruction.type_id) &&
        (instruction.opcode == WirOpcode.SignedDivide || instruction.opcode == WirOpcode.UnsignedDivide ||
         instruction.opcode == WirOpcode.SignedRemainder || instruction.opcode == WirOpcode.UnsignedRemainder)) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "128-bit division requires two operands and a result";
        }
        let prepare_error = x86_prepare_wide_scratch(ref program, ref state, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        let load_error = x86_load_wide_half(ref program, instruction.operands[0], false, X86Register.RAX, ref state, ref output);
        if (load_error.length() == 0) { load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R10, ref state, ref output); }
        if (load_error.length() == 0) { load_error = x86_load_wide_half(ref program, instruction.operands[1], false, X86Register.R11, ref state, ref output); }
        if (load_error.length() == 0) { load_error = x86_load_wide_half(ref program, instruction.operands[1], true, X86Register.R9, ref state, ref output); }
        if (load_error.length() != 0) { return load_error; }

        let signed: Bool = instruction.opcode == WirOpcode.SignedDivide || instruction.opcode == WirOpcode.SignedRemainder;
        let remainder: Bool = instruction.opcode == WirOpcode.SignedRemainder || instruction.opcode == WirOpcode.UnsignedRemainder;
        if (signed) {
            x86_mov_register64(ref output, X86Register.RDX, X86Register.R10);
            x86_shift_register_imm8(ref output, X86Register.RDX, Byte(63), 7, true);
            x86_apply_wide_sign(ref output, X86Register.RAX, X86Register.R10, X86Register.RDX);
            x86_mov_register64(ref output, X86Register.R8, X86Register.R9);
            x86_shift_register_imm8(ref output, X86Register.R8, Byte(63), 7, true);
            x86_apply_wide_sign(ref output, X86Register.R11, X86Register.R9, X86Register.R8);
        }
        if (!x86_divide_wide_unsigned(ref output)) { return "cannot encode 128-bit division"; }

        if (signed) {
            load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R11, ref state, ref output);
            if (load_error.length() == 0) { load_error = x86_load_wide_half(ref program, instruction.operands[1], true, X86Register.RCX, ref state, ref output); }
            if (load_error.length() != 0) { return load_error; }
            x86_xor_register_width(ref output, X86Register.R11, X86Register.RCX, true);
            x86_shift_register_imm8(ref output, X86Register.R11, Byte(63), 7, true);
            x86_test_register_width(ref output, X86Register.R11, X86Register.R11, true);
            let same_sign: Int = x86_jump_if_rel32(ref output, X86Opcode.Je);
            if (!remainder) { x86_apply_wide_sign(ref output, X86Register.RAX, X86Register.R10, X86Register.R11); }
            let sign_done: Int = x86_jump_rel32(ref output);
            if (!x86_patch_i32(ref output, same_sign, output.bytes.length() - (same_sign + 4))) {
                return "cannot resolve signed 128-bit division";
            }
            // MIN / -1 must fault like the native signed divide instruction
            x86_test_register_width(ref output, X86Register.R10, X86Register.R10, true);
            let in_range: Int = x86_jump_if_rel32(ref output, X86Opcode.Jge);
            x86_mov_register_imm32(ref output, X86Register.R11, 0U);
            x86_div_register_width(ref output, X86Register.R11, true, false);
            if (!x86_patch_i32(ref output, in_range, output.bytes.length() - (in_range + 4)) ||
                !x86_patch_i32(ref output, sign_done, output.bytes.length() - (sign_done + 4))) {
                return "cannot resolve signed 128-bit division";
            }
        }

        if (remainder) {
            x86_mov_register64(ref output, X86Register.RAX, X86Register.RDX);
            x86_mov_register64(ref output, X86Register.R10, X86Register.R8);
            if (signed) {
                load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R11, ref state, ref output);
                if (load_error.length() != 0) { return load_error; }
                x86_shift_register_imm8(ref output, X86Register.R11, Byte(63), 7, true);
                x86_apply_wide_sign(ref output, X86Register.RAX, X86Register.R10, X86Register.R11);
            }
        }
        if (!x86_store_wide_pair(instruction.result, X86Register.RAX, X86Register.R10, ref state, ref output)) {
            return "128-bit division result has no storage";
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (instruction.opcode == WirOpcode.StructValue || instruction.opcode == WirOpcode.ArrayValue) {
        let type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        let layout: WirTypeLayout = state.layouts[wir_id_index(UInt32(instruction.type_id))];
        let home = x86_stack_offset(ref state.stack, instruction.result);
        let count = type.fields.length();
        if (type.kind == WirTypeKind.Array) {
            if (type.length > UIntSize(2147483647U)) { return "array constructor exceeds the machine operand limit"; }
            count = Int(type.length);
        }
        if (!layout.valid || home == 0 || instruction.operands.length() > count ||
            (instruction.opcode == WirOpcode.StructValue && type.kind != WirTypeKind.Struct) ||
            (instruction.opcode == WirOpcode.ArrayValue && type.kind != WirTypeKind.Array)) {
            return "aggregate constructor has an invalid layout or operand count";
        }
        let temporary: X86RegisterChoice = x86_choose_register(ref program, ref state.registers, state.position);
        let prepare_error = x86_prepare_register(ref program, ref state, temporary, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        // initialize padding too, so snapshots do not copy uninitialized stack bytes
        if (!x86_zero_memory(ref output, X86Register.RBP, home, Int(layout.size), temporary.register)) { return "cannot initialize aggregate storage"; }
        let i = 0;
        let stride = 0;
        if (type.kind == WirTypeKind.Array) { stride = Int(state.layouts[wir_id_index(UInt32(type.element))].size); }
        while (i < instruction.operands.length()) {
            let offset: Int = i * stride;
            if (type.kind == WirTypeKind.Struct) { offset = Int(layout.field_offsets[i]); }
            let operand: WirValueID = instruction.operands[i];
            let message = x86_store_value(ref program, ref function, operand, X86Register.RBP, home + offset, slots, ref state, ref output);
            if (message.length() != 0) { return message; }
            let repeated: Bool = false;
            let next: Int = i + 1;
            while (next < instruction.operands.length()) {
                if (instruction.operands[next] == operand) {
                    repeated = true;
                    break;
                }
                next++;
            }
            if (!repeated && x86_next_use(ref state.registers.uses, operand, state.position) == X86_NO_NEXT_USE) {
                x86_forget_register_value(ref state.registers, operand);
                x86_forget_spill_value(ref state.spills, operand);
            }
            i++;
        }
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (instruction.opcode == WirOpcode.Field || instruction.opcode == WirOpcode.Index) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) { return "aggregate extraction requires two operands and a result"; }
        let aggregate: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        let type: WirType = program.arena.types[wir_id_index(UInt32(aggregate.type_id))];
        let index: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))];
        let home = x86_stack_offset(ref state.stack, instruction.operands[0]);
        if (index.kind != WirValueKind.Integer) { return "aggregate extraction currently requires a constant index"; }
        let offset = 0;
        if (instruction.opcode == WirOpcode.Field) {
            if (type.kind != WirTypeKind.Struct || index.integer >= UInt128(type.fields.length())) { return "aggregate field index is out of range"; }
            offset = Int(state.layouts[wir_id_index(UInt32(aggregate.type_id))].field_offsets[Int(index.integer)]);
        } else {
            if (type.kind != WirTypeKind.Array || index.integer >= UInt128(type.length)) { return "aggregate element index is out of range"; }
            offset = Int(index.integer) * Int(state.layouts[wir_id_index(UInt32(type.element))].size);
        }

        if (home == 0 && aggregate.kind == WirValueKind.Constant) {
            let constant: WirConstant = program.arena.constants[wir_id_index(aggregate.owner)];
            if (constant.kind == WirConstKind.Aggregate && index.integer < UInt128(constant.elements.length())) {
                let member: WirValueID = constant.elements[Int(index.integer)];
                if (x86_memory_value(ref program, instruction.type_id)) {
                    let message: String = x86_store_value(ref program, ref function, member, X86Register.RBP, x86_stack_offset(ref state.stack, instruction.result), slots, ref state, ref output);
                    if (message.length() != 0) { return message; }
                    state.accumulator = NO_WIR_VALUE;
                } else {
                    let value: X86RegisterResult = x86_materialize_register(ref program, ref function, member, slots, ref state, ref output);
                    if (value.message.length() != 0) { return value.message; }
                    x86_bind_register(ref state.registers, value.register, instruction.result);
                    state.accumulator = instruction.result;
                }
                return "";
            }
            if (constant.kind == WirConstKind.Zero) {
                if (x86_memory_value(ref program, instruction.type_id)) {
                    let layout: WirTypeLayout = state.layouts[wir_id_index(UInt32(instruction.type_id))];
                    let result_home: Int = x86_stack_offset(ref state.stack, instruction.result);
                    let temporary: X86RegisterChoice = x86_choose_register(ref program, ref state.registers, state.position);
                    let prepare_error: String = x86_prepare_register(ref program, ref state, temporary, ref output);
                    if (prepare_error.length() != 0) { return prepare_error; }
                    if (result_home == 0 || !x86_zero_memory(ref output, X86Register.RBP, result_home, Int(layout.size), temporary.register)) {
                        return "cannot extract a zero aggregate member";
                    }
                    state.accumulator = NO_WIR_VALUE;
                } else {
                    let choice: X86RegisterChoice = x86_choose_register_class(ref program, ref state.registers, state.position, X86Register.None, x86_scalar_float(ref program, instruction.type_id));
                    let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
                    if (prepare_error.length() != 0) { return prepare_error; }
                    if (x86_is_xmm(choice.register)) {
                        let integer: X86RegisterChoice = x86_choose_register(ref program, ref state.registers, state.position);
                        prepare_error = x86_prepare_register(ref program, ref state, integer, ref output);
                        if (prepare_error.length() != 0) { return prepare_error; }
                        x86_mov_register_imm32(ref output, integer.register, 0U);
                        if (!x86_sse_bits(ref output, choice.register, integer.register, x86_scalar_size(ref program, instruction.type_id), true)) {
                            return "cannot extract a zero floating member";
                        }
                    } else {
                        x86_mov_register_imm32(ref output, choice.register, 0U);
                    }
                    x86_bind_register(ref state.registers, choice.register, instruction.result);
                    state.accumulator = instruction.result;
                }
                return "";
            }
        }
        if (home == 0) { return "aggregate value has no storage for extraction"; }
        let choice: X86RegisterChoice = x86_choose_register_class(ref program, ref state.registers, state.position, X86Register.None, x86_scalar_float(ref program, instruction.type_id));
        let prepare_error = x86_prepare_register(ref program, ref state, choice, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        if (x86_memory_value(ref program, instruction.type_id)) {
            let layout: WirTypeLayout = state.layouts[wir_id_index(UInt32(instruction.type_id))];
            if (!x86_copy_memory(ref output, X86Register.RBP, x86_stack_offset(ref state.stack, instruction.result), X86Register.RBP, home + offset, Int(layout.size), choice.register)) { return "cannot extract aggregate member"; }
            state.accumulator = NO_WIR_VALUE;
        } else {
            if (!x86_load_scalar(ref output, choice.register, X86Register.RBP, home + offset, x86_scalar_size(ref program, instruction.type_id), x86_scalar_signed(ref program, instruction.type_id))) { return "cannot extract scalar member"; }
            x86_bind_register(ref state.registers, choice.register, instruction.result);
            state.accumulator = instruction.result;
        }
        return "";
    }

    if (instruction.opcode == WirOpcode.Store) {
        if (instruction.operands.length() != 2) {
            return "store instruction has the wrong operand count";
        }

        let offset: Int = x86_stack_offset(ref state.stack, instruction.operands[1]);
        if (!x86_rematerializable(ref program, instruction.operands[1])) {
            offset = 0;
        }

        let stored_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        if (x86_memory_value(ref program, stored_value.type_id)) {
            let address: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[1], slots, ref state, ref output);
            if (address.message.length() != 0) { return address.message; }
            let message = x86_store_value(ref program, ref function, instruction.operands[0], address.register, 0, slots, ref state, ref output);
            if (message.length() != 0) { return message; }
            state.accumulator = NO_WIR_VALUE;
            return "";
        }
        let size: Int = x86_scalar_size(ref program, stored_value.type_id);
        if (size == 0 || (offset != 0 && size > x86_stack_size(ref state.stack, instruction.operands[1]))) {
            return "store has an unsupported value or insufficient stack storage";
        }

        let stored: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (stored.message.length() != 0) {
            return stored.message;
        }

        if (offset != 0) {
            x86_store_scalar(ref output, stored.register, X86Register.RBP, offset, size);
        } else {
            let address: X86RegisterResult = x86_materialize_register_except(ref program, ref function, instruction.operands[1], slots, ref state, stored.register, ref output);
            if (address.message.length() != 0) {
                return address.message;
            }

            x86_store_scalar(ref output, stored.register, address.register, 0, size);
        }
        state.accumulator = instruction.operands[0];
        return "";
    }

    if (instruction.opcode == WirOpcode.Load) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
            return "load instruction has the wrong operand count";
        }
        if (x86_memory_value(ref program, instruction.type_id)) {
            let address: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
            if (address.message.length() != 0) { return address.message; }
            let temporary: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, address.register);
            let prepare_error = x86_prepare_register(ref program, ref state, temporary, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            let layout: WirTypeLayout = state.layouts[wir_id_index(UInt32(instruction.type_id))];
            let home = x86_stack_offset(ref state.stack, instruction.result);
            if (!x86_copy_memory(ref output, X86Register.RBP, home, address.register, 0, Int(layout.size), temporary.register)) { return "cannot load aggregate snapshot"; }
            state.accumulator = NO_WIR_VALUE;
            return "";
        }

        let offset: Int = x86_stack_offset(ref state.stack, instruction.operands[0]);
        if (!x86_rematerializable(ref program, instruction.operands[0])) {
            offset = 0;
        }

        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        if (size == 0 || (offset != 0 && size > x86_stack_size(ref state.stack, instruction.operands[0]))) {
            return "load has an unsupported value or insufficient stack storage";
        }

        let base: X86Register = X86Register.RBP;
        if (offset == 0) {
            let address: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
            if (address.message.length() != 0) {
                return address.message;
            }

            base = address.register;
        }
        let floating: Bool = x86_scalar_float(ref program, instruction.type_id);
        let choice: X86RegisterChoice = X86RegisterChoice(register=X86Register.None, evicted=NO_WIR_VALUE);
        if (offset == 0 && !floating && x86_next_use(ref state.registers.uses, instruction.operands[0], state.position) == X86_NO_NEXT_USE) {
            // mov reg, [reg] is safe once the address has no later use
            x86_clear_register(ref state.registers, base);
            choice = X86RegisterChoice(register=base, evicted=NO_WIR_VALUE);
        } else {
            choice = x86_choose_register_class(ref program, ref state.registers, state.position, base, floating);
        }

        let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
        if (prepare_error.length() != 0) {
            return prepare_error;
        }

        x86_load_scalar(ref output, choice.register, base, offset, size, x86_scalar_signed(ref program, instruction.type_id));
        x86_bind_register(ref state.registers, choice.register, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.SignedIntToFloat || instruction.opcode == WirOpcode.UnsignedIntToFloat ||
        instruction.opcode == WirOpcode.FloatToSignedInt || instruction.opcode == WirOpcode.FloatToUnsignedInt) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
            return "numeric conversion has the wrong operand count";
        }
        let to_float = instruction.opcode == WirOpcode.SignedIntToFloat || instruction.opcode == WirOpcode.UnsignedIntToFloat;
        let unsigned = instruction.opcode == WirOpcode.UnsignedIntToFloat || instruction.opcode == WirOpcode.FloatToUnsignedInt;
        let source_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        let integer_type: WirTypeID = instruction.type_id;
        let float_type: WirTypeID = source_value.type_id;
        if (to_float) {
            integer_type = source_value.type_id;
            float_type = instruction.type_id;
        }
        let integer_size = x86_scalar_size(ref program, integer_type);
        let float_size = x86_scalar_size(ref program, float_type);
        let kind = program.arena.types[wir_id_index(UInt32(integer_type))].kind;
        if (integer_size == 0 || !x86_scalar_float(ref program, float_type) ||
            (unsigned && kind != WirTypeKind.UnsignedInt) || (!unsigned && kind != WirTypeKind.SignedInt)) {
            return "numeric conversion requires a scalar integer and f32 or f64";
        }
        let source: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (source.message.length() != 0) { return source.message; }
        let choice: X86RegisterChoice = x86_choose_register_class(ref program, ref state.registers, state.position, source.register, to_float);
        let prepare_error = x86_prepare_register(ref program, ref state, choice, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        if (unsigned && integer_size == 8) {
            if (to_float) {
                let half: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, source.register);
                prepare_error = x86_prepare_register(ref program, ref state, half, ref output);
                if (prepare_error.length() != 0) { return prepare_error; }
                let low_bit: X86RegisterChoice = x86_choose_register_avoiding(ref program, ref state.registers, state.position, source.register, half.register);
                prepare_error = x86_prepare_register(ref program, ref state, low_bit, ref output);
                if (prepare_error.length() != 0) { return prepare_error; }
                if (!x86_uint64_to_float(ref output, choice.register, source.register, half.register, low_bit.register, float_size)) {
                    return "the x86_64 encoder rejected the u64-to-float conversion";
                }
            } else {
                let temporary: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, choice.register);
                prepare_error = x86_prepare_register(ref program, ref state, temporary, ref output);
                if (prepare_error.length() != 0) { return prepare_error; }
                let threshold: X86RegisterChoice = x86_choose_register_class(ref program, ref state.registers, state.position, source.register, true);
                prepare_error = x86_prepare_register(ref program, ref state, threshold, ref output);
                if (prepare_error.length() != 0) { return prepare_error; }
                // the upper-half path subtracts from source; preserve it before either path
                prepare_error = x86_overwrite_operand(ref program, ref state, source.register, ref output);
                if (prepare_error.length() != 0) { return prepare_error; }
                if (!x86_float_to_uint64(ref output, choice.register, source.register, threshold.register, temporary.register, float_size)) {
                    return "the x86_64 encoder rejected the float-to-u64 conversion";
                }
            }
            x86_bind_register(ref state.registers, choice.register, instruction.result);
            state.accumulator = instruction.result;
            return "";
        }
        // u32 needs a signed 64-bit conversion to retain its upper half
        let conversion_size = 4;
        if (unsigned || integer_size == 8) { conversion_size = 8; }
        if (!x86_sse_convert(ref output, choice.register, source.register, float_size, conversion_size, to_float)) {
            return "the x86_64 encoder rejected the numeric conversion";
        }
        if (!to_float) { x86_normalize_scalar(ref output, choice.register, integer_size, !unsigned); }
        x86_bind_register(ref state.registers, choice.register, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.FloatExtend || instruction.opcode == WirOpcode.FloatTruncate ||
        (instruction.opcode == WirOpcode.Bitcast && instruction.operands.length() == 1 &&
         (x86_scalar_float(ref program, instruction.type_id) || x86_scalar_float(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id)))) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) { return "floating cast requires one operand and a result"; }
        let source_id: WirValueID = instruction.operands[0];
        let source_value: WirValue = program.arena.values[wir_id_index(UInt32(source_id))];
        let source_size: Int = x86_scalar_size(ref program, source_value.type_id);
        let target_size: Int = x86_scalar_size(ref program, instruction.type_id);
        if ((source_size != 4 && source_size != 8) || (target_size != 4 && target_size != 8)) { return "floating casts require 32-bit or 64-bit scalar values"; }
        let source: X86RegisterResult = x86_materialize_register(ref program, ref function, source_id, slots, ref state, ref output);
        if (source.message.length() != 0) { return source.message; }
        if (instruction.opcode == WirOpcode.Bitcast) {
            if (source_size != target_size) { return "bitcast operands must have equal widths"; }
            let choice: X86RegisterChoice = x86_choose_register_class(ref program, ref state.registers, state.position, X86Register.None, x86_scalar_float(ref program, instruction.type_id));
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            x86_move_scalar(ref output, choice.register, source.register, source_size);
            x86_bind_register(ref state.registers, choice.register, instruction.result);
        } else {
            if (!x86_is_xmm(source.register) || !x86_scalar_float(ref program, instruction.type_id)) { return "floating precision casts require floating operands"; }
            let save_error: String = x86_overwrite_operand(ref program, ref state, source.register, ref output);
            if (save_error.length() != 0) { return save_error; }
            x86_sse_register(ref output, 90, source.register, source.register, source_size);
            x86_bind_register(ref state.registers, source.register, instruction.result);
        }
        state.accumulator = instruction.result;
        return "";
    }

    if ((instruction.opcode == WirOpcode.Truncate || instruction.opcode == WirOpcode.SignExtend || instruction.opcode == WirOpcode.ZeroExtend ||
         instruction.opcode == WirOpcode.Bitcast || instruction.opcode == WirOpcode.PointerToInt || instruction.opcode == WirOpcode.IntToPointer) &&
        instruction.operands.length() == 1 && instruction.result != NO_WIR_VALUE) {
        let source_id: WirValueID = instruction.operands[0];
        let source_value: WirValue = program.arena.values[wir_id_index(UInt32(source_id))];
        let source_wide: Bool = x86_wide_integer(ref program, source_value.type_id);
        let target_wide: Bool = x86_wide_integer(ref program, instruction.type_id);

        if (source_wide && target_wide) {
            if (instruction.opcode != WirOpcode.Bitcast) { return "128-bit integer casts of equal width require a bitcast"; }
            let prepare_error: String = x86_prepare_wide_scratch(ref program, ref state, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            let load_error: String = x86_load_wide_half(ref program, source_id, false, X86Register.RAX, ref state, ref output);
            if (load_error.length() == 0) { load_error = x86_load_wide_half(ref program, source_id, true, X86Register.R10, ref state, ref output); }
            if (load_error.length() != 0) { return load_error; }
            if (!x86_store_wide_pair(instruction.result, X86Register.RAX, X86Register.R10, ref state, ref output)) {
                return "128-bit bitcast result has no storage";
            }
            state.accumulator = NO_WIR_VALUE;
            return "";
        }

        if (target_wide) {
            if (instruction.opcode != WirOpcode.SignExtend && instruction.opcode != WirOpcode.ZeroExtend && instruction.opcode != WirOpcode.PointerToInt) {
                return "unsupported cast to a 128-bit integer";
            }
            let prepare_error: String = x86_prepare_wide_scratch(ref program, ref state, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            let source: X86RegisterResult = x86_materialize_register(ref program, ref function, source_id, slots, ref state, ref output);
            if (source.message.length() != 0) { return source.message; }
            if (source.register != X86Register.RAX) { x86_mov_register64(ref output, X86Register.RAX, source.register); }
            if (instruction.opcode == WirOpcode.SignExtend) {
                let source_size: Int = x86_scalar_size(ref program, source_value.type_id);
                if (source_size < 8) { x86_sign_extend32(ref output, X86Register.RAX, X86Register.RAX); }
                x86_mov_register64(ref output, X86Register.R10, X86Register.RAX);
                x86_shift_register_imm8(ref output, X86Register.R10, Byte(63), 7, true);
            } else {
                x86_mov_register_imm32(ref output, X86Register.R10, 0U);
            }
            if (!x86_store_wide_pair(instruction.result, X86Register.RAX, X86Register.R10, ref state, ref output)) {
                return "128-bit cast result has no storage";
            }
            state.accumulator = NO_WIR_VALUE;
            return "";
        }

        if (source_wide) {
            if (instruction.opcode != WirOpcode.Truncate && instruction.opcode != WirOpcode.IntToPointer) {
                return "unsupported cast from a 128-bit integer";
            }
            let target_size: Int = x86_scalar_size(ref program, instruction.type_id);
            if (target_size == 0) { return "128-bit integer cast has an unsupported target type"; }
            let prepare_error: String = x86_prepare_fixed_register(ref program, ref state, X86Register.RAX, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            let load_error: String = x86_load_wide_half(ref program, source_id, false, X86Register.RAX, ref state, ref output);
            if (load_error.length() != 0) { return load_error; }
            x86_normalize_scalar(ref output, X86Register.RAX, target_size, x86_scalar_signed(ref program, instruction.type_id));
            x86_bind_register(ref state.registers, X86Register.RAX, instruction.result);
            state.accumulator = instruction.result;
            return "";
        }
    }

    if (instruction.opcode == WirOpcode.Truncate || instruction.opcode == WirOpcode.SignExtend || instruction.opcode == WirOpcode.ZeroExtend ||
        instruction.opcode == WirOpcode.Bitcast || instruction.opcode == WirOpcode.PointerToInt || instruction.opcode == WirOpcode.IntToPointer) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) { return "cast instruction requires one operand and a result"; }
        let source_id: WirValueID = instruction.operands[0];
        let source_value: WirValue = program.arena.values[wir_id_index(UInt32(source_id))];
        let source_size: Int = x86_scalar_size(ref program, source_value.type_id);
        let target_size: Int = x86_scalar_size(ref program, instruction.type_id);
        if (source_size == 0 || target_size == 0) { return "the x86_64 lowering supports integer and pointer casts up to 64 bits"; }
        let source: X86RegisterResult = x86_materialize_register(ref program, ref function, source_id, slots, ref state, ref output);
        if (source.message.length() != 0) { return source.message; }
        let destination: X86Register = source.register;
        if (x86_next_use(ref state.registers.uses, source_id, state.position) != X86_NO_NEXT_USE) {
            let choice: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, source.register);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            destination = choice.register;
            x86_move_scalar(ref output, destination, source.register, source_size);
        }
        // inttoptr zero-extends the source bits, even when its declared type is signed
        if (instruction.opcode == WirOpcode.IntToPointer && source_size < 4) {
            x86_extend_register(ref output, destination, destination, source_size, false);
        } else if (instruction.opcode == WirOpcode.SignExtend && target_size == 8) {
            x86_sign_extend32(ref output, destination, destination);
        } else if (source_size < 8 && target_size == 8) {
            x86_mov_register32(ref output, destination, destination);
        }
        if (instruction.type_id == program.bool_type) {
            x86_bitwise_register_imm32(ref output, destination, 1U, 4);
        } else {
            x86_normalize_scalar(ref output, destination, target_size, x86_scalar_signed(ref program, instruction.type_id));
        }
        x86_bind_register(ref state.registers, destination, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.FieldAddress || instruction.opcode == WirOpcode.IndexAddress) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) { return "address instruction requires two operands and a result"; }
        let base_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        let pointer: WirType = program.arena.types[wir_id_index(UInt32(base_value.type_id))];
        if (pointer.kind != WirTypeKind.Pointer) { return "address instruction requires a pointer base"; }
        let layout: WirTypeLayout = state.layouts[wir_id_index(UInt32(pointer.element))];
        if (!layout.valid) { return "address instruction has no valid element layout"; }
        let base: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (base.message.length() != 0) { return base.message; }
        if (instruction.opcode == WirOpcode.FieldAddress) {
            let field: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))];
            if (field.kind != WirValueKind.Integer || field.integer >= UInt128(layout.field_offsets.length())) { return "field address has an invalid field index"; }
            let offset: UInt64 = layout.field_offsets[Int(field.integer)];
            if (offset > 2147483647UL) { return "field offset exceeds the x86_64 displacement range"; }
            let choice: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, base.register);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            x86_lea(ref output, choice.register, base.register, X86Register.None, 1, Int(offset));
            x86_bind_register(ref state.registers, choice.register, instruction.result);
        } else {
            let index_id: WirValueID = instruction.operands[1];
            let index_value: WirValue = program.arena.values[wir_id_index(UInt32(index_id))];
            let index_size: Int = x86_scalar_size(ref program, index_value.type_id);
            let element: WirType = program.arena.types[wir_id_index(UInt32(pointer.element))];
            if (element.kind == WirTypeKind.Array) { layout = state.layouts[wir_id_index(UInt32(element.element))]; }
            if (!layout.valid || layout.size > 2147483647UL || index_size == 0) { return "index address has an unsupported index width or element stride"; }
            let index: X86RegisterResult = x86_materialize_register_except(ref program, ref function, index_id, slots, ref state, base.register, ref output);
            if (index.message.length() != 0) { return index.message; }
            let choice: X86RegisterChoice = x86_choose_register_avoiding(ref program, ref state.registers, state.position, base.register, index.register);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            if (index_size == 8) { x86_mov_register64(ref output, choice.register, index.register); }
            else if (x86_scalar_signed(ref program, index_value.type_id)) { x86_sign_extend32(ref output, choice.register, index.register); }
            else { x86_mov_register32(ref output, choice.register, index.register); }
            let scale: Int = Int(layout.size);
            if (scale != 1 && scale != 2 && scale != 4 && scale != 8) {
                x86_multiply_imm32(ref output, choice.register, UInt32(layout.size), true);
                scale = 1;
            }
            x86_lea(ref output, choice.register, base.register, choice.register, scale, 0);
            x86_bind_register(ref state.registers, choice.register, instruction.result);
        }
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.FloatNegate) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE || !x86_scalar_float(ref program, instruction.type_id)) {
            return "floating negate requires one f32 or f64 operand and a result";
        }
        if (program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id != instruction.type_id) {
            return "floating negate operand and result must have the same type";
        }
        let size = x86_scalar_size(ref program, instruction.type_id);
        let source: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (source.message.length() != 0) { return source.message; }
        let destination: X86RegisterChoice = x86_choose_register_class(ref program, ref state.registers, state.position, source.register, true);
        let prepare_error = x86_prepare_register(ref program, ref state, destination, ref output);
        if (prepare_error.length() != 0) { return "floating negate destination: " + prepare_error; }
        let bits: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, X86Register.None);
        prepare_error = x86_prepare_register(ref program, ref state, bits, ref output);
        if (prepare_error.length() != 0) { return "floating negate bits: " + prepare_error; }
        // flip the sign bit without floating arithmetic; keep -0 and NaN payloads intact
        x86_move_scalar(ref output, bits.register, source.register, size);
        if (size == 4) {
            x86_bitwise_register_imm32(ref output, bits.register, 2147483648U, 6);
        } else {
            let mask: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, bits.register);
            prepare_error = x86_prepare_register(ref program, ref state, mask, ref output);
            if (prepare_error.length() != 0) { return "floating negate mask: " + prepare_error; }
            x86_mov_register_imm64(ref output, mask.register, 9223372036854775808UL);
            x86_xor_register_width(ref output, bits.register, mask.register, true);
        }
        x86_move_scalar(ref output, destination.register, bits.register, size);
        x86_bind_register(ref state.registers, destination.register, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (x86_scalar_float(ref program, instruction.type_id) && (instruction.opcode == WirOpcode.Add || instruction.opcode == WirOpcode.Subtract || instruction.opcode == WirOpcode.Multiply || instruction.opcode == WirOpcode.FloatDivide)) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) { return "floating arithmetic requires two operands and a result"; }
        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        if (size != 4 && size != 8) { return "the x86_64 lowering supports f32 and f64 arithmetic"; }
        let left: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (left.message.length() != 0) { return left.message; }
        let right: X86RegisterResult = x86_materialize_register_except(ref program, ref function, instruction.operands[1], slots, ref state, left.register, ref output);
        if (right.message.length() != 0) { return right.message; }
        // two-operand SSE overwrites the left value; spill it first if it stays live
        let save_error: String = x86_overwrite_operand(ref program, ref state, left.register, ref output);
        if (save_error.length() != 0) { return save_error; }
        let opcode: Int = 88;
        if (instruction.opcode == WirOpcode.Subtract) { opcode = 92; }
        else if (instruction.opcode == WirOpcode.Multiply) { opcode = 89; }
        else if (instruction.opcode == WirOpcode.FloatDivide) { opcode = 94; }
        if (!x86_sse_register(ref output, opcode, left.register, right.register, size)) { return "the SSE encoder rejected floating arithmetic operands"; }
        x86_bind_register(ref state.registers, left.register, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.Add || instruction.opcode == WirOpcode.Subtract || instruction.opcode == WirOpcode.Multiply) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "arithmetic instruction has the wrong operand count";
        }

        let result_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        if ((result_type.kind != WirTypeKind.SignedInt && result_type.kind != WirTypeKind.UnsignedInt) || size == 0) {
            return "the x86_64 lowering supports integer arithmetic up to 64 bits";
        }

        let left_id: WirValueID = instruction.operands[0];
        let right_id: WirValueID = instruction.operands[1];
        let left_value: WirValue = program.arena.values[wir_id_index(UInt32(left_id))];
        let right: WirValue = program.arena.values[wir_id_index(UInt32(right_id))];
        if (instruction.opcode != WirOpcode.Subtract && left_value.kind == WirValueKind.Integer && right.kind != WirValueKind.Integer) {
            let swap = left_id;
            left_id = right_id;
            right_id = swap;
            right = left_value;
        }
        let left: X86RegisterResult = x86_materialize_register(ref program, ref function, left_id, slots, ref state, ref output);
        if (left.message.length() != 0) {
            return left.message;
        }

        let immediate: Bool = x86_integer_immediate(right, size);
        let right_register: X86Register = X86Register.None;
        if (!immediate) {
            let loaded_right: X86RegisterResult = x86_materialize_register_except(ref program, ref function, right_id, slots, ref state, left.register, ref output);
            if (loaded_right.message.length() != 0) {
                return loaded_right.message;
            }
            right_register = loaded_right.register;
        }

        let destination: X86Register = left.register;
        if (x86_next_use(ref state.registers.uses, left_id, state.position) != X86_NO_NEXT_USE) {
            let reuse_right: Bool = instruction.opcode != WirOpcode.Subtract && 
                                    right_register != X86Register.None &&
                                    x86_next_use(ref state.registers.uses, right_id, state.position) == X86_NO_NEXT_USE;
            if reuse_right {
                destination = right_register;
            } else {
                let choice: X86RegisterChoice = x86_choose_register_avoiding(ref program, ref state.registers, state.position, left.register, right_register);
                let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
                if (prepare_error.length() != 0) {
                    return prepare_error;
                }
                destination = choice.register;
                x86_move_scalar(ref output, destination, left.register, size);
            }
        }

        if (immediate) {
            if (instruction.opcode == WirOpcode.Add) {
                x86_add_register_imm(ref output, destination, UInt32(right.integer), size == 8);
            } else if (instruction.opcode == WirOpcode.Subtract) {
                x86_sub_register_imm(ref output, destination, UInt32(right.integer), size == 8);
            } else {
                x86_imul_register_imm(ref output, destination, UInt32(right.integer), size == 8);
            }
        } else {
            let source: X86Register = right_register;
            if (destination == right_register) {
                source = left.register;
            }

            if (size == 8) {
                if (instruction.opcode == WirOpcode.Add) {
                    x86_add_register64(ref output, destination, source);
                } else if (instruction.opcode == WirOpcode.Subtract) {
                    x86_sub_register64(ref output, destination, source);
                } else {
                    x86_imul_register64(ref output, destination, source);
                }
            } else {
                if (instruction.opcode == WirOpcode.Add) { x86_add_register32(ref output, destination, source); }
                else if (instruction.opcode == WirOpcode.Subtract) { x86_sub_register32(ref output, destination, source); }
                else { x86_imul_register32(ref output, destination, source); }
            }
        }

        x86_normalize_scalar(ref output, destination, size, result_type.kind == WirTypeKind.SignedInt);
        x86_bind_register(ref state.registers, destination, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.BitAnd || instruction.opcode == WirOpcode.BitOr || instruction.opcode == WirOpcode.BitXor) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "bitwise instruction has the wrong operand count";
        }
        let result_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        if ((result_type.kind != WirTypeKind.SignedInt && result_type.kind != WirTypeKind.UnsignedInt && result_type.kind != WirTypeKind.BoolType) || size == 0) {
            return "the x86_64 lowering supports scalar integer and Bool bitwise operations up to 64 bits";
        }
        let left_id: WirValueID = instruction.operands[0];
        let right_id: WirValueID = instruction.operands[1];
        let left_value: WirValue = program.arena.values[wir_id_index(UInt32(left_id))];
        let right: WirValue = program.arena.values[wir_id_index(UInt32(right_id))];
        if (left_value.kind == WirValueKind.Integer && right.kind != WirValueKind.Integer) {
            let swap = left_id;
            left_id = right_id;
            right_id = swap;
            right = left_value;
        }
        let immediate: Bool = x86_integer_immediate(right, size);
        let left: X86RegisterResult = x86_materialize_register(ref program, ref function, left_id, slots, ref state, ref output);
        if (left.message.length() != 0) { return left.message; }

        let right_register: X86Register = X86Register.None;
        if (!immediate) {
            let loaded_right: X86RegisterResult = x86_materialize_register_except(ref program, ref function, right_id, slots, ref state, left.register, ref output);
            if (loaded_right.message.length() != 0) { return loaded_right.message; }
            right_register = loaded_right.register;
        }

        let destination: X86Register = left.register;
        if (x86_next_use(ref state.registers.uses, left_id, state.position) != X86_NO_NEXT_USE) {
            let choice: X86RegisterChoice = x86_choose_register_avoiding(ref program, ref state.registers, state.position, left.register, right_register);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            destination = choice.register;
            x86_move_scalar(ref output, destination, left.register, size);
        }

        if (immediate) {
            let group: Int = 4;
            if (instruction.opcode == WirOpcode.BitOr) { group = 1; }
            else if (instruction.opcode == WirOpcode.BitXor) { group = 6; }
            x86_bitwise_register_imm(ref output, destination, UInt32(right.integer), group, size == 8);
        } else if (instruction.opcode == WirOpcode.BitAnd) {
            x86_and_register_width(ref output, destination, right_register, size == 8);
        } else if (instruction.opcode == WirOpcode.BitOr) {
            x86_or_register_width(ref output, destination, right_register, size == 8);
        } else {
            x86_xor_register_width(ref output, destination, right_register, size == 8);
        }
        x86_normalize_scalar(ref output, destination, size, result_type.kind == WirTypeKind.SignedInt);
        x86_bind_register(ref state.registers, destination, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.ShiftLeft || instruction.opcode == WirOpcode.SignedShiftRight || instruction.opcode == WirOpcode.UnsignedShiftRight) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "shift instruction has the wrong operand count";
        }
        let result_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        if ((result_type.kind != WirTypeKind.SignedInt && result_type.kind != WirTypeKind.UnsignedInt) || size == 0) {
            return "the x86_64 lowering supports integer shifts up to 64 bits";
        }
        let left_id: WirValueID = instruction.operands[0];
        let right_id: WirValueID = instruction.operands[1];
        let right: WirValue = program.arena.values[wir_id_index(UInt32(right_id))];
        let left: X86RegisterResult = x86_materialize_register(ref program, ref function, left_id, slots, ref state, ref output);
        if (left.message.length() != 0) { return left.message; }

        let right_register: X86Register = X86Register.None;
        if (right.kind != WirValueKind.Integer) {
            let loaded_right: X86RegisterResult = x86_materialize_register_except(ref program, ref function, right_id, slots, ref state, left.register, ref output);
            if (loaded_right.message.length() != 0) { return loaded_right.message; }
            right_register = loaded_right.register;
            x86_mov_register32(ref output, X86Register.RCX, right_register);
        }

        let destination: X86Register = left.register;
        if (x86_next_use(ref state.registers.uses, left_id, state.position) != X86_NO_NEXT_USE) {
            let choice: X86RegisterChoice = x86_choose_register_avoiding(ref program, ref state.registers, state.position, left.register, right_register);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            destination = choice.register;
            x86_move_scalar(ref output, destination, left.register, size);
        }

        let group: Int = 4;
        if (instruction.opcode == WirOpcode.UnsignedShiftRight) { group = 5; }
        else if (instruction.opcode == WirOpcode.SignedShiftRight) { group = 7; }
        if (right.kind == WirValueKind.Integer) {
            x86_shift_register_imm8(ref output, destination, Byte(UInt32(right.integer) & 255U), group, size == 8);
        } else {
            x86_shift_register_cl(ref output, destination, group, size == 8);
        }
        x86_normalize_scalar(ref output, destination, size, result_type.kind == WirTypeKind.SignedInt);
        x86_bind_register(ref state.registers, destination, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.SignedDivide || instruction.opcode == WirOpcode.UnsignedDivide ||
        instruction.opcode == WirOpcode.SignedRemainder || instruction.opcode == WirOpcode.UnsignedRemainder) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
            return "division instruction has the wrong operand count";
        }
        let result_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        if ((result_type.kind != WirTypeKind.SignedInt && result_type.kind != WirTypeKind.UnsignedInt) || size == 0) {
            return "the x86_64 lowering supports integer division up to 64 bits";
        }
        let right: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[1], slots, ref state, ref output);
        if (right.message.length() != 0) { return right.message; }
        x86_move_scalar(ref output, X86Register.RCX, right.register, size);

        let left: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (left.message.length() != 0) { return left.message; }
        let prepare_error: String = x86_prepare_fixed_register(ref program, ref state, X86Register.RAX, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        if (left.register != X86Register.RAX) { x86_move_scalar(ref output, X86Register.RAX, left.register, size); }

        let signed: Bool = instruction.opcode == WirOpcode.SignedDivide || instruction.opcode == WirOpcode.SignedRemainder;
        x86_prepare_dividend(ref output, size == 8, signed);
        x86_div_register_width(ref output, X86Register.RCX, size == 8, signed);
        if (instruction.opcode == WirOpcode.SignedRemainder || instruction.opcode == WirOpcode.UnsignedRemainder) {
            x86_move_scalar(ref output, X86Register.RAX, X86Register.RDX, size);
        }
        x86_normalize_scalar(ref output, X86Register.RAX, size, result_type.kind == WirTypeKind.SignedInt);
        x86_bind_register(ref state.registers, X86Register.RAX, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.Negate || instruction.opcode == WirOpcode.Not) {
        if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
            return "unary instruction has the wrong operand count";
        }
        let result_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        let size: Int = x86_scalar_size(ref program, instruction.type_id);
        let integer: Bool = result_type.kind == WirTypeKind.SignedInt || result_type.kind == WirTypeKind.UnsignedInt;
        if (size == 0 || (!integer && result_type.kind != WirTypeKind.BoolType) ||
            (instruction.opcode == WirOpcode.Negate && !integer)) {
            return "the x86_64 lowering cannot apply this unary operation to the result type";
        }
        let source_id: WirValueID = instruction.operands[0];
        let source: X86RegisterResult = x86_materialize_register(ref program, ref function, source_id, slots, ref state, ref output);
        if (source.message.length() != 0) { return source.message; }
        let destination: X86Register = source.register;
        if (x86_next_use(ref state.registers.uses, source_id, state.position) != X86_NO_NEXT_USE) {
            let choice: X86RegisterChoice = x86_choose_register_except(ref program, ref state.registers, state.position, source.register);
            let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
            destination = choice.register;
            x86_move_scalar(ref output, destination, source.register, size);
        }
        if (instruction.opcode == WirOpcode.Negate) { x86_unary_register(ref output, destination, 3, size == 8); }
        else if (result_type.kind == WirTypeKind.BoolType) { x86_bitwise_register_imm32(ref output, destination, 1U, 6); }
        else { x86_unary_register(ref output, destination, 2, size == 8); }
        x86_normalize_scalar(ref output, destination, size, result_type.kind == WirTypeKind.SignedInt);
        x86_bind_register(ref state.registers, destination, instruction.result);
        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.FloatLess || instruction.opcode == WirOpcode.FloatLessEqual ||
        instruction.opcode == WirOpcode.FloatGreater || instruction.opcode == WirOpcode.FloatGreaterEqual ||
        ((instruction.opcode == WirOpcode.Equal || instruction.opcode == WirOpcode.NotEqual) && instruction.operands.length() == 2 &&
         x86_scalar_float(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id))) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE || instruction.type_id != program.bool_type) {
            return "floating comparison has an invalid result or operand count";
        }
        let left_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        let right_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))];
        if (left_value.type_id != right_value.type_id || !x86_scalar_float(ref program, left_value.type_id)) {
            return "floating comparison requires matching f32 or f64 operands";
        }
        let left: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (left.message.length() != 0) { return left.message; }
        let right: X86RegisterResult = x86_materialize_register_except(ref program, ref function, instruction.operands[1], slots, ref state, left.register, ref output);
        if (right.message.length() != 0) { return right.message; }
        let choice: X86RegisterChoice = x86_choose_register(ref program, ref state.registers, state.position);
        let prepare_error = x86_prepare_register(ref program, ref state, choice, ref output);
        if (prepare_error.length() != 0) { return prepare_error; }
        let comparison: X86Opcode = X86Opcode.Je;
        if (instruction.opcode == WirOpcode.NotEqual) { comparison = X86Opcode.Jne; }
        else if (instruction.opcode == WirOpcode.FloatLess) { comparison = X86Opcode.Jb; }
        else if (instruction.opcode == WirOpcode.FloatLessEqual) { comparison = X86Opcode.Jbe; }
        else if (instruction.opcode == WirOpcode.FloatGreater) { comparison = X86Opcode.Ja; }
        else if (instruction.opcode == WirOpcode.FloatGreaterEqual) { comparison = X86Opcode.Jae; }
        let parity: X86RegisterChoice = X86RegisterChoice(register=X86Register.None, evicted=NO_WIR_VALUE);
        if (comparison != X86Opcode.Ja && comparison != X86Opcode.Jae) {
            parity = x86_choose_register_except(ref program, ref state.registers, state.position, choice.register);
            prepare_error = x86_prepare_register(ref program, ref state, parity, ref output);
            if (prepare_error.length() != 0) { return prepare_error; }
        }
        if (!x86_sse_compare(ref output, left.register, right.register, x86_scalar_size(ref program, left_value.type_id)) ||
            !x86_set_condition_register(ref output, choice.register, comparison)) {
            return "the x86_64 encoder rejected the floating comparison";
        }
        // unordered sets ZF, CF and PF; only != accepts that result
        if (parity.register != X86Register.None) {
            let condition: X86Opcode = X86Opcode.Jnp;
            if (comparison == X86Opcode.Jne) { condition = X86Opcode.Jp; }
            x86_set_condition_register(ref output, parity.register, condition);
            if (comparison == X86Opcode.Jne) { x86_or_register_width(ref output, choice.register, parity.register, false); }
            else { x86_and_register_width(ref output, choice.register, parity.register, false); }
        }
        x86_bind_register(ref state.registers, choice.register, instruction.result);
        state.accumulator = instruction.result;
        // branch lowering tests the materialized Bool, not the unordered SSE flags
        return "";
    }

    let comparison: X86Opcode = x86_comparison_opcode(instruction.opcode);
    if (comparison != X86Opcode.Invalid) {
        if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE || instruction.type_id != program.bool_type) {
            return "comparison instruction has an invalid result or operand count";
        }
        let right_id: WirValueID = instruction.operands[1];
        let right: WirValue = program.arena.values[wir_id_index(UInt32(right_id))];
        let left_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        if (x86_scalar_float(ref program, left_value.type_id)) { return "floating comparisons are not yet supported by the machine backend"; }
        let size: Int = x86_scalar_size(ref program, left_value.type_id);
        if (size == 0) { return "the x86_64 lowering cannot compare this value type"; }
        let left: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
        if (left.message.length() != 0) {
            return left.message;
        }
        let result_register: X86Register = X86Register.None;
        if (x86_next_use(ref state.registers.uses, instruction.operands[0], state.position) == X86_NO_NEXT_USE) {
            result_register = left.register;
        }

        if (x86_integer_immediate(right, size)) {
            // narrow registers are extended to 32 bits; compare constants in the same form
            let immediate: UInt32 = UInt32(right.integer);
            if (size == 1) {
                immediate &= 255U;
                if (x86_scalar_signed(ref program, right.type_id) && (immediate & 128U) != 0U) { immediate |= 4294967040U; }
            } else if (size == 2) {
                immediate &= 65535U;
                if (x86_scalar_signed(ref program, right.type_id) && (immediate & 32768U) != 0U) { immediate |= 4294901760U; }
            }
            x86_cmp_register_imm(ref output, left.register, immediate, size == 8);
        } else {
            let loaded_right: X86RegisterResult = x86_materialize_register_except(ref program, ref function, right_id, slots, ref state, left.register, ref output);
            if (loaded_right.message.length() != 0) { return loaded_right.message; }
            if (size == 8) { x86_cmp_register64(ref output, left.register, loaded_right.register); }
            else { x86_cmp_register32(ref output, left.register, loaded_right.register); }
            if (result_register == X86Register.None && x86_next_use(ref state.registers.uses, right_id, state.position) == X86_NO_NEXT_USE) {
                result_register = loaded_right.register;
            }
        }
        let choice: X86RegisterChoice = X86RegisterChoice(register=X86Register.None, evicted=NO_WIR_VALUE);
        if (result_register != X86Register.None) {
            // cmp has consumed both operands, so setcc can reuse a dead operand register
            x86_clear_register(ref state.registers, result_register);
            choice = X86RegisterChoice(register=result_register, evicted=NO_WIR_VALUE);
        } else {
            choice = x86_choose_register(ref program, ref state.registers, state.position);
        }
        let prepare_error: String = x86_prepare_register(ref program, ref state, choice, ref output);
        if (prepare_error.length() != 0) {
            return prepare_error;
        }

        if (!x86_set_condition_register(ref output, choice.register, comparison)) {
            return "the x86_64 encoder rejected the comparison condition";
        }

        x86_bind_register(ref state.registers, choice.register, instruction.result);

        state.accumulator = instruction.result;
        state.flags_value = instruction.result;
        state.flags_opcode = comparison;
        return "";
    }

    if (instruction.opcode == WirOpcode.Call) {
        if (instruction.operands.length() == 0 || instruction.call_type == NO_WIR_TYPE) {
            return "call requires a target and a function signature";
        }

        let callee: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        let callee_type: WirType = program.arena.types[wir_id_index(UInt32(callee.type_id))];
        if (callee_type.kind != WirTypeKind.Function && callee_type.kind != WirTypeKind.Pointer) {
            return "the x86_64 call target must be a function address";
        }

        let signature: WirType = program.arena.types[wir_id_index(UInt32(instruction.call_type))];
        if (signature.kind != WirTypeKind.Function || signature.variadic ||
            instruction.operands.length() - 1 != signature.parameters.length()) {
            return "the x86_64 call lowering requires a fixed-arity function signature";
        }
        let storage: X86CallStorage = x86_call_storage(ref program, signature, state.layouts);
        if (storage.size < 0) {
            return "call storage exceeds the addressable stack frame";
        }
        let hidden: Bool = storage.result >= 0;
        if (instruction.result != NO_WIR_VALUE && !hidden && x86_abi_size(ref program, instruction.type_id, state.layouts) == 0) {
            return "call result requires an unsupported machine ABI representation";
        }
        let save_error: String = x86_save_live_registers(ref program, slots, instruction.operands, ref state, ref output);
        if (save_error.length() != 0) {
            return save_error;
        }
        let argument_index: Int = 0;
        // copies cannot use SSA homes, one value may be passed more than once
        while (argument_index < signature.parameters.length()) {
            if (storage.arguments[argument_index] >= 0) {
                let copy_error = x86_store_value(ref program, ref function, instruction.operands[argument_index + 1], X86Register.RSP, storage.arguments[argument_index], slots, ref state, ref output);
                if (copy_error.length() != 0) {
                    return copy_error;
                }
            }
            argument_index++;
        }
        if hidden {
            x86_lea(ref output, X86Register.RCX, X86Register.RSP, X86Register.None, 1, storage.result);
        }

        argument_index = 0;
        while (argument_index < signature.parameters.length()) {
            let size: Int = x86_abi_size(ref program, signature.parameters[argument_index], state.layouts);
            let argument: X86RegisterResult = X86RegisterResult(register=X86Register.None, message="");
            if (storage.arguments[argument_index] >= 0) {
                size = 8;
                let choice: X86RegisterChoice = x86_choose_register(ref program, ref state.registers, state.position);
                let prepare_error = x86_prepare_register(ref program, ref state, choice, ref output);
                if (prepare_error.length() != 0) {
                    return prepare_error;
                }

                x86_lea(ref output, choice.register, X86Register.RSP, X86Register.None, 1, storage.arguments[argument_index]);
                argument.register = choice.register;
            } else {
                if (size == 0) {
                    return "call argument requires an unsupported machine ABI representation";
                }
                argument = x86_materialize_abi_value(ref program, ref function, instruction.operands[argument_index + 1], slots, ref state, ref output);
            }
            if (argument.message.length() != 0) {
                return argument.message;
            }

            let position: Int = argument_index;
            if hidden {
                position++;
            }
            if (position < 4) {
                let destination: X86Register = x86_win64_argument_register(position, x86_scalar_float(ref program, signature.parameters[argument_index]));
                if (destination == X86Register.None) {
                    return "the x86_64 ABI has no register for this argument";
                }
                if (argument.register != destination) {
                    x86_move_scalar(ref output, destination, argument.register, size);
                }
            } else {
                let offset: Int = x86_win64_stack_arg_offset(position);
                if (offset < 0) {
                    return "the x86_64 ABI has no stack location for this argument";
                }
                x86_store_scalar(ref output, argument.register, X86Register.RSP, offset, size);
            }
            argument_index += 1;
        }

        if (callee.kind == WirValueKind.Function) {
            let target_function: WirFuncID = WirFuncID(callee.owner);
            calls.append(X86CallFixup(offset=x86_call_rel32(ref output), target=target_function));
        } else {
            // scratch registers do not overlap the four win64 argument registers
            let target: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
            if (target.message.length() != 0) {
                return target.message;
            }
            if (!x86_call_register(ref output, target.register)) {
                return "the x86_64 encoder rejected the indirect call target";
            }
        }

        // all allocator registers are caller-saved, including reloaded arguments
        x86_reset_registers(ref state.registers);
        if (instruction.result != NO_WIR_VALUE) {
            if (x86_wide_integer(ref program, instruction.type_id)) {
                let home = x86_stack_offset(ref state.stack, instruction.result);
                if (home == 0 || !x86_sse_vector_memory(ref output, X86Register.XMM0, X86Register.RBP, home, false)) {
                    return "cannot save a 128-bit integer call result";
                }
            } else if (x86_aggregate_type(ref program, instruction.type_id)) {
                let home = x86_stack_offset(ref state.stack, instruction.result);
                if (home == 0) { return "aggregate call result has no storage"; }
                if (hidden) {
                    let layout: WirTypeLayout = state.layouts[wir_id_index(UInt32(instruction.type_id))];
                    if (!x86_copy_memory(ref output, X86Register.RBP, home, X86Register.RSP, storage.result, Int(layout.size), X86Register.RAX)) {
                        return "cannot copy indirect call result";
                    }
                } else {
                    x86_store_scalar(ref output, X86Register.RAX, X86Register.RBP, home, x86_abi_size(ref program, instruction.type_id, state.layouts));
                }
            } else if (x86_scalar_float(ref program, instruction.type_id)) {
                let choice: X86RegisterChoice = x86_choose_register_class(ref program, ref state.registers, state.position, X86Register.None, true);
                x86_move_scalar(ref output, choice.register, X86Register.XMM0, x86_scalar_size(ref program, instruction.type_id));
                x86_bind_register(ref state.registers, choice.register, instruction.result);
            } else {
                x86_normalize_scalar(ref output, X86Register.RAX, x86_scalar_size(ref program, instruction.type_id), x86_scalar_signed(ref program, instruction.type_id));
                x86_bind_register(ref state.registers, X86Register.RAX, instruction.result);
            }
        }

        state.accumulator = instruction.result;
        return "";
    }

    if (instruction.opcode == WirOpcode.Trap || instruction.opcode == WirOpcode.Unreachable) {
        if (instruction.operands.length() != 0 || instruction.result != NO_WIR_VALUE) {
            return "trap instruction cannot have operands or a result";
        }
        x86_trap(ref output);
        state.accumulator = NO_WIR_VALUE;
        return "";
    }

    if (instruction.opcode == WirOpcode.Jump) {
        if (instruction.operands.length() != 0 || instruction.edges.length() != 1) {
            return "jump instruction has an unsupported edge shape";
        }
        let move_error: String = x86_emit_edge_moves(ref program, ref function, instruction.edges[0], slots, scratch, state, ref output);
        if (move_error.length() != 0) {
            return move_error;
        }

        fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[0].target));
        return "";
    }

    if (instruction.opcode == WirOpcode.Branch) {
        if (instruction.operands.length() != 1 || instruction.edges.length() != 2) {
            return "branch instruction has an unsupported edge shape";
        }

        let condition: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
        if (condition.kind == WirValueKind.BoolValue) {
            let edge = 1;
            if (condition.integer != UInt128(0U)) {
                edge = 0;
            }

            let move_error: String = x86_emit_edge_moves(ref program, ref function, instruction.edges[edge], slots, scratch, state, ref output);
            if (move_error.length() != 0) {
                return move_error;
            }

            fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[edge].target));
            return "";
        }

        if (instruction.operands[0] != state.flags_value || state.flags_opcode == X86Opcode.Invalid) {
            let condition_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
            if (condition_value.type_id != program.bool_type) { return "branch condition is not Bool"; }
            let condition_register: X86RegisterResult = x86_materialize_register(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
            if (condition_register.message.length() != 0) { return condition_register.message; }
            x86_test_register_width(ref output, condition_register.register, condition_register.register, false);
            state.flags_opcode = X86Opcode.Jne;
        }
        if (instruction.edges[0].arguments.length() == 0 && instruction.edges[1].arguments.length() == 0) {
            let direct_patch: Int = x86_jump_if_rel32(ref output, state.flags_opcode);
            if (direct_patch < 0) {
                return "the x86_64 encoder rejected the branch condition";
            }

            fixups.append(X86BranchFixup(offset=direct_patch, target=instruction.edges[0].target));
            fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[1].target));
            return "";
        }

        let true_patch: Int = x86_jump_if_rel32(ref output, state.flags_opcode);
        if (true_patch < 0) {
            return "the x86_64 encoder rejected the branch condition";
        }

        let false_move_error: String = x86_emit_edge_moves(ref program, ref function, instruction.edges[1], slots, scratch, state, ref output);
        if (false_move_error.length() != 0) {
            return false_move_error;
        }

        fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[1].target));

        let true_offset: Int = output.bytes.length();
        if (!x86_patch_i32(ref output, true_patch, true_offset - (true_patch + 4))) {
            return "the x86_64 lowering could not resolve the true edge transfer";
        }
        let true_move_error: String = x86_emit_edge_moves(ref program, ref function, instruction.edges[0], slots, scratch, state, ref output);
        if (true_move_error.length() != 0) {
            return true_move_error;
        }

        fixups.append(X86BranchFixup(offset=x86_jump_rel32(ref output), target=instruction.edges[0].target));
        return "";
    }

    if (instruction.opcode == WirOpcode.Return) {
        if (instruction.operands.length() == 1) {
            let value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
            if (x86_wide_integer(ref program, value.type_id)) {
                let home = x86_stack_offset(ref state.stack, instruction.operands[0]);
                if (home != 0) {
                    if (!x86_sse_vector_memory(ref output, X86Register.XMM0, X86Register.RBP, home, true)) {
                        return "cannot load a 128-bit integer return value";
                    }
                } else {
                    let load_error = x86_load_wide_half(ref program, instruction.operands[0], false, X86Register.RAX, ref state, ref output);
                    if (load_error.length() == 0) { load_error = x86_load_wide_half(ref program, instruction.operands[0], true, X86Register.R10, ref state, ref output); }
                    if (load_error.length() != 0 || !x86_sse_bits(ref output, X86Register.XMM0, X86Register.RAX, 8, true) ||
                        !x86_sse_bits(ref output, X86Register.XMM1, X86Register.R10, 8, true) ||
                        !x86_sse_pair(ref output, X86Register.XMM0, X86Register.XMM1)) {
                        return "cannot encode a 128-bit integer return value";
                    }
                }
                if (frame_size > 0) { x86_frame_leave(ref output); }
                x86_return(ref output);
                return "";
            }
            if (x86_indirect_aggregate(ref program, value.type_id, state.layouts)) {
                if (state.return_pointer == 0) { return "indirect return has no saved destination"; }
                let copy_error = x86_prepare_fixed_register(ref program, ref state, X86Register.R10, ref output);
                if (copy_error.length() != 0) { return copy_error; }
                x86_load_scalar(ref output, X86Register.R10, X86Register.RBP, state.return_pointer, 8, false);
                copy_error = x86_store_value(ref program, ref function, instruction.operands[0], X86Register.R10, 0, slots, ref state, ref output);
                if (copy_error.length() != 0) { return copy_error; }
                x86_mov_register64(ref output, X86Register.RAX, X86Register.R10);
                x86_frame_leave(ref output);
                x86_return(ref output);
                return "";
            }
            let size: Int = x86_abi_size(ref program, value.type_id, state.layouts);
            if (size == 0) { return "unsupported return operand in the x86_64 lowering"; }
            let returned: X86RegisterResult = x86_materialize_abi_value(ref program, ref function, instruction.operands[0], slots, ref state, ref output);
            if (returned.message.length() != 0) {
                return returned.message;
            }

            let destination: X86Register = X86Register.RAX;
            if (x86_scalar_float(ref program, value.type_id)) {
                destination = X86Register.XMM0;
            }
            if (returned.register != destination) {
                x86_move_scalar(ref output, destination, returned.register, size);
            }

            if (frame_size > 0) {
                x86_frame_leave(ref output);
            }

            x86_return(ref output);
            return "";
        }
        if (instruction.operands.length() == 0) {
            if (frame_size > 0) {
                x86_frame_leave(ref output);
            }

            x86_return(ref output);
            return "";
        }

        return "return instruction has the wrong operand count";
    }

    return "unsupported instruction in the initial x86_64 lowering";
}

func x86_lower_function(ref program: WirModule, function_id: WirFuncID) -> X86LoweringResult {
    return x86_lower_function_with_layouts(ref program, function_id, x86_type_layouts(ref program), x86_find_function(ref program, "__wl_retain"), x86_find_function(ref program, "__wl_release"), x86_find_function(ref program, "__wl_fail_null"), x86_find_function(ref program, "__wl_fail_bounds"));
}

func x86_lower_function_with_layouts(ref program: WirModule, function_id: WirFuncID, layouts: Vector(WirTypeLayout), retain_function: WirFuncID, release_function: WirFuncID, null_function: WirFuncID, bounds_function: WirFuncID) -> X86LoweringResult {
    if (program.target != "x86_64-pc-windows-msvc" || program.pointer_bits != 64 || !program.data_layout.valid || program.data_layout.pointer_bits != 64) {
        return x86_lowering_error("the machine backend currently requires x86_64-pc-windows-msvc");
    }
    let function_index: Int = wir_id_index(UInt32(function_id));
    if (function_index < 0 || function_index >= program.arena.functions.length()) {
        return x86_lowering_error("function id is outside the WIR function table");
    }

    let function: WirFunction = program.arena.functions[function_index];
    if (function.linkage == WirLinkage.External) {
        return x86_lowering_error("external functions do not have machine code");
    }
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    let indirect_return = x86_indirect_aggregate(ref program, signature.result, layouts);
    let order: Vector(WirBlockID) = x86_block_order(function);
    if (order.length() == 0 || order.length() != function.blocks.length()) {
        return x86_lowering_error("the x86_64 lowering could not find the function entry block");
    }

    let analysis: X86FunctionAnalysis = x86_analyze_function(ref program, function_id, function, order, layouts);
    if (analysis.message.length() != 0) {
        return x86_lowering_error(analysis.message);
    }

    let located_values: Int = analysis.located_values;
    let home_parameters: Bool = analysis.home_parameters;
    if indirect_return {
        home_parameters = true;
    }
    let cross: X86ValueFlags = x86_cross_block_values(ref program, order);
    let block_index: Int = 0;
    while (block_index < order.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(order[block_index]))];
    
        let i = 0;
        while (i < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[i]))];
            if (instruction.result != NO_WIR_VALUE && instruction.opcode != WirOpcode.StackAlloc &&
                (x86_flag(cross, instruction.result) || x86_memory_value(ref program, instruction.type_id))) {
                located_values++;
            }

            i++;
        }

        block_index++;
    }
    let uses: X86UseTable = x86_collect_uses(ref program, order);
    let slots: Vector(X86StackSlot) = x86_stack_slots_with_uses(ref program, function, order, home_parameters, cross, layouts, uses);
    if (home_parameters) { located_values += function.parameters.length(); }
    if (slots.length() != located_values) { return x86_lowering_error("the x86_64 lowering could not lay out a stack slot"); }
    let value_range: X86ValueRange = x86_function_value_range(ref program, order);
    let stack: X86StackIndex = x86_stack_index(slots, value_range);
    let scratch: Vector(Int) = x86_edge_scratch(ref program, order, slots, layouts, analysis.edge_scratch);
    if (scratch.length() != analysis.edge_scratch) { return x86_lowering_error("the x86_64 lowering could not lay out edge staging storage"); }
    let register_plan: X86RegisterPlan = x86_register_plan(uses);
    let register_count: Int = 3;

    // the smaller register bank gives a conservative mixed-class spill bound
    if (analysis.has_float) {
        register_count = 2;
    }
    let spill_count: Int = x86_spill_capacity(ref program, order, ref uses, register_count);

    // fixed scratch registers may still contain live values, reserve their spills too
    if (analysis.integer_division) {
        spill_count += 1;
    }
    if (analysis.u64_cast) {
        spill_count += 1;
    }
    if (analysis.float_negate) {
        spill_count += 3;
    }
    if (analysis.wide_operation) {
        spill_count += 3;
    }
    let spill_locations: Vector(Int) = x86_spill_locations(slots, scratch, spill_count);
    let spill_plan: X86SpillPlan = x86_spill_plan_for_range(spill_locations, value_range);

    let frame_size: Int = x86_stack_frame_size(slots, scratch, spill_locations);
    let return_pointer = 0;
    if indirect_return {
        frame_size = x86_align_frame_offset(frame_size + 8, 16);
        return_pointer = -frame_size;
    }
    let call_frame: Int = analysis.call_frame;
    if (call_frame < 0 || call_frame > 2147483632 - frame_size) {
        return x86_lowering_error("outgoing call storage exceeds the addressable stack frame");
    }
    if (call_frame > 0) {
        frame_size = x86_align_frame_offset(frame_size + call_frame, 16);
    }
    let output: X86CodeBuffer = x86_new_code_buffer();
    let offsets: Vector(X86BlockOffset) = [];
    let fixups: Vector(X86BranchFixup) = [];
    let calls: Vector(X86CallFixup) = [];
    let position: Int = 0;
    if (frame_size > 0) {
        x86_frame_enter(ref output, frame_size);
    }
    if indirect_return {
        x86_store_scalar(ref output, X86Register.RCX, X86Register.RBP, return_pointer, 8);
    }
    if (home_parameters && !x86_home_parameters(ref program, function, stack, layouts, ref output)) {
        return x86_lowering_error("the x86_64 lowering could not save function parameters");
    }

    block_index = 0;
    while (block_index < order.length()) {
        let block_id: WirBlockID = order[block_index];
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];
        offsets.append(X86BlockOffset(block=block_id, offset=output.bytes.length()));
        // fixed homes survive block boundaries; transient register and spill bindings do not
        x86_reset_registers(ref register_plan);
        x86_reset_spills(ref spill_plan);

        let state: X86BlockState = X86BlockState(accumulator=NO_WIR_VALUE, flags_value=NO_WIR_VALUE, flags_opcode=X86Opcode.Invalid, registers=register_plan, spills=spill_plan, stack=stack, layouts=layouts, retain_function=retain_function, release_function=release_function, null_function=null_function, bounds_function=bounds_function, return_pointer=return_pointer, position=position, message="");
        let instruction_index: Int = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];
            state.message = x86_lower_instruction(ref program, ref function, ref instruction, slots, scratch, frame_size, ref state, ref output, ref fixups, ref calls);
            if (state.message.length() != 0) {
                return x86_lowering_error("function '" + function.name + "', block '" + block.name + "', instruction " + instruction_index + " (opcode " + Int(instruction.opcode) + "): " + state.message);
            }
            if (instruction.result != NO_WIR_VALUE && x86_flag(cross, instruction.result) && !x86_memory_value(ref program, instruction.type_id)) {
                // write the defining value before its register can be reused
                let register: X86Register = x86_register_for(ref state.registers, instruction.result);
                let offset: Int = x86_stack_offset(ref stack, instruction.result);
                let size: Int = x86_scalar_size(ref program, instruction.type_id);
                if (register == X86Register.None || offset == 0 || !x86_store_scalar(ref output, register, X86Register.RBP, offset, size)) {
                    return x86_lowering_error("the x86_64 lowering could not save a cross-block value");
                }
            }

            x86_consume_instruction(ref state.registers.uses, instruction, state.position);
            x86_release_dead_registers(ref state.registers, state.position);
            x86_release_dead_spills(ref state.spills, ref state.registers.uses, state.position);

            state.position += 1;
            instruction_index += 1;
        }

        position = state.position;
        block_index += 1;
    }

    if (!x86_patch_branches(ref output, offsets, fixups)) {
        return x86_lowering_error("the x86_64 lowering could not resolve a branch target");
    }

    return X86LoweringResult(bytes=output.bytes, errors=[], calls=calls, relocations=output.relocations);
}

func x86_lower_module(ref program: WirModule, verbose: Bool = false) -> X86ModuleResult {
    if (program.target != "x86_64-pc-windows-msvc" || program.pointer_bits != 64 || !program.data_layout.valid || program.data_layout.pointer_bits != 64) {
        return x86_module_error("the machine backend currently requires x86_64-pc-windows-msvc");
    }
    let codes: Vector(X86FunctionCode) = [];
    let layouts: Vector(WirTypeLayout) = x86_type_layouts(ref program);
    let relocations: Vector(X86Relocation) = [];
    let symbols: Vector(X86Symbol) = [];
    let output: X86CodeBuffer = x86_new_code_buffer();
    let reachable: WirReachability = wir_reachable_symbols(program);
    let retain_function: WirFuncID = x86_find_function(ref program, "__wl_retain");
    let release_function: WirFuncID = x86_find_function(ref program, "__wl_release");
    // checks share two runtime targets, resolve them once rather than searching
    // every function name again for each checked load and index operation.
    let null_function: WirFuncID = x86_find_function(ref program, "__wl_fail_null");
    let bounds_function: WirFuncID = x86_find_function(ref program, "__wl_fail_bounds");
    if (verbose) { print("Emitting x86-64 functions"); }
    let function_index: Int = 0;
    while (function_index < program.arena.functions.length()) {
        let function: WirFunction = program.arena.functions[function_index];
        if (reachable.functions[function_index] && function.linkage != WirLinkage.External) {
            let function_id: WirFuncID = WirFuncID(UInt32(function_index + 1));
            let lowered: X86LoweringResult = x86_lower_function_with_layouts(ref program, function_id, layouts, retain_function, release_function, null_function, bounds_function);
            if (lowered.errors.length() != 0) {
                return x86_module_error(lowered.errors[0]);
            }
            let offset: Int = output.bytes.length();
            let i: Int = 0;
            while (i < lowered.bytes.length()) {
                output.bytes.append(lowered.bytes[i]);
                i++;
            }

            codes.append(X86FunctionCode(function=function_id, offset=offset, bytes=lowered.bytes, calls=lowered.calls));
            symbols.append(X86Symbol(name=function.name, section=".text", offset=UInt32(offset), external=function.linkage == WirLinkage.Exported));
            i = 0;
            while (i < lowered.relocations.length()) {
                let relocation: X86Relocation = lowered.relocations[i];
                relocation.offset += UInt32(offset);
                relocations.append(relocation);
                i++;
            }
        }

        function_index++;
    }

    let code_index = 0;
    while (code_index < codes.length()) {
        let code: X86FunctionCode = codes[code_index];
        let call_index = 0;
        while (call_index < code.calls.length()) {
            let call: X86CallFixup = code.calls[call_index];
            let target_index: Int = wir_id_index(UInt32(call.target));
            if (target_index < 0 || target_index >= program.arena.functions.length()) {
                return x86_module_error("the x86_64 lowering could not resolve a call target");
            }

            let target: WirFunction = program.arena.functions[target_index];
            if (target.linkage == WirLinkage.External) {
                relocations.append(X86Relocation(section=".text", offset=UInt32(code.offset + call.offset), kind=X86RelocationKind.Rel32, symbol=target.name, addend=0L));
            }
            call_index++;
        }
        code_index++;
    }

    function_index = 0;
    while (function_index < program.arena.functions.length()) {
        let function: WirFunction = program.arena.functions[function_index];
        if (reachable.functions[function_index] && function.linkage == WirLinkage.External) {
            let duplicate = false;
            let symbol_index = 0;
            while (symbol_index < symbols.length()) {
                if (symbols[symbol_index].name == function.name) {
                    duplicate = true;
                }

                symbol_index++;
            }

            if (!duplicate) {
                if (x86_is_memop(function.name)) {
                    let offset: Int = output.bytes.length();
                    if (!x86_emit_memop(ref output, function.name)) { return x86_module_error("cannot emit Windows memory support"); }
                    symbols.append(X86Symbol(name=function.name, section=".text", offset=UInt32(offset), external=true));
                } else {
                    symbols.append(X86Symbol(name=function.name, section="", offset=0U, external=true));
                }
            }
        }

        function_index++;
    }
    if (!x86_patch_calls(ref program, ref output, codes)) {
        return x86_module_error("the x86_64 lowering could not resolve a direct call target");
    }
    let object: X86Object = X86Object(sections=[X86CodeSection(name=".text", bytes=output.bytes, alignment=16, executable=true, writable=false)], symbols=symbols, relocations=relocations);
    if (verbose) { print("Emitting global data"); }
    let data_error: String = x86_emit_globals(ref program, layouts, reachable.globals, ref object);
    if (data_error.length() != 0) {
        return x86_module_error(data_error);
    }
    return X86ModuleResult(bytes=output.bytes, errors=[], relocations=object.relocations, symbols=object.symbols, sections=object.sections);
}
