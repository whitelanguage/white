// src/compiler/machine/aarch64/lowering.wl
import * from "model.wl"
import * from "encoder.wl"
import a64_argument_register, a64_pair_argument_index from "abi.wl"
import * from "../../wir/model.wl"
import wir_type_layouts from "../../wir/layout.wl"
import MachineSection, MachineSymbol from "../object.wl"
import MachineDataResult, MachineDataRelocation, machine_emit_globals from "../data.wl"


struct A64LoweringResult(
    bytes: Vector(Byte),
    errors: Vector(String),
    relocations: Vector(A64Relocation)
)

struct A64ModuleResult(
    errors: Vector(String),
    sections: Vector(A64Section),
    symbols: Vector(A64Symbol),
    relocations: Vector(A64Relocation)
)

struct A64ValueMap(registers: Vector(A64Register), next_register: Int, next_float_register: Int)

struct A64RegisterPair(low: A64Register, high: A64Register)

struct A64BlockOffset(block: WirBlockID, offset: Int)

struct A64BranchFixup(
    offset: Int,
    target: WirBlockID,
    condition: A64Condition,
    conditional: Bool
)

struct A64StackSlot(value: WirValueID, offset: Int, size: Int)

struct A64StackLayout(
    storage: Vector(A64StackSlot),
    homes: Vector(A64StackSlot),
    frame_size: Int,
    result_pointer_offset: Int,
    message: String
)

struct A64HFA(
    valid: Bool,
    bits: Int,
    count: Int
)

struct A64ArgumentState(integer: Int, floating: Int, stack: Int)

struct A64ArgumentLocation(
    valid: Bool,
    on_stack: Bool,
    offset: Int,
    first: Int,
    count: Int,
    floating: Bool,
    indirect: Bool
)

func a64_lowering_error(message: String) -> A64LoweringResult {
    return A64LoweringResult(bytes=[], errors=[message], relocations=[]);
}

func a64_module_error(message: String) -> A64ModuleResult {
    return A64ModuleResult(errors=[message], sections=[], symbols=[], relocations=[]);
}

func a64_scalar_width(ref program: WirModule, type_id: WirTypeID) -> Int {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) { return 0; }

    let type: WirType = program.arena.types[index];
    if (type.kind == WirTypeKind.BoolType) { return 32; }
    if (type.kind == WirTypeKind.Pointer || type.kind == WirTypeKind.Function) { return 64; }
    if (type.kind == WirTypeKind.FloatType && (type.bits == 32 || type.bits == 64)) { return type.bits; }
    if (type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt) { return 0; }
    if (type.bits <= 0 || type.bits > 64) { return 0; }
    if (type.bits <= 32) { return 32; }

    return 64;
}

func a64_integer_width(ref program: WirModule, type_id: WirTypeID) -> Int {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) {
        return 0;
    }

    let type: WirType = program.arena.types[index];
    if (type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt) {
        return 0;
    }
    if (type.bits == 128) {
        return 128;
    }

    return a64_scalar_width(ref program, type_id);
}

func a64_integer_bits(ref program: WirModule, type_id: WirTypeID) -> Int {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) {
        return 0;
    }

    let type: WirType = program.arena.types[index];
    if (type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt) {
        return 0;
    }

    return type.bits;
}

func a64_integer_signed(ref program: WirModule, type_id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(type_id));
    return index >= 0 && index < program.arena.types.length() &&
           program.arena.types[index].kind == WirTypeKind.SignedInt;
}

func a64_value_size(ref program: WirModule, type_id: WirTypeID) -> Int {
    let width: Int = a64_integer_width(ref program, type_id);
    if (width != 0) {
        return width / 8;
    }

    width = a64_scalar_width(ref program, type_id);
    if (width == 0) {
        return 0;
    }

    return width / 8;
}

func a64_stack_value_size(ref program: WirModule, type_id: WirTypeID, layouts: Vector(WirTypeLayout)) -> Int {
    let scalar: Int = a64_value_size(ref program, type_id);
    if (scalar != 0) {
        return scalar;
    }

    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= layouts.length() || !layouts[index].valid ||
        layouts[index].size > 2147483647UL) {
        return 0;
    }

    return a64_align(Int(layouts[index].size), 8);
}

func a64_stack_value_alignment(type_id: WirTypeID, layouts: Vector(WirTypeLayout), fallback: Int) -> Int {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index >= 0 && index < layouts.length() && layouts[index].valid &&
        layouts[index].size == UInt64(fallback)) {
        return layouts[index].alignment;
    }

    return fallback;
}

func a64_scalar_float(ref program: WirModule, type_id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(type_id));
    return index >= 0 && index < program.arena.types.length() && program.arena.types[index].kind == WirTypeKind.FloatType;
}

func a64_aggregate_type(ref program: WirModule, type_id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) {
        return false;
    }

    let kind: WirTypeKind = program.arena.types[index].kind;
    return kind == WirTypeKind.Struct || kind == WirTypeKind.Array;
}

func a64_hfa_type(ref program: WirModule, type_id: WirTypeID, layouts: Vector(WirTypeLayout)) -> A64HFA {
// AAPCS64 gives homogeneous float aggregates their own V-register path. Keep
// this test on WIR layouts, source structs may already have been flattened.
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length() || index >= layouts.length()) {
        return A64HFA(valid=false, bits=0, count=0);
    }

    let type: WirType = program.arena.types[index];
    if (type.kind == WirTypeKind.FloatType && (type.bits == 32 || type.bits == 64)) {
        return A64HFA(valid=true, bits=type.bits, count=1);
    }

    if ((type.kind != WirTypeKind.Struct && type.kind != WirTypeKind.Array) ||
        !layouts[index].valid) {
        return A64HFA(valid=false, bits=0, count=0);
    }

    let bits: Int = 0;
    let count: Int = 0;
    if (type.kind == WirTypeKind.Array) {
        let element: A64HFA = a64_hfa_type(ref program, type.element, layouts);
        if (!element.valid || type.length == UIntSize(0) || type.length > UIntSize(4)) {
            return A64HFA(valid=false, bits=0, count=0);
        }

        bits = element.bits;
        count = element.count * Int(type.length);
    } else {
        let i: Int = 0;
        while (i < type.fields.length()) {
            let field: A64HFA = a64_hfa_type(ref program, type.fields[i], layouts);
            if (!field.valid || (bits != 0 && bits != field.bits)) {
                return A64HFA(valid=false, bits=0, count=0);
            }

            bits = field.bits;
            count += field.count;
            i++;
        }
    }

    let bytes: Int = bits / 8;
    if (bits == 0 || count < 1 || count > 4 ||
        layouts[index].size != UInt64(bytes * count)) {
        return A64HFA(valid=false, bits=0, count=0);
    }

    return A64HFA(valid=true, bits=bits, count=count);
}

func a64_align(value: Int, alignment: Int) -> Int {
    if (alignment <= 1) { return value; }
    return ((value + alignment - 1) / alignment) * alignment;
}

func a64_stack_argument(ref state: A64ArgumentState, size: Int, alignment: Int, indirect: Bool) -> A64ArgumentLocation {
    let aligned: Int = alignment;
    if (aligned < 8) { aligned = 8; }
    if (aligned > 16) { aligned = 16; }
    state.stack = a64_align(state.stack, aligned);

    let offset: Int = state.stack;
    let bytes: Int = size;
    if (bytes < 8) { bytes = 8; }
    state.stack += a64_align(bytes, 8);

    return A64ArgumentLocation(valid=true, on_stack=true, offset=offset, first=-1, count=0, floating=false, indirect=indirect);
}

func a64_argument_location(
    ref program: WirModule,
    type_id: WirTypeID,
    layouts: Vector(WirTypeLayout),
    ref state: A64ArgumentState
) -> A64ArgumentLocation {
// Keep this classifier shared by the caller, callee and outgoing-frame scan.
// Small changes to one side of AAPCS64 otherwise tend to produce valid objects
// which only fail after the first call with more than eight arguments.
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length() || index >= layouts.length()) {
        return A64ArgumentLocation(valid=false, on_stack=false, offset=-1, first=-1, count=0, floating=false, indirect=false);
    }

    let type: WirType = program.arena.types[index];
    let layout: WirTypeLayout = layouts[index];
    if (type.kind == WirTypeKind.Struct || type.kind == WirTypeKind.Array) {
        if (!layout.valid || layout.size == 0UL || layout.size > 2147483647UL) {
            return A64ArgumentLocation(valid=false, on_stack=false, offset=-1, first=-1, count=0, floating=false, indirect=false);
        }

        let hfa: A64HFA = a64_hfa_type(ref program, type_id, layouts);
        if (hfa.valid) {
            if (state.floating + hfa.count <= 8) {
                let first: Int = state.floating;
                state.floating += hfa.count;
                return A64ArgumentLocation(valid=true, on_stack=false, offset=-1, first=first, count=hfa.count, floating=true, indirect=false);
            }
            state.floating = 8;
            return a64_stack_argument(ref state, Int(layout.size), layout.alignment, false);
        }

        let count: Int = a64_aggregate_register_count(layout);
        if (count != 0) {
            let first: Int = a64_align_aggregate_argument(state.integer, layout);
            if (first + count <= 8) {
                state.integer = first + count;
                return A64ArgumentLocation(valid=true, on_stack=false, offset=-1, first=first, count=count, floating=false, indirect=false);
            }
            state.integer = 8;
            return a64_stack_argument(ref state, Int(layout.size), layout.alignment, false);
        }

        if (state.integer < 8) {
            let first: Int = state.integer;
            state.integer++;
            return A64ArgumentLocation(valid=true, on_stack=false, offset=-1, first=first, count=1, floating=false, indirect=true);
        }
        return a64_stack_argument(ref state, 8, 8, true);
    }

    let width: Int = a64_integer_width(ref program, type_id);
    if (width == 128) {
        let first: Int = state.integer;
        if ((first & 1) != 0) { first++; }
        if (first + 2 <= 8) {
            state.integer = first + 2;
            return A64ArgumentLocation(valid=true, on_stack=false, offset=-1, first=first, count=2, floating=false, indirect=false);
        }
        state.integer = 8;
        return a64_stack_argument(ref state, 16, 16, false);
    }

    let floating: Bool = a64_scalar_float(ref program, type_id);
    let scalar: Int = a64_scalar_width(ref program, type_id);
    if (scalar == 0) {
        return A64ArgumentLocation(valid=false, on_stack=false, offset=-1, first=-1, count=0, floating=false, indirect=false);
    }

    if floating {
        if (state.floating < 8) {
            let first: Int = state.floating;
            state.floating++;
            return A64ArgumentLocation(valid=true, on_stack=false, offset=-1, first=first, count=1, floating=true, indirect=false);
        }
        return a64_stack_argument(ref state, scalar / 8, scalar / 8, false);
    }

    if (state.integer < 8) {
        let first: Int = state.integer;
        state.integer++;
        return A64ArgumentLocation(valid=true, on_stack=false, offset=-1, first=first, count=1, floating=false, indirect=false);
    }
    return a64_stack_argument(ref state, scalar / 8, scalar / 8, false);
}

func a64_outgoing_stack(ref program: WirModule, ref function: WirFunction, layouts: Vector(WirTypeLayout)) -> Int {
    let maximum: Int = 0;
    let i: Int = 0;
    while (i < function.blocks.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(function.blocks[i]))];
        let j: Int = 0;
        while (j < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
            if (instruction.opcode == WirOpcode.Call && instruction.call_type != NO_WIR_TYPE) {
                let call_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.call_type))];
                let state: A64ArgumentState = A64ArgumentState(integer=0, floating=0, stack=0);
                let arg: Int = 0;
                while (arg < call_type.parameters.length()) {
                    let location: A64ArgumentLocation = a64_argument_location(ref program, call_type.parameters[arg], layouts, ref state);
                    if (!location.valid) { return -1; }
                    arg++;
                }
                if (state.stack > maximum) { maximum = state.stack; }
            }
            j++;
        }
        i++;
    }

    return a64_align(maximum, 16);
}

func a64_stack_layout(ref program: WirModule, ref function: WirFunction, layouts: Vector(WirTypeLayout)) -> A64StackLayout {
    let storage: Vector(A64StackSlot) = [];
    let homes: Vector(A64StackSlot) = [];
    let size: Int = a64_outgoing_stack(ref program, ref function, layouts);
    if (size < 0) {
        return A64StackLayout(storage=[], homes=[], frame_size=0, result_pointer_offset=-1, message="AArch64 call has an unsupported argument type");
    }
    let result_pointer_offset: Int = -1;
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    let result_index: Int = wir_id_index(UInt32(signature.result));
    if (result_index >= 0 && result_index < layouts.length()) {
        let result_type: WirType = program.arena.types[result_index];
        let result_layout: WirTypeLayout = layouts[result_index];
        let result_hfa: A64HFA = a64_hfa_type(ref program, signature.result, layouts);
        if ((result_type.kind == WirTypeKind.Struct || result_type.kind == WirTypeKind.Array) &&
            result_layout.valid && result_layout.size > 16UL && !result_hfa.valid) {
            size = a64_align(size, 8);
            result_pointer_offset = size;
            size += 8;
        }
    }
    let i: Int = 0;

    while (i < function.parameters.length()) {
        let param: WirValueID = function.parameters[i];
        let type_id: WirTypeID = program.arena.values[wir_id_index(UInt32(param))].type_id;
        let bytes: Int = a64_stack_value_size(ref program, type_id, layouts);
        if (bytes == 0) {
            return A64StackLayout(storage=[], homes=[], frame_size=0, result_pointer_offset=-1, message="AArch64 parameter home has an unsupported type");
        }

        size = a64_align(size, a64_stack_value_alignment(type_id, layouts, bytes));
        homes.append(A64StackSlot(value=param, offset=size, size=bytes));
        size += bytes;
        i++;
    }

    i = 0;
    while (i < function.blocks.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(function.blocks[i]))];
        let j: Int = 0;

        let param_index: Int = 0;
        while (param_index < block.parameters.length()) {
            let param: WirValueID = block.parameters[param_index];
            let type_id: WirTypeID = program.arena.values[wir_id_index(UInt32(param))].type_id;
            let bytes: Int = a64_stack_value_size(ref program, type_id, layouts);
            if (bytes == 0) {
                return A64StackLayout(storage=[], homes=[], frame_size=0, result_pointer_offset=-1, message="AArch64 block parameter home has an unsupported type");
            }

            size = a64_align(size, a64_stack_value_alignment(type_id, layouts, bytes));
            homes.append(A64StackSlot(value=param, offset=size, size=bytes));
            size += bytes;
            param_index++;
        }

        while (j < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
            if (instruction.opcode == WirOpcode.StackAlloc) {
                let pointer: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
                let bytes: Int = 0;
                if (pointer.kind == WirTypeKind.Pointer) {
                    bytes = a64_stack_value_size(ref program, pointer.element, layouts);
                }
                if (instruction.result == NO_WIR_VALUE || bytes == 0) {
                    return A64StackLayout(storage=[], homes=[], frame_size=0, result_pointer_offset=-1, message="AArch64 stack slot has an unsupported type");
                }

                size = a64_align(size, a64_stack_value_alignment(pointer.element, layouts, bytes));
                storage.append(A64StackSlot(value=instruction.result, offset=size, size=bytes));
                size += bytes;
            } else if (instruction.result != NO_WIR_VALUE) {
                let bytes: Int = a64_stack_value_size(ref program, instruction.type_id, layouts);
                if (bytes != 0) {
                    size = a64_align(size, a64_stack_value_alignment(instruction.type_id, layouts, bytes));
                    homes.append(A64StackSlot(value=instruction.result, offset=size, size=bytes));
                    size += bytes;
                }
            }

            let operand_index: Int = 0;
            while (operand_index < instruction.operands.length()) {
                let operand: WirValueID = instruction.operands[operand_index];
                let value: WirValue = program.arena.values[wir_id_index(UInt32(operand))];
                let existing: A64StackSlot = a64_find_stack_slot(homes, operand);
                if (value.kind == WirValueKind.Constant && existing.value == NO_WIR_VALUE &&
                    a64_aggregate_type(ref program, value.type_id)) {
                    let bytes: Int = a64_stack_value_size(ref program, value.type_id, layouts);
                    if (bytes == 0) {
                        return A64StackLayout(storage=[], homes=[], frame_size=0, result_pointer_offset=-1, message="AArch64 aggregate constant has an unsupported type");
                    }

                    size = a64_align(size, a64_stack_value_alignment(value.type_id, layouts, bytes));
                    homes.append(A64StackSlot(value=operand, offset=size, size=bytes));
                    size += bytes;
                }
                operand_index++;
            }
            j++;
        }
        i++;
    }

    let frame_size: Int = a64_align(size, 16);
    return A64StackLayout(storage=storage, homes=homes, frame_size=frame_size, result_pointer_offset=result_pointer_offset, message="");
}

func a64_find_stack_slot(slots: Vector(A64StackSlot), value: WirValueID) -> A64StackSlot {
    let i: Int = 0;
    while (i < slots.length()) {
        if (slots[i].value == value) { return slots[i]; }
        i++;
    }

    return A64StackSlot(value=NO_WIR_VALUE, offset=0, size=0);
}

func a64_stack_address(ref output: A64CodeBuffer, destination: A64Register, offset: Int) -> Bool {
    return a64_offset_address(ref output, destination, A64Register.SP, offset);
}

func a64_offset_address(ref output: A64CodeBuffer, destination: A64Register, base: A64Register, offset: Int) -> Bool {
    if (offset < 0 || destination == A64Register.None || destination == A64Register.SP ||
        base == A64Register.None || base == A64Register.ZR) {
        return false;
    }

    let remaining: Int = offset;
    let current: A64Register = base;
    if (remaining == 0) {
        return a64_add_immediate(ref output, destination, current, 0, true);
    }

    while (remaining != 0) {
        let amount: Int = remaining;
        if (amount > 4095) { amount = 4095; }
        if (!a64_add_immediate(ref output, destination, current, amount, true)) {
            return false;
        }
        remaining -= amount;
        current = destination;
    }

    return true;
}

func a64_load_integer_at(ref output: A64CodeBuffer, destination: A64Register, base: A64Register, offset: Int, width: Int) -> Bool {
    if (a64_load_integer(ref output, destination, base, offset, width)) {
        return true;
    }
    return a64_offset_address(ref output, A64Register.X16, base, offset) &&
           a64_load_integer(ref output, destination, A64Register.X16, 0, width);
}

func a64_store_integer_at(ref output: A64CodeBuffer, source: A64Register, base: A64Register, offset: Int, width: Int) -> Bool {
    if (a64_store_integer(ref output, source, base, offset, width)) {
        return true;
    }
    return a64_offset_address(ref output, A64Register.X16, base, offset) &&
           a64_store_integer(ref output, source, A64Register.X16, 0, width);
}

func a64_load_float_at(ref output: A64CodeBuffer, destination: A64Register, base: A64Register, offset: Int, double: Bool) -> Bool {
    if (a64_load_float(ref output, destination, base, offset, double)) {
        return true;
    }
    return a64_offset_address(ref output, A64Register.X16, base, offset) &&
           a64_load_float(ref output, destination, A64Register.X16, 0, double);
}

func a64_store_float_at(ref output: A64CodeBuffer, source: A64Register, base: A64Register, offset: Int, double: Bool) -> Bool {
    if (a64_store_float(ref output, source, base, offset, double)) {
        return true;
    }
    return a64_offset_address(ref output, A64Register.X16, base, offset) &&
           a64_store_float(ref output, source, A64Register.X16, 0, double);
}

func a64_aggregate_register_count(layout: WirTypeLayout) -> Int {
    if (!layout.valid || layout.size == 0UL || layout.size > 16UL) {
        return 0;
    }

    return (Int(layout.size) + 7) / 8;
}

func a64_align_aggregate_argument(index: Int, layout: WirTypeLayout) -> Int {
    if (layout.alignment >= 16 && index % 2 != 0) {
        return index + 1;
    }
    return index;
}

func a64_save_aggregate_registers(
    ref output: A64CodeBuffer,
    home: A64StackSlot,
    first: Int,
    count: Int
) -> Bool {
    let i: Int = 0;
    while (i < count) {
        let incoming: A64Register = a64_argument_register(first + i, false);
        if (incoming == A64Register.None ||
            !a64_store_integer_at(ref output, incoming, A64Register.SP, home.offset + i * 8, 64)) {
            return false;
        }
        i++;
    }

    return true;
}

func a64_load_aggregate_registers(
    ref output: A64CodeBuffer,
    home: A64StackSlot,
    first: Int,
    count: Int
) -> Bool {
    let i: Int = 0;
    while (i < count) {
        let outgoing: A64Register = a64_argument_register(first + i, false);
        if (outgoing == A64Register.None ||
            !a64_load_integer_at(ref output, outgoing, A64Register.SP, home.offset + i * 8, 64)) {
            return false;
        }
        i++;
    }

    return true;
}

func a64_save_hfa_registers(ref output: A64CodeBuffer, home: A64StackSlot, first: Int, hfa: A64HFA) -> Bool {
    let i: Int = 0;
    while (i < hfa.count) {
        let incoming: A64Register = a64_argument_register(first + i, true);
        if (incoming == A64Register.None ||
            !a64_store_float_at(ref output, incoming, A64Register.SP, home.offset + i * (hfa.bits / 8), hfa.bits == 64)) {
            return false;
        }
        i++;
    }

    return true;
}

func a64_load_hfa_registers(ref output: A64CodeBuffer, home: A64StackSlot, first: Int, hfa: A64HFA) -> Bool {
    let i: Int = 0;
    while (i < hfa.count) {
        let destination: A64Register = a64_argument_register(first + i, true);
        if (destination == A64Register.None ||
            !a64_load_float_at(ref output, destination, A64Register.SP, home.offset + i * (hfa.bits / 8), hfa.bits == 64)) {
            return false;
        }
        i++;
    }

    return true;
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

func a64_new_value_map(value_count: Int) -> A64ValueMap {
    let registers: Vector(A64Register) = [];
    let i: Int = 0;

    while (i < value_count) {
        registers.append(A64Register.None);
        i++;
    }

    return A64ValueMap(registers=registers, next_register=0, next_float_register=0);
}

func a64_alloc_register(ref values: A64ValueMap, floating: Bool) -> A64Register {
    if floating {
        let register: A64Register = a64_float_work_register(values.next_float_register % 7);
        values.next_float_register++;
        return register;
    }

    let register: A64Register = a64_work_register(values.next_register % 7);
    values.next_register++;

    return register;
}

func a64_bind_value(ref values: A64ValueMap, value_id: WirValueID, register: A64Register) -> Bool {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= values.registers.length()) { return false; }

    values.registers[index] = register;
    return true;
}

func a64_mapped_register(ref values: A64ValueMap, value_id: WirValueID) -> A64Register {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= values.registers.length()) { return A64Register.None; }

    return values.registers[index];
}

func a64_value_symbol(ref program: WirModule, value: WirValue) -> String {
    let owner: Int = wir_id_index(value.owner);
    if (value.kind == WirValueKind.Global && owner >= 0 && owner < program.arena.globals.length()) {
        return program.arena.globals[owner].name;
    }
    if (value.kind == WirValueKind.Function && owner >= 0 && owner < program.arena.functions.length()) {
        return program.arena.functions[owner].name;
    }

    return "";
}

func a64_materialize(
    ref program: WirModule,
    value_id: WirValueID,
    homes: Vector(A64StackSlot),
    ref values: A64ValueMap,
    ref output: A64CodeBuffer
) -> A64Register {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= program.arena.values.length()) { return A64Register.None; }

    let value: WirValue = program.arena.values[index];
    let floating: Bool = a64_scalar_float(ref program, value.type_id);
    let width: Int = a64_scalar_width(ref program, value.type_id);
    let home: A64StackSlot = a64_find_stack_slot(homes, value_id);
    if (home.value != NO_WIR_VALUE) {
        let register: A64Register = a64_alloc_register(ref values, floating);
        let loaded: Bool = false;
        if (floating) {
            loaded = a64_load_float_at(ref output, register, A64Register.SP, home.offset, width == 64);
        } else {
            loaded = a64_load_integer_at(ref output, register, A64Register.SP, home.offset, width);
        }
        if (register == A64Register.None || width == 0 || home.size != width / 8 || !loaded) {
            return A64Register.None;
        }

        return register;
    }

    if (value.kind == WirValueKind.Global || value.kind == WirValueKind.Function) {
        let register: A64Register = a64_alloc_register(ref values, false);
        if (register == A64Register.None || !a64_symbol_address(ref output, register, a64_value_symbol(ref program, value), 0L)) {
            return A64Register.None;
        }

        return register;
    }

    if (value.kind == WirValueKind.Constant) {
        let constant_index: Int = wir_id_index(value.owner);
        if (constant_index < 0 || constant_index >= program.arena.constants.length()) {
            return A64Register.None;
        }

        let constant: WirConstant = program.arena.constants[constant_index];
        if (constant.kind == WirConstKind.Address) {
            let target_index: Int = wir_id_index(UInt32(constant.target));
            if (target_index < 0 || target_index >= program.arena.values.length()) {
                return A64Register.None;
            }
            let register: A64Register = a64_alloc_register(ref values, false);
            let target: WirValue = program.arena.values[target_index];
            if (register == A64Register.None ||
                !a64_symbol_address(ref output, register, a64_value_symbol(ref program, target), constant.addend)) {
                return A64Register.None;
            }
            return register;
        }
        if (constant.kind != WirConstKind.Zero) {
            return A64Register.None;
        }

        if (floating) {
            let bits: A64Register = a64_alloc_register(ref values, false);
            let register: A64Register = a64_alloc_register(ref values, true);
            if (bits == A64Register.None || register == A64Register.None ||
                !a64_mov_immediate(ref output, bits, 0UL, width == 64) ||
                !a64_float_from_bits(ref output, register, bits, width == 64)) {
                return A64Register.None;
            }
            return register;
        }

        let register: A64Register = a64_alloc_register(ref values, false);
        if (register == A64Register.None || !a64_mov_immediate(ref output, register, 0UL, width == 64)) {
            return A64Register.None;
        }
        return register;
    }

    if (value.kind != WirValueKind.Integer && value.kind != WirValueKind.BoolValue && value.kind != WirValueKind.Null &&
        value.kind != WirValueKind.FloatValue) {
        return A64Register.None;
    }

    if (width == 0) { return A64Register.None; }

    if (floating) {
        let bits_register: A64Register = a64_alloc_register(ref values, false);
        let register: A64Register = a64_alloc_register(ref values, true);
        if (bits_register == A64Register.None || register == A64Register.None ||
            !a64_mov_immediate(ref output, bits_register, value.float_bits, width == 64) ||
            !a64_float_from_bits(ref output, register, bits_register, width == 64)) {
            return A64Register.None;
        }
        return register;
    }

    let register: A64Register = a64_alloc_register(ref values, false);
    if (register == A64Register.None) { return register; }

    let bits: UInt64 = UInt64(value.integer & UInt128(18446744073709551615UL));
    if (!a64_mov_immediate(ref output, register, bits, width == 64)) {
        return A64Register.None;
    }

    return register;
}

func a64_materialize_address(
    ref program: WirModule,
    value_id: WirValueID,
    storage: Vector(A64StackSlot),
    homes: Vector(A64StackSlot),
    ref values: A64ValueMap,
    ref output: A64CodeBuffer
) -> A64Register {
// load the address consumed by field access, casts and calls

    // form StackAlloc pointers from frame offsets, loading a scalar home here
    // would read the allocation's contents and treat those bytes as an address.
    let slot: A64StackSlot = a64_find_stack_slot(storage, value_id);
    if (slot.value != NO_WIR_VALUE) {
        let address: A64Register = a64_alloc_register(ref values, false);
        if (address == A64Register.None || !a64_stack_address(ref output, address, slot.offset)) {
            return A64Register.None;
        }

        return address;
    }

    return a64_materialize(ref program, value_id, homes, ref values, ref output);
}

func a64_alloc_pair(ref values: A64ValueMap) -> A64RegisterPair {
    let low: A64Register = a64_alloc_register(ref values, false);
    let high: A64Register = a64_alloc_register(ref values, false);

    return A64RegisterPair(low=low, high=high);
}

func a64_materialize_pair(
    ref program: WirModule,
    value_id: WirValueID,
    homes: Vector(A64StackSlot),
    ref values: A64ValueMap,
    ref output: A64CodeBuffer
) -> A64RegisterPair {
// 128-bit integers stay as a little-endian pair all the way through lowering.
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= program.arena.values.length()) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let value: WirValue = program.arena.values[index];
    if (a64_integer_width(ref program, value.type_id) != 128) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let pair: A64RegisterPair = a64_alloc_pair(ref values);
    if (pair.low == A64Register.None || pair.high == A64Register.None) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let home: A64StackSlot = a64_find_stack_slot(homes, value_id);
    if (home.value != NO_WIR_VALUE) {
        if (home.size != 16 ||
            !a64_load_integer_at(ref output, pair.low, A64Register.SP, home.offset, 64) ||
            !a64_load_integer_at(ref output, pair.high, A64Register.SP, home.offset + 8, 64)) {
            return A64RegisterPair(low=A64Register.None, high=A64Register.None);
        }

        return pair;
    }

    if (value.kind == WirValueKind.Constant) {
        let constant_index: Int = wir_id_index(value.owner);
        if (constant_index >= 0 && constant_index < program.arena.constants.length() &&
            program.arena.constants[constant_index].kind == WirConstKind.Zero &&
            a64_mov_immediate(ref output, pair.low, 0UL, true) &&
            a64_mov_immediate(ref output, pair.high, 0UL, true)) {
            return pair;
        }
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }
    if (value.kind != WirValueKind.Integer) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let low_bits: UInt64 = UInt64(value.integer & UInt128(18446744073709551615UL));
    let high_bits: UInt64 = UInt64(value.integer >> UInt128(64U));
    if (!a64_mov_immediate(ref output, pair.low, low_bits, true) ||
        !a64_mov_immediate(ref output, pair.high, high_bits, true)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    return pair;
}

func a64_materialize_pair_into(
    ref program: WirModule,
    value_id: WirValueID,
    homes: Vector(A64StackSlot),
    destination: A64RegisterPair,
    ref output: A64CodeBuffer
) -> Bool {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= program.arena.values.length() ||
        destination.low == A64Register.None || destination.high == A64Register.None) {
        return false;
    }

    let value: WirValue = program.arena.values[index];
    if (a64_integer_width(ref program, value.type_id) != 128) {
        return false;
    }

    let home: A64StackSlot = a64_find_stack_slot(homes, value_id);
    if (home.value != NO_WIR_VALUE) {
        return home.size == 16 &&
               a64_load_integer_at(ref output, destination.low, A64Register.SP, home.offset, 64) &&
               a64_load_integer_at(ref output, destination.high, A64Register.SP, home.offset + 8, 64);
    }
    if (value.kind != WirValueKind.Integer) {
        return false;
    }

    return a64_mov_immediate(ref output, destination.low, UInt64(value.integer & UInt128(18446744073709551615UL)), true) &&
           a64_mov_immediate(ref output, destination.high, UInt64(value.integer >> UInt128(64U)), true);
}

func a64_save_pair(ref output: A64CodeBuffer, homes: Vector(A64StackSlot), value: WirValueID, pair: A64RegisterPair) -> Bool {
    let home: A64StackSlot = a64_find_stack_slot(homes, value);
    if (home.value == NO_WIR_VALUE || home.size != 16 ||
        pair.low == A64Register.None || pair.high == A64Register.None) {
        return false;
    }

    return a64_store_integer_at(ref output, pair.low, A64Register.SP, home.offset, 64) &&
           a64_store_integer_at(ref output, pair.high, A64Register.SP, home.offset + 8, 64);
}

func a64_wide_binary(ref output: A64CodeBuffer, opcode: WirOpcode, destination: A64RegisterPair, left: A64RegisterPair, right: A64RegisterPair) -> Bool {
    if (opcode == WirOpcode.Add) {
        return a64_add_sub_flags(ref output, destination.low, left.low, right.low, false) &&
               a64_add_sub_carry(ref output, destination.high, left.high, right.high, false);
    }
    if (opcode == WirOpcode.Subtract) {
        return a64_add_sub_flags(ref output, destination.low, left.low, right.low, true) &&
               a64_add_sub_carry(ref output, destination.high, left.high, right.high, true);
    }

    let operation: Int = -1;
    if (opcode == WirOpcode.BitAnd) { operation = 0; }
    if (opcode == WirOpcode.BitOr) { operation = 1; }
    if (opcode == WirOpcode.BitXor) { operation = 2; }
    if (operation < 0) {
        return false;
    }

    return a64_logical_register(ref output, destination.low, left.low, right.low, operation, true) &&
           a64_logical_register(ref output, destination.high, left.high, right.high, operation, true);
}

func a64_wide_multiply(ref output: A64CodeBuffer, destination: A64RegisterPair, left: A64RegisterPair, right: A64RegisterPair, temporary: A64Register) -> Bool {
// Only the low 128 bits survive. The two cross products contribute their low
// words to the high half, UMULH supplies the missing half of low * low.
    if (!a64_multiply_register(ref output, destination.low, left.low, right.low, true) ||
        !a64_multiply_high_unsigned(ref output, destination.high, left.low, right.low) ||
        !a64_multiply_register(ref output, temporary, left.high, right.low, true) ||
        !a64_add_register(ref output, destination.high, destination.high, temporary, true) ||
        !a64_multiply_register(ref output, temporary, left.low, right.high, true)) {
        return false;
    }

    return a64_add_register(ref output, destination.high, destination.high, temporary, true);
}

func a64_apply_wide_sign(ref output: A64CodeBuffer, value: A64RegisterPair, mask: A64Register) -> Bool {
    return a64_logical_register(ref output, value.low, value.low, mask, 2, true) &&
           a64_logical_register(ref output, value.high, value.high, mask, 2, true) &&
           a64_add_sub_flags(ref output, value.low, value.low, mask, true) &&
           a64_add_sub_carry(ref output, value.high, value.high, mask, true);
}

func a64_wide_divide(ref output: A64CodeBuffer, signed: Bool, remainder: Bool) -> A64RegisterPair {
// X0:X1 starts as the dividend and becomes the quotient. X4:X5 is the
// remainder. Keeping the loop in emitted code avoids unrolling 128 rounds.
    let quotient: A64RegisterPair = A64RegisterPair(low=A64Register.X0, high=A64Register.X1);
    let divisor: A64RegisterPair = A64RegisterPair(low=A64Register.X2, high=A64Register.X3);
    let rest: A64RegisterPair = A64RegisterPair(low=A64Register.X4, high=A64Register.X5);
    let counter: A64Register = A64Register.X6;
    let bit: A64Register = A64Register.X7;
    let temporary: A64Register = A64Register.X8;
    let one: A64Register = A64Register.X9;
    let quotient_sign: A64Register = A64Register.X10;
    let remainder_sign: A64Register = A64Register.X11;
    let divisor_sign: A64Register = A64Register.X12;

    if (!a64_mov_immediate(ref output, temporary, 63UL, true)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }
    if signed {
        if (!a64_shift_register(ref output, remainder_sign, quotient.high, temporary, 1, true) ||
            !a64_shift_register(ref output, divisor_sign, divisor.high, temporary, 1, true) ||
            !a64_logical_register(ref output, quotient_sign, divisor_sign, remainder_sign, 2, true) ||
            !a64_apply_wide_sign(ref output, quotient, remainder_sign) ||
            !a64_apply_wide_sign(ref output, divisor, divisor_sign)) {
            return A64RegisterPair(low=A64Register.None, high=A64Register.None);
        }
    }

    if (!a64_mov_immediate(ref output, rest.low, 0UL, true) ||
        !a64_mov_immediate(ref output, rest.high, 0UL, true) ||
        !a64_mov_immediate(ref output, counter, 128UL, true) ||
        !a64_mov_immediate(ref output, one, 1UL, true)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let loop: Int = output.bytes.length();
    if (!a64_mov_immediate(ref output, temporary, 63UL, true) ||
        !a64_shift_register(ref output, bit, quotient.high, temporary, 2, true) ||
        !a64_shift_register(ref output, quotient.high, quotient.high, one, 0, true) ||
        !a64_shift_register(ref output, temporary, quotient.low, temporary, 2, true) ||
        !a64_logical_register(ref output, quotient.high, quotient.high, temporary, 1, true) ||
        !a64_shift_register(ref output, quotient.low, quotient.low, one, 0, true) ||
        !a64_mov_immediate(ref output, temporary, 63UL, true) ||
        !a64_shift_register(ref output, temporary, rest.low, temporary, 2, true) ||
        !a64_shift_register(ref output, rest.high, rest.high, one, 0, true) ||
        !a64_logical_register(ref output, rest.high, rest.high, temporary, 1, true) ||
        !a64_shift_register(ref output, rest.low, rest.low, one, 0, true) ||
        !a64_logical_register(ref output, rest.low, rest.low, bit, 1, true) ||
        !a64_compare_register(ref output, rest.high, divisor.high, true)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let subtract_high: Int = output.bytes.length();
    if (!a64_conditional_branch(ref output, 0, A64Condition.UnsignedHigher)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }
    let skip_high: Int = output.bytes.length();
    if (!a64_conditional_branch(ref output, 0, A64Condition.CarryClear) ||
        !a64_compare_register(ref output, rest.low, divisor.low, true)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }
    let skip_low: Int = output.bytes.length();
    if (!a64_conditional_branch(ref output, 0, A64Condition.CarryClear) ||
        !a64_patch_branch(ref output, subtract_high, output.bytes.length(), A64Condition.UnsignedHigher, true) ||
        !a64_add_sub_flags(ref output, rest.low, rest.low, divisor.low, true) ||
        !a64_add_sub_carry(ref output, rest.high, rest.high, divisor.high, true) ||
        !a64_logical_register(ref output, quotient.low, quotient.low, one, 1, true)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    let next: Int = output.bytes.length();
    if (!a64_patch_branch(ref output, skip_high, next, A64Condition.CarryClear, true) ||
        !a64_patch_branch(ref output, skip_low, next, A64Condition.CarryClear, true) ||
        !a64_add_sub_flags(ref output, counter, counter, one, true) ||
        !a64_conditional_branch(ref output, loop - output.bytes.length(), A64Condition.NotEqual)) {
        return A64RegisterPair(low=A64Register.None, high=A64Register.None);
    }

    if signed {
        if (!a64_apply_wide_sign(ref output, quotient, quotient_sign) ||
            !a64_apply_wide_sign(ref output, rest, remainder_sign)) {
            return A64RegisterPair(low=A64Register.None, high=A64Register.None);
        }
    }
    if remainder {
        return rest;
    }

    return quotient;
}

func a64_wide_unary(ref output: A64CodeBuffer, opcode: WirOpcode, destination: A64RegisterPair, source: A64RegisterPair, temporary: A64Register) -> Bool {
    if (!a64_invert_register(ref output, destination.low, source.low, true) ||
        !a64_invert_register(ref output, destination.high, source.high, true)) {
        return false;
    }
    if (opcode == WirOpcode.Not) {
        return true;
    }
    if (opcode != WirOpcode.Negate || temporary == A64Register.None ||
        !a64_mov_immediate(ref output, temporary, 1UL, true)) {
        return false;
    }

    return a64_add_sub_flags(ref output, destination.low, destination.low, temporary, false) &&
           a64_add_sub_carry(ref output, destination.high, destination.high, A64Register.ZR, false);
}

func a64_wide_compare(ref output: A64CodeBuffer, opcode: WirOpcode, destination: A64Register, first: A64Register, second: A64Register, left: A64RegisterPair, right: A64RegisterPair) -> Bool {
    if (opcode == WirOpcode.Equal || opcode == WirOpcode.NotEqual) {
        let condition: A64Condition = A64Condition.Equal;
        let operation: Int = 0;
        if (opcode == WirOpcode.NotEqual) {
            condition = A64Condition.NotEqual;
            operation = 1;
        }

        return a64_compare_register(ref output, left.low, right.low, true) &&
               a64_set_condition(ref output, destination, condition) &&
               a64_compare_register(ref output, left.high, right.high, true) &&
               a64_set_condition(ref output, first, condition) &&
               a64_logical_register(ref output, destination, destination, first, operation, false);
    }

    let high_condition: A64Condition = A64Condition.Never;
    let low_condition: A64Condition = A64Condition.Never;
    if (opcode == WirOpcode.SignedLess) { high_condition = A64Condition.SignedLess; low_condition = A64Condition.CarryClear; }
    if (opcode == WirOpcode.SignedLessEqual) { high_condition = A64Condition.SignedLess; low_condition = A64Condition.UnsignedLowerOrSame; }
    if (opcode == WirOpcode.SignedGreater) { high_condition = A64Condition.SignedGreater; low_condition = A64Condition.UnsignedHigher; }
    if (opcode == WirOpcode.SignedGreaterEqual) { high_condition = A64Condition.SignedGreater; low_condition = A64Condition.CarrySet; }
    if (opcode == WirOpcode.UnsignedLess) { high_condition = A64Condition.CarryClear; low_condition = A64Condition.CarryClear; }
    if (opcode == WirOpcode.UnsignedLessEqual) { high_condition = A64Condition.CarryClear; low_condition = A64Condition.UnsignedLowerOrSame; }
    if (opcode == WirOpcode.UnsignedGreater) { high_condition = A64Condition.UnsignedHigher; low_condition = A64Condition.UnsignedHigher; }
    if (opcode == WirOpcode.UnsignedGreaterEqual) { high_condition = A64Condition.UnsignedHigher; low_condition = A64Condition.CarrySet; }
    if (high_condition == A64Condition.Never) {
        return false;
    }

    return a64_compare_register(ref output, left.high, right.high, true) &&
           a64_set_condition(ref output, destination, high_condition) &&
           a64_set_condition(ref output, first, A64Condition.Equal) &&
           a64_compare_register(ref output, left.low, right.low, true) &&
           a64_set_condition(ref output, second, low_condition) &&
           a64_logical_register(ref output, second, second, first, 0, false) &&
           a64_logical_register(ref output, destination, destination, second, 1, false);
}

func a64_wide_shift(ref output: A64CodeBuffer, opcode: WirOpcode, destination: A64RegisterPair, source: A64RegisterPair, amount: A64Register, count: A64Register, work: A64Register, cross: A64Register) -> Bool {
// The language masks a 128-bit shift count to seven bits. Keep the two paths
// short, shifts below 64 combine both words, larger shifts move one word only.
    if (!a64_mov_register(ref output, destination.low, source.low, true) ||
        !a64_mov_register(ref output, destination.high, source.high, true) ||
        !a64_mov_immediate(ref output, work, 127UL, true) ||
        !a64_logical_register(ref output, count, amount, work, 0, true) ||
        !a64_compare_zero(ref output, count, true)) {
        return false;
    }

    let zero: Int = output.bytes.length();
    if (!a64_conditional_branch(ref output, 0, A64Condition.Equal) ||
        !a64_mov_immediate(ref output, work, 64UL, true) ||
        !a64_compare_register(ref output, count, work, true)) {
        return false;
    }

    let large: Int = output.bytes.length();
    if (!a64_conditional_branch(ref output, 0, A64Condition.CarrySet) ||
        !a64_sub_register(ref output, work, work, count, true)) {
        return false;
    }

    if (opcode == WirOpcode.ShiftLeft) {
        if (!a64_shift_register(ref output, destination.high, source.high, count, 0, true) ||
            !a64_shift_register(ref output, cross, source.low, work, 2, true) ||
            !a64_logical_register(ref output, destination.high, destination.high, cross, 1, true) ||
            !a64_shift_register(ref output, destination.low, source.low, count, 0, true)) {
            return false;
        }
    } else {
        let high_shift: Int = 2;
        if (opcode == WirOpcode.SignedShiftRight) { high_shift = 1; }
        if (!a64_shift_register(ref output, destination.low, source.low, count, 2, true) ||
            !a64_shift_register(ref output, cross, source.high, work, 0, true) ||
            !a64_logical_register(ref output, destination.low, destination.low, cross, 1, true) ||
            !a64_shift_register(ref output, destination.high, source.high, count, high_shift, true)) {
            return false;
        }
    }

    let done: Int = output.bytes.length();
    if (!a64_branch(ref output, 0, false) ||
        !a64_patch_branch(ref output, large, output.bytes.length(), A64Condition.CarrySet, true) ||
        !a64_mov_immediate(ref output, work, 63UL, true) ||
        !a64_logical_register(ref output, count, count, work, 0, true)) {
        return false;
    }

    if (opcode == WirOpcode.ShiftLeft) {
        if (!a64_shift_register(ref output, destination.high, source.low, count, 0, true) ||
            !a64_mov_immediate(ref output, destination.low, 0UL, true)) {
            return false;
        }
    } else {
        let low_shift: Int = 2;
        if (opcode == WirOpcode.SignedShiftRight) { low_shift = 1; }
        if (!a64_shift_register(ref output, destination.low, source.high, count, low_shift, true)) {
            return false;
        }
        if (opcode == WirOpcode.SignedShiftRight) {
            if (!a64_mov_immediate(ref output, work, 63UL, true) ||
                !a64_shift_register(ref output, destination.high, source.high, work, 1, true)) {
                return false;
            }
        } else if (!a64_mov_immediate(ref output, destination.high, 0UL, true)) {
            return false;
        }
    }

    let end: Int = output.bytes.length();
    return a64_patch_branch(ref output, zero, end, A64Condition.Equal, true) &&
           a64_patch_branch(ref output, done, end, A64Condition.Always, false);
}

func a64_save_home(ref output: A64CodeBuffer, homes: Vector(A64StackSlot), value: WirValueID, register: A64Register, width: Int) -> Bool {
    let home: A64StackSlot = a64_find_stack_slot(homes, value);
    if (home.value == NO_WIR_VALUE || width == 0 || home.size != width / 8) { return false; }

    if (a64_vec_code(register) >= 0) {
        return a64_store_float_at(ref output, register, A64Register.SP, home.offset, width == 64);
    }

    return a64_store_integer_at(ref output, register, A64Register.SP, home.offset, width);
}

func a64_memory_width(ref program: WirModule, type_id: WirTypeID) -> Int {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) {
        return 0;
    }

    let type: WirType = program.arena.types[index];
    if (type.kind == WirTypeKind.BoolType) { return 8; }
    if (type.kind == WirTypeKind.Pointer || type.kind == WirTypeKind.Function) { return 64; }
    if (type.kind == WirTypeKind.FloatType) { return type.bits; }
    if (type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt) { return 0; }
    if (type.bits <= 8) { return 8; }
    if (type.bits <= 16) { return 16; }
    if (type.bits <= 32) { return 32; }
    if (type.bits <= 64) { return 64; }
    if (type.bits == 128) { return 128; }

    return 0;
}

func a64_copy_chunk(source_offset: Int, destination_offset: Int, remaining: Int) -> Int {
    if (remaining >= 8 && source_offset % 8 == 0 && destination_offset % 8 == 0) { return 64; }
    if (remaining >= 4 && source_offset % 4 == 0 && destination_offset % 4 == 0) { return 32; }
    if (remaining >= 2 && source_offset % 2 == 0 && destination_offset % 2 == 0) { return 16; }
    return 8;
}

func a64_zero_memory(ref output: A64CodeBuffer, base: A64Register, offset: Int, size: Int) -> Bool {
    let written: Int = 0;
    while (written < size) {
        let width: Int = a64_copy_chunk(offset + written, offset + written, size - written);
        if (!a64_store_integer_at(ref output, A64Register.ZR, base, offset + written, width)) {
            return false;
        }
        written += width / 8;
    }

    return true;
}

func a64_copy_memory(
    ref output: A64CodeBuffer,
    destination_base: A64Register,
    destination_offset: Int,
    source_base: A64Register,
    source_offset: Int,
    size: Int,
    temporary: A64Register
) -> Bool {
    let copied: Int = 0;
    while (copied < size) {
        let width: Int = a64_copy_chunk(source_offset + copied, destination_offset + copied, size - copied);
        let loaded: Bool = a64_load_integer(ref output, temporary, source_base, source_offset + copied, width);
        if (!loaded) {
            loaded = a64_offset_address(ref output, A64Register.X16, source_base, source_offset + copied) &&
                     a64_load_integer(ref output, temporary, A64Register.X16, 0, width);
        }

        let stored: Bool = a64_store_integer(ref output, temporary, destination_base, destination_offset + copied, width);
        if (!stored) {
            stored = a64_offset_address(ref output, A64Register.X17, destination_base, destination_offset + copied) &&
                     a64_store_integer(ref output, temporary, A64Register.X17, 0, width);
        }
        if (!loaded || !stored) {
            return false;
        }
        copied += width / 8;
    }

    return true;
}

func a64_store_value_at(
    ref program: WirModule,
    value_id: WirValueID,
    base: A64Register,
    offset: Int,
    storage: Vector(A64StackSlot),
    homes: Vector(A64StackSlot),
    layouts: Vector(WirTypeLayout),
    ref values: A64ValueMap,
    ref output: A64CodeBuffer
) -> Bool {
    let value: WirValue = program.arena.values[wir_id_index(UInt32(value_id))];
    let type: WirType = program.arena.types[wir_id_index(UInt32(value.type_id))];
    let width: Int = a64_memory_width(ref program, value.type_id);

    if (type.kind == WirTypeKind.Struct || type.kind == WirTypeKind.Array) {
        let layout: WirTypeLayout = layouts[wir_id_index(UInt32(value.type_id))];
        if (!layout.valid) {
            return false;
        }

        if (value.kind == WirValueKind.Constant) {
            let constant_index: Int = wir_id_index(value.owner);
            if (constant_index < 0 || constant_index >= program.arena.constants.length()) {
                return false;
            }

            let constant: WirConstant = program.arena.constants[constant_index];
            if (constant.kind == WirConstKind.Zero) {
                return a64_zero_memory(ref output, base, offset, Int(layout.size));
            }
            if (constant.kind != WirConstKind.Aggregate ||
                !a64_zero_memory(ref output, base, offset, Int(layout.size))) {
                return false;
            }

            let stride: Int = 0;
            if (type.kind == WirTypeKind.Array) {
                let element_layout: WirTypeLayout = layouts[wir_id_index(UInt32(type.element))];
                if (!element_layout.valid || element_layout.size > 2147483647UL) {
                    return false;
                }
                stride = Int(element_layout.size);
            }

            let i: Int = 0;
            while (i < constant.elements.length()) {
                let member_offset: Int = i * stride;
                if (type.kind == WirTypeKind.Struct) {
                    if (i >= layout.field_offsets.length()) {
                        return false;
                    }
                    member_offset = Int(layout.field_offsets[i]);
                }
                if (!a64_store_value_at(
                    ref program,
                    constant.elements[i],
                    base,
                    offset + member_offset,
                    storage,
                    homes,
                    layouts,
                    ref values,
                    ref output
                )) {
                    return false;
                }
                i++;
            }
            return true;
        }

        let source: A64StackSlot = a64_find_stack_slot(homes, value_id);
        let temporary: A64Register = a64_alloc_register(ref values, false);
        return source.value != NO_WIR_VALUE && temporary != A64Register.None &&
               a64_copy_memory(
                   ref output,
                   base,
                   offset,
                   A64Register.SP,
                   source.offset,
                   Int(layout.size),
                   temporary
               );
    }

    if (width == 128) {
        let pair: A64RegisterPair = a64_materialize_pair(ref program, value_id, homes, ref values, ref output);
        return pair.low != A64Register.None && pair.high != A64Register.None &&
               a64_store_integer_at(ref output, pair.low, base, offset, 64) &&
               a64_store_integer_at(ref output, pair.high, base, offset + 8, 64);
    }

    let source: A64Register = a64_materialize_address(
        ref program,
        value_id,
        storage,
        homes,
        ref values,
        ref output
    );
    if (source == A64Register.None || width == 0) {
        return false;
    }
    if (type.kind == WirTypeKind.FloatType) {
        return a64_store_float_at(ref output, source, base, offset, width == 64);
    }

    return a64_store_integer_at(ref output, source, base, offset, width);
}

func a64_load_value_at(
    ref program: WirModule,
    type_id: WirTypeID,
    result: WirValueID,
    base: A64Register,
    offset: Int,
    homes: Vector(A64StackSlot),
    layouts: Vector(WirTypeLayout),
    ref values: A64ValueMap,
    ref output: A64CodeBuffer
) -> Bool {
    let type: WirType = program.arena.types[wir_id_index(UInt32(type_id))];
    let width: Int = a64_memory_width(ref program, type_id);

    if (type.kind == WirTypeKind.Struct || type.kind == WirTypeKind.Array) {
        let destination: A64StackSlot = a64_find_stack_slot(homes, result);
        let layout: WirTypeLayout = layouts[wir_id_index(UInt32(type_id))];
        let temporary: A64Register = a64_alloc_register(ref values, false);
        return destination.value != NO_WIR_VALUE && layout.valid && temporary != A64Register.None &&
               a64_zero_memory(ref output, A64Register.SP, destination.offset, destination.size) &&
               a64_copy_memory(
                   ref output,
                   A64Register.SP,
                   destination.offset,
                   base,
                   offset,
                   Int(layout.size),
                   temporary
               );
    }

    if (width == 128) {
        let pair: A64RegisterPair = a64_alloc_pair(ref values);
        return pair.low != A64Register.None && pair.high != A64Register.None &&
               a64_load_integer_at(ref output, pair.low, base, offset, 64) &&
               a64_load_integer_at(ref output, pair.high, base, offset + 8, 64) &&
               a64_save_pair(ref output, homes, result, pair);
    }

    let floating: Bool = type.kind == WirTypeKind.FloatType;
    let destination: A64Register = a64_alloc_register(ref values, floating);
    let loaded: Bool = false;
    if (floating) {
        loaded = a64_load_float_at(ref output, destination, base, offset, width == 64);
    } else {
        loaded = a64_load_integer_at(ref output, destination, base, offset, width);
        if (loaded && type.kind == WirTypeKind.SignedInt && width < 32) {
            loaded = a64_extend_integer(ref output, destination, destination, width, true, false);
        }
    }

    return destination != A64Register.None && loaded &&
           a64_save_home(ref output, homes, result, destination, a64_scalar_width(ref program, type_id));
}

func a64_comparison_condition(opcode: WirOpcode) -> A64Condition {
    if (opcode == WirOpcode.Equal) { return A64Condition.Equal; }
    if (opcode == WirOpcode.NotEqual) { return A64Condition.NotEqual; }
    if (opcode == WirOpcode.SignedLess) { return A64Condition.SignedLess; }
    if (opcode == WirOpcode.SignedLessEqual) { return A64Condition.SignedLessOrEqual; }
    if (opcode == WirOpcode.SignedGreater) { return A64Condition.SignedGreater; }
    if (opcode == WirOpcode.SignedGreaterEqual) { return A64Condition.SignedGreaterOrEqual; }
    if (opcode == WirOpcode.UnsignedLess) { return A64Condition.CarryClear; }
    if (opcode == WirOpcode.UnsignedLessEqual) { return A64Condition.UnsignedLowerOrSame; }
    if (opcode == WirOpcode.UnsignedGreater) { return A64Condition.UnsignedHigher; }
    if (opcode == WirOpcode.UnsignedGreaterEqual) { return A64Condition.CarrySet; }

    return A64Condition.Never;
}

func a64_is_integer_comparison(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.Equal || opcode == WirOpcode.NotEqual ||
           opcode == WirOpcode.SignedLess || opcode == WirOpcode.SignedLessEqual ||
           opcode == WirOpcode.SignedGreater || opcode == WirOpcode.SignedGreaterEqual ||
           opcode == WirOpcode.UnsignedLess || opcode == WirOpcode.UnsignedLessEqual ||
           opcode == WirOpcode.UnsignedGreater || opcode == WirOpcode.UnsignedGreaterEqual;
}

func a64_is_integer_binary(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.Add || opcode == WirOpcode.Subtract || opcode == WirOpcode.Multiply ||
           opcode == WirOpcode.BitAnd || opcode == WirOpcode.BitOr || opcode == WirOpcode.BitXor ||
           opcode == WirOpcode.ShiftLeft || opcode == WirOpcode.SignedShiftRight || opcode == WirOpcode.UnsignedShiftRight;
}

func a64_is_integer_division(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.SignedDivide || opcode == WirOpcode.UnsignedDivide ||
           opcode == WirOpcode.SignedRemainder || opcode == WirOpcode.UnsignedRemainder;
}

func a64_is_float_comparison(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.Equal || opcode == WirOpcode.NotEqual ||
           opcode == WirOpcode.FloatLess || opcode == WirOpcode.FloatLessEqual ||
           opcode == WirOpcode.FloatGreater || opcode == WirOpcode.FloatGreaterEqual;
}

func a64_float_condition(opcode: WirOpcode) -> A64Condition {
// FCMP's unordered flags make these conditions match WIR's ordered relations.
// NotEqual is unordered-or-not-equal, the same rule used by the LLVM backend.
    if (opcode == WirOpcode.Equal) { return A64Condition.Equal; }
    if (opcode == WirOpcode.NotEqual) { return A64Condition.NotEqual; }
    if (opcode == WirOpcode.FloatLess) { return A64Condition.Minus; }
    if (opcode == WirOpcode.FloatLessEqual) { return A64Condition.UnsignedLowerOrSame; }
    if (opcode == WirOpcode.FloatGreater) { return A64Condition.SignedGreater; }
    if (opcode == WirOpcode.FloatGreaterEqual) { return A64Condition.SignedGreaterOrEqual; }

    return A64Condition.Never;
}

func a64_emit_integer_binary(ref output: A64CodeBuffer, opcode: WirOpcode, destination: A64Register, left: A64Register, right: A64Register, wide: Bool) -> Bool {
    if (opcode == WirOpcode.Add) { return a64_add_register(ref output, destination, left, right, wide); }
    if (opcode == WirOpcode.Subtract) { return a64_sub_register(ref output, destination, left, right, wide); }
    if (opcode == WirOpcode.Multiply) { return a64_multiply_register(ref output, destination, left, right, wide); }
    if (opcode == WirOpcode.BitAnd) { return a64_logical_register(ref output, destination, left, right, 0, wide); }
    if (opcode == WirOpcode.BitOr) { return a64_logical_register(ref output, destination, left, right, 1, wide); }
    if (opcode == WirOpcode.BitXor) { return a64_logical_register(ref output, destination, left, right, 2, wide); }
    if (opcode == WirOpcode.ShiftLeft) { return a64_shift_register(ref output, destination, left, right, 0, wide); }
    if (opcode == WirOpcode.SignedShiftRight) { return a64_shift_register(ref output, destination, left, right, 1, wide); }
    if (opcode == WirOpcode.UnsignedShiftRight) { return a64_shift_register(ref output, destination, left, right, 2, wide); }

    return false;
}

func a64_is_float_binary(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.Add || opcode == WirOpcode.Subtract ||
           opcode == WirOpcode.Multiply || opcode == WirOpcode.FloatDivide;
}

func a64_emit_float_binary(ref output: A64CodeBuffer, opcode: WirOpcode, destination: A64Register, left: A64Register, right: A64Register, double: Bool) -> Bool {
    let operation: Int = -1;
    if (opcode == WirOpcode.Add) { operation = 0; }
    if (opcode == WirOpcode.Subtract) { operation = 1; }
    if (opcode == WirOpcode.Multiply) { operation = 2; }
    if (opcode == WirOpcode.FloatDivide) { operation = 3; }
    if (operation < 0) { return false; }

    return a64_float_binary(ref output, destination, left, right, operation, double);
}

func a64_atomic_acquire(order: WirMemoryOrder) -> Bool {
    return order == WirMemoryOrder.Acquire || order == WirMemoryOrder.AcquireRelease ||
           order == WirMemoryOrder.SequentiallyConsistent;
}

func a64_atomic_release(order: WirMemoryOrder) -> Bool {
    return order == WirMemoryOrder.Release || order == WirMemoryOrder.AcquireRelease ||
           order == WirMemoryOrder.SequentiallyConsistent;
}

func a64_emit_atomic_rmw(
    ref output: A64CodeBuffer,
    operation: WirAtomicOp,
    address: A64Register,
    input: A64Register,
    old_value: A64Register,
    new_value: A64Register,
    status: A64Register,
    width: Int,
    order: WirMemoryOrder
) -> Bool {
// AAPCS64 only promises the base ARMv8 instruction set, use an LL/SC loop
// here instead of making the whole backend depend on the optional LSE atomics.
    let retry: Int = output.bytes.length();
    let wide: Bool = width == 64;
    if (!a64_load_exclusive(ref output, old_value, address, width, a64_atomic_acquire(order))) {
        return false;
    }

    let encoded: Bool = false;
    if (operation == WirAtomicOp.Exchange) {
        encoded = a64_mov_register(ref output, new_value, input, wide);
    } else if (operation == WirAtomicOp.Add) {
        encoded = a64_add_register(ref output, new_value, old_value, input, wide);
    } else if (operation == WirAtomicOp.Subtract) {
        encoded = a64_sub_register(ref output, new_value, old_value, input, wide);
    } else if (operation == WirAtomicOp.BitAnd) {
        encoded = a64_logical_register(ref output, new_value, old_value, input, 0, wide);
    } else if (operation == WirAtomicOp.BitOr) {
        encoded = a64_logical_register(ref output, new_value, old_value, input, 1, wide);
    } else if (operation == WirAtomicOp.BitXor) {
        encoded = a64_logical_register(ref output, new_value, old_value, input, 2, wide);
    }
    if (!encoded || !a64_store_exclusive(
        ref output,
        status,
        new_value,
        address,
        width,
        a64_atomic_release(order)
    )) {
        return false;
    }

    if (!a64_compare_zero(ref output, status, false)) {
        return false;
    }

    let branch: Int = output.bytes.length();
    return a64_conditional_branch(ref output, retry - branch, A64Condition.NotEqual);
}

func a64_block_offset(offsets: Vector(A64BlockOffset), block: WirBlockID) -> Int {
    let i: Int = 0;
    while (i < offsets.length()) {
        if (offsets[i].block == block) { return offsets[i].offset; }
        i++;
    }

    return -1;
}

func a64_patch_branches(ref output: A64CodeBuffer, offsets: Vector(A64BlockOffset), fixups: Vector(A64BranchFixup)) -> Bool {
    let i: Int = 0;

    while (i < fixups.length()) {
        let fixup: A64BranchFixup = fixups[i];
        let target: Int = a64_block_offset(offsets, fixup.target);
        if (target < 0 || !a64_patch_branch(ref output, fixup.offset, target, fixup.condition, fixup.conditional)) {
            return false;
        }
        i++;
    }

    return true;
}

func a64_write_edge(ref program: WirModule, edge: WirEdge, homes: Vector(A64StackSlot), layouts: Vector(WirTypeLayout), ref values: A64ValueMap, ref output: A64CodeBuffer) -> Bool {
// Block arguments are copied through homes, this also handles swaps on loop edges.
    let block_index: Int = wir_id_index(UInt32(edge.target));
    if (block_index < 0 || block_index >= program.arena.blocks.length()) { return false; }

    let target: WirBlock = program.arena.blocks[block_index];
    if (target.parameters.length() != edge.arguments.length()) { return false; }

    let i: Int = 0;
    while (i < edge.arguments.length()) {
        let argument: WirValueID = edge.arguments[i];
        let parameter: WirValueID = target.parameters[i];
        let parameter_type: WirTypeID = program.arena.values[wir_id_index(UInt32(parameter))].type_id;
        if (a64_aggregate_type(ref program, parameter_type)) {
            let source: A64StackSlot = a64_find_stack_slot(homes, argument);
            let destination: A64StackSlot = a64_find_stack_slot(homes, parameter);
            let layout: WirTypeLayout = layouts[wir_id_index(UInt32(parameter_type))];
            let temporary: A64Register = a64_alloc_register(ref values, false);
            if (source.value == NO_WIR_VALUE || destination.value == NO_WIR_VALUE ||
                !layout.valid || temporary == A64Register.None ||
                !a64_zero_memory(ref output, A64Register.SP, destination.offset, destination.size) ||
                !a64_copy_memory(
                    ref output,
                    A64Register.SP,
                    destination.offset,
                    A64Register.SP,
                    source.offset,
                    Int(layout.size),
                    temporary
                )) {
                return false;
            }

            i++;
            continue;
        }

        let width: Int = a64_integer_width(ref program, parameter_type);
        if (width == 128) {
            let pair: A64RegisterPair = a64_materialize_pair(ref program, argument, homes, ref values, ref output);
            if (!a64_save_pair(ref output, homes, parameter, pair)) {
                return false;
            }

            i++;
            continue;
        }

        width = a64_scalar_width(ref program, parameter_type);
        let source: A64Register = a64_materialize(ref program, argument, homes, ref values, ref output);
        if (source == A64Register.None || width == 0 || !a64_save_home(ref output, homes, parameter, source, width)) {
            return false;
        }
        i++;
    }

    return true;
}

func a64_lower_function(ref program: WirModule, function_id: WirFuncID) -> A64LoweringResult {
    if (program.target != "aarch64-unknown-linux-gnu" || program.pointer_bits != 64) {
        return a64_lowering_error("the AArch64 backend does not support this target");
    }

    let function_index: Int = wir_id_index(UInt32(function_id));
    if (function_index < 0 || function_index >= program.arena.functions.length()) {
        return a64_lowering_error("function id is outside the WIR arena");
    }

    let function: WirFunction = program.arena.functions[function_index];
    if (function.blocks.length() == 0 || function.entry != function.blocks[0]) {
        return a64_lowering_error("AArch64 lowering requires a valid entry block");
    }
    let output: A64CodeBuffer = a64_new_code_buffer();
    let values: A64ValueMap = a64_new_value_map(program.arena.values.length());
    let offsets: Vector(A64BlockOffset) = [];
    let fixups: Vector(A64BranchFixup) = [];
    let layouts: Vector(WirTypeLayout) = wir_type_layouts(program);
    let stack: A64StackLayout = a64_stack_layout(ref program, ref function, layouts);
    if (stack.message.length() != 0) { return a64_lowering_error(stack.message); }

    let has_call: Bool = false;
    let i: Int = 0;

    while (i < function.blocks.length()) {
        let scan_block: WirBlock = program.arena.blocks[wir_id_index(UInt32(function.blocks[i]))];
        let j: Int = 0;
        while (j < scan_block.instructions.length()) {
            let scan: WirInstruction = program.arena.instructions[wir_id_index(UInt32(scan_block.instructions[j]))];
            if (scan.opcode == WirOpcode.Call || scan.opcode == WirOpcode.Retain || scan.opcode == WirOpcode.Release ||
                scan.opcode == WirOpcode.NullCheck || scan.opcode == WirOpcode.BoundsCheck) {
                has_call = true;
            }
            j++;
        }
        i++;
    }
    let has_frame: Bool = has_call || stack.frame_size != 0;
    if (has_frame && !a64_enter_sized_frame(ref output, stack.frame_size)) {
        return a64_lowering_error("cannot encode the AArch64 stack frame");
    }
    if (stack.result_pointer_offset >= 0 &&
        !a64_store_integer_at(ref output, A64Register.X8, A64Register.SP, stack.result_pointer_offset, 64)) {
        return a64_lowering_error("cannot save the AArch64 aggregate return pointer");
    }

    let incoming_state: A64ArgumentState = A64ArgumentState(integer=0, floating=0, stack=0);
    i = 0;
    while (i < function.parameters.length()) {
        let parameter: WirValueID = function.parameters[i];
        let value: WirValue = program.arena.values[wir_id_index(UInt32(parameter))];
        let location: A64ArgumentLocation = a64_argument_location(ref program, value.type_id, layouts, ref incoming_state);
        let home: A64StackSlot = a64_find_stack_slot(stack.homes, parameter);
        if (!location.valid || home.value == NO_WIR_VALUE) {
            return a64_lowering_error("AArch64 parameter has no valid ABI location or home");
        }

        if (a64_aggregate_type(ref program, value.type_id)) {
            let layout: WirTypeLayout = layouts[wir_id_index(UInt32(value.type_id))];
            let hfa: A64HFA = a64_hfa_type(ref program, value.type_id, layouts);
            if (!layout.valid) {
                return a64_lowering_error("AArch64 aggregate parameter has no valid layout");
            }

            if (location.on_stack) {
                let incoming_offset: Int = stack.frame_size + 16 + location.offset;
                let copied: Bool = false;
                if (location.indirect) {
                    copied = a64_load_integer_at(ref output, A64Register.X16, A64Register.SP, incoming_offset, 64) &&
                             a64_zero_memory(ref output, A64Register.SP, home.offset, home.size) &&
                             a64_copy_memory(ref output, A64Register.SP, home.offset, A64Register.X16, 0, Int(layout.size), A64Register.X9);
                } else {
                    copied = a64_zero_memory(ref output, A64Register.SP, home.offset, home.size) &&
                             a64_copy_memory(ref output, A64Register.SP, home.offset, A64Register.SP, incoming_offset, Int(layout.size), A64Register.X9);
                }
                if (!copied) {
                    return a64_lowering_error("cannot copy an AArch64 stack aggregate parameter");
                }
            } else if (hfa.valid) {
                if (!a64_save_hfa_registers(ref output, home, location.first, hfa)) {
                    return a64_lowering_error("cannot save an AArch64 homogeneous float parameter");
                }
            } else if (!location.indirect) {
                if (!a64_save_aggregate_registers(ref output, home, location.first, location.count)) {
                    return a64_lowering_error("cannot save an AArch64 aggregate parameter");
                }
            } else {
                let incoming: A64Register = a64_argument_register(location.first, false);
                let temporary: A64Register = A64Register.X9;
                if (incoming == A64Register.None || !a64_zero_memory(
                    ref output,
                    A64Register.SP,
                    home.offset,
                    home.size
                ) || !a64_copy_memory(
                    ref output,
                    A64Register.SP,
                    home.offset,
                    incoming,
                    0,
                    Int(layout.size),
                    temporary
                )) {
                    return a64_lowering_error("cannot copy an indirect AArch64 aggregate parameter");
                }
            }

            i++;
            continue;
        }

        let width: Int = a64_integer_width(ref program, value.type_id);
        if (width == 128) {
            let pair: A64RegisterPair = A64RegisterPair(low=A64Register.X9, high=A64Register.X10);
            let loaded: Bool = false;
            if (location.on_stack) {
                let incoming_offset: Int = stack.frame_size + 16 + location.offset;
                loaded = a64_load_integer_at(ref output, pair.low, A64Register.SP, incoming_offset, 64) &&
                         a64_load_integer_at(ref output, pair.high, A64Register.SP, incoming_offset + 8, 64);
            } else {
                pair.low = a64_argument_register(location.first, false);
                pair.high = a64_argument_register(location.first + 1, false);
                loaded = pair.low != A64Register.None && pair.high != A64Register.None;
            }
            if (!loaded || !a64_save_pair(ref output, stack.homes, parameter, pair)) {
                return a64_lowering_error("cannot save an AArch64 128-bit argument pair");
            }

            i++;
            continue;
        }

        width = a64_scalar_width(ref program, value.type_id);
        let floating: Bool = a64_scalar_float(ref program, value.type_id);
        if (width == 0) {
            return a64_lowering_error("AArch64 scalar parameter has no register width");
        }
        let incoming: A64Register = A64Register.None;
        if (location.on_stack) {
            incoming = a64_alloc_register(ref values, floating);
            let incoming_offset: Int = stack.frame_size + 16 + location.offset;
            let loaded: Bool = false;
            if floating {
                loaded = a64_load_float_at(ref output, incoming, A64Register.SP, incoming_offset, width == 64);
            } else {
                loaded = a64_load_integer_at(ref output, incoming, A64Register.SP, incoming_offset, width);
            }
            if (!loaded) {
                return a64_lowering_error("cannot load an AArch64 stack parameter");
            }
        } else {
            incoming = a64_argument_register(location.first, floating);
        }
        if (incoming == A64Register.None || !a64_save_home(ref output, stack.homes, parameter, incoming, width)) {
            return a64_lowering_error("cannot save an AArch64 argument register");
        }
        i++;
    }

    i = 0;
    while (i < stack.homes.length()) {
        let home: A64StackSlot = stack.homes[i];
        let value: WirValue = program.arena.values[wir_id_index(UInt32(home.value))];
        if (value.kind == WirValueKind.Constant && a64_aggregate_type(ref program, value.type_id) &&
            !a64_store_value_at(
                ref program,
                home.value,
                A64Register.SP,
                home.offset,
                stack.storage,
                stack.homes,
                layouts,
                ref values,
                ref output
            )) {
            return a64_lowering_error("cannot initialize an AArch64 aggregate constant");
        }
        i++;
    }

    i = 0;
    while (i < function.blocks.length()) {
        let block_id: WirBlockID = function.blocks[i];
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];
        offsets.append(A64BlockOffset(block=block_id, offset=output.bytes.length()));

        let instruction_index: Int = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];

            if (instruction.opcode == WirOpcode.StackAlloc) {
                // stack slots were assigned before instruction selection
            } else if (instruction.opcode == WirOpcode.Load) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("load has an invalid WIR shape");
                }

                let slot: A64StackSlot = a64_find_stack_slot(stack.storage, instruction.operands[0]);
                let base: A64Register = A64Register.SP;
                let offset: Int = slot.offset;
                if (slot.value == NO_WIR_VALUE) {
                    base = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                    offset = 0;
                }

                if (base == A64Register.None || !a64_load_value_at(
                    ref program,
                    instruction.type_id,
                    instruction.result,
                    base,
                    offset,
                    stack.homes,
                    layouts,
                    ref values,
                    ref output
                )) {
                    return a64_lowering_error("cannot encode AArch64 load");
                }
            } else if (instruction.opcode == WirOpcode.Store) {
                if (instruction.operands.length() != 2 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("store has an invalid WIR shape");
                }

                let slot: A64StackSlot = a64_find_stack_slot(stack.storage, instruction.operands[1]);
                let base: A64Register = A64Register.SP;
                let offset: Int = slot.offset;
                if (slot.value == NO_WIR_VALUE) {
                    base = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                    offset = 0;
                }

                if (base == A64Register.None || !a64_store_value_at(
                    ref program,
                    instruction.operands[0],
                    base,
                    offset,
                    stack.storage,
                    stack.homes,
                    layouts,
                    ref values,
                    ref output
                )) {
                    return a64_lowering_error("cannot encode AArch64 store");
                }
            } else if (instruction.opcode == WirOpcode.StructValue ||
                       instruction.opcode == WirOpcode.ArrayValue) {
                let type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
                let layout: WirTypeLayout = layouts[wir_id_index(UInt32(instruction.type_id))];
                let home: A64StackSlot = a64_find_stack_slot(stack.homes, instruction.result);
                let count: Int = type.fields.length();
                if (type.kind == WirTypeKind.Array) {
                    if (type.length > UIntSize(2147483647U)) {
                        return a64_lowering_error("AArch64 array constructor exceeds the machine limit");
                    }
                    count = Int(type.length);
                }
                if (!layout.valid || home.value == NO_WIR_VALUE || home.size < Int(layout.size) ||
                    instruction.operands.length() > count ||
                    (instruction.opcode == WirOpcode.StructValue && type.kind != WirTypeKind.Struct) ||
                    (instruction.opcode == WirOpcode.ArrayValue && type.kind != WirTypeKind.Array) ||
                    !a64_zero_memory(ref output, A64Register.SP, home.offset, home.size)) {
                    return a64_lowering_error("AArch64 aggregate constructor has an invalid layout");
                }

                let stride: Int = 0;
                if (type.kind == WirTypeKind.Array) {
                    let element_layout: WirTypeLayout = layouts[wir_id_index(UInt32(type.element))];
                    if (!element_layout.valid || element_layout.size > 2147483647UL) {
                        return a64_lowering_error("AArch64 array element has an invalid layout");
                    }
                    stride = Int(element_layout.size);
                }

                let element_index: Int = 0;
                while (element_index < instruction.operands.length()) {
                    let offset: Int = element_index * stride;
                    if (type.kind == WirTypeKind.Struct) {
                        offset = Int(layout.field_offsets[element_index]);
                    }
                    if (!a64_store_value_at(
                        ref program,
                        instruction.operands[element_index],
                        A64Register.SP,
                        home.offset + offset,
                        stack.storage,
                        stack.homes,
                        layouts,
                        ref values,
                        ref output
                    )) {
                        return a64_lowering_error("cannot initialize an AArch64 aggregate member");
                    }
                    element_index++;
                }
            } else if (instruction.opcode == WirOpcode.Field || instruction.opcode == WirOpcode.Index) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("aggregate extraction has an invalid WIR shape");
                }

                let aggregate_id: WirValueID = instruction.operands[0];
                let aggregate: WirValue = program.arena.values[wir_id_index(UInt32(aggregate_id))];
                let type: WirType = program.arena.types[wir_id_index(UInt32(aggregate.type_id))];
                let layout: WirTypeLayout = layouts[wir_id_index(UInt32(aggregate.type_id))];
                let home: A64StackSlot = a64_find_stack_slot(stack.homes, aggregate_id);
                let index: WirValue = program.arena.values[
                    wir_id_index(UInt32(instruction.operands[1]))
                ];
                if (!layout.valid || index.kind != WirValueKind.Integer) {
                    return a64_lowering_error("AArch64 aggregate extraction requires a valid layout and constant index");
                }

                let offset: Int = 0;
                if (instruction.opcode == WirOpcode.Field) {
                    if (type.kind != WirTypeKind.Struct || index.integer >= UInt128(type.fields.length())) {
                        return a64_lowering_error("AArch64 aggregate field index is out of range");
                    }
                    offset = Int(layout.field_offsets[Int(index.integer)]);
                } else {
                    if (type.kind != WirTypeKind.Array || index.integer >= UInt128(type.length)) {
                        return a64_lowering_error("AArch64 aggregate element index is out of range");
                    }
                    let element_layout: WirTypeLayout = layouts[wir_id_index(UInt32(type.element))];
                    if (!element_layout.valid || element_layout.size > 2147483647UL) {
                        return a64_lowering_error("AArch64 aggregate element has an invalid layout");
                    }
                    offset = Int(index.integer) * Int(element_layout.size);
                }

                if (home.value == NO_WIR_VALUE && aggregate.kind == WirValueKind.Constant) {
                    let constant_index: Int = wir_id_index(aggregate.owner);
                    let result_home: A64StackSlot = a64_find_stack_slot(stack.homes, instruction.result);
                    if (constant_index < 0 || constant_index >= program.arena.constants.length() ||
                        result_home.value == NO_WIR_VALUE) {
                        return a64_lowering_error("AArch64 constant aggregate member has no storage");
                    }

                    let constant: WirConstant = program.arena.constants[constant_index];
                    if (constant.kind == WirConstKind.Zero) {
                        if (!a64_zero_memory(ref output, A64Register.SP, result_home.offset, result_home.size)) {
                            return a64_lowering_error("cannot extract an AArch64 zero aggregate member");
                        }
                    } else if (constant.kind == WirConstKind.Aggregate &&
                               index.integer < UInt128(constant.elements.length())) {
                        if (!a64_store_value_at(
                            ref program,
                            constant.elements[Int(index.integer)],
                            A64Register.SP,
                            result_home.offset,
                            stack.storage,
                            stack.homes,
                            layouts,
                            ref values,
                            ref output
                        )) {
                            return a64_lowering_error("cannot extract an AArch64 constant aggregate member");
                        }
                    } else {
                        return a64_lowering_error("AArch64 constant aggregate member is unavailable");
                    }
                } else if (home.value == NO_WIR_VALUE) {
                    return a64_lowering_error("AArch64 aggregate value has no storage for extraction");
                } else if (!a64_load_value_at(
                    ref program,
                    instruction.type_id,
                    instruction.result,
                    A64Register.SP,
                    home.offset + offset,
                    stack.homes,
                    layouts,
                    ref values,
                    ref output
                )) {
                    return a64_lowering_error("cannot extract an AArch64 aggregate member");
                }
            } else if (instruction.opcode == WirOpcode.AtomicLoad) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("atomic load has an invalid WIR shape");
                }

                let width: Int = a64_integer_bits(ref program, instruction.type_id);
                let home_width: Int = a64_scalar_width(ref program, instruction.type_id);
                let address: A64Register = a64_materialize(
                    ref program,
                    instruction.operands[0],
                    stack.homes,
                    ref values,
                    ref output
                );
                let destination: A64Register = a64_alloc_register(ref values, false);
                if (address == A64Register.None || destination == A64Register.None ||
                    !a64_atomic_load(
                        ref output,
                        destination,
                        address,
                        width,
                        a64_atomic_acquire(instruction.memory_order)
                    ) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, home_width)) {
                    return a64_lowering_error("cannot encode AArch64 atomic load");
                }
            } else if (instruction.opcode == WirOpcode.AtomicStore) {
                if (instruction.operands.length() != 2 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("atomic store has an invalid WIR shape");
                }

                let value_type: WirTypeID = program.arena.values[
                    wir_id_index(UInt32(instruction.operands[0]))
                ].type_id;
                let width: Int = a64_integer_bits(ref program, value_type);
                let source: A64Register = a64_materialize(
                    ref program,
                    instruction.operands[0],
                    stack.homes,
                    ref values,
                    ref output
                );
                let address: A64Register = a64_materialize(
                    ref program,
                    instruction.operands[1],
                    stack.homes,
                    ref values,
                    ref output
                );
                if (source == A64Register.None || address == A64Register.None ||
                    !a64_atomic_store(
                        ref output,
                        source,
                        address,
                        width,
                        a64_atomic_release(instruction.memory_order)
                    )) {
                    return a64_lowering_error("cannot encode AArch64 atomic store");
                }
            } else if (instruction.opcode == WirOpcode.AtomicRmw) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("atomic RMW has an invalid WIR shape");
                }

                let width: Int = a64_integer_bits(ref program, instruction.type_id);
                let home_width: Int = a64_scalar_width(ref program, instruction.type_id);
                let address: A64Register = a64_materialize(
                    ref program,
                    instruction.operands[0],
                    stack.homes,
                    ref values,
                    ref output
                );
                let input: A64Register = a64_materialize(
                    ref program,
                    instruction.operands[1],
                    stack.homes,
                    ref values,
                    ref output
                );
                let old_value: A64Register = a64_alloc_register(ref values, false);
                let new_value: A64Register = a64_alloc_register(ref values, false);
                let status: A64Register = a64_alloc_register(ref values, false);
                if (address == A64Register.None || input == A64Register.None || old_value == A64Register.None ||
                    new_value == A64Register.None || status == A64Register.None ||
                    !a64_emit_atomic_rmw(
                        ref output,
                        instruction.atomic_op,
                        address,
                        input,
                        old_value,
                        new_value,
                        status,
                        width,
                        instruction.memory_order
                    ) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, old_value, home_width)) {
                    return a64_lowering_error("cannot encode AArch64 atomic read-modify-write");
                }
            } else if (instruction.opcode == WirOpcode.FieldAddress ||
                       instruction.opcode == WirOpcode.IndexAddress) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("aggregate address has an invalid WIR shape");
                }

                let base_id: WirValueID = instruction.operands[0];
                let base_value: WirValue = program.arena.values[wir_id_index(UInt32(base_id))];
                let pointer: WirType = program.arena.types[wir_id_index(UInt32(base_value.type_id))];
                if (pointer.kind != WirTypeKind.Pointer) {
                    return a64_lowering_error("aggregate address requires a pointer base");
                }

                let base: A64Register = a64_materialize_address(
                    ref program,
                    base_id,
                    stack.storage,
                    stack.homes,
                    ref values,
                    ref output
                );
                let destination: A64Register = a64_alloc_register(ref values, false);
                if (base == A64Register.None || destination == A64Register.None) {
                    return a64_lowering_error("cannot materialize an AArch64 aggregate address");
                }

                if (instruction.opcode == WirOpcode.FieldAddress) {
                    let layout: WirTypeLayout = layouts[wir_id_index(UInt32(pointer.element))];
                    let field: WirValue = program.arena.values[
                        wir_id_index(UInt32(instruction.operands[1]))
                    ];
                    if (!layout.valid || field.kind != WirValueKind.Integer ||
                        field.integer >= UInt128(layout.field_offsets.length())) {
                        return a64_lowering_error("AArch64 field address has an invalid field index");
                    }

                    let offset: UInt64 = layout.field_offsets[Int(field.integer)];
                    let encoded: Bool = false;
                    if (offset == 0UL) {
                        encoded = a64_mov_register(ref output, destination, base, true);
                    } else if (offset <= 4095UL) {
                        encoded = a64_add_immediate(ref output, destination, base, Int(offset), true);
                    } else {
                        let temporary: A64Register = a64_alloc_register(ref values, false);
                        encoded = temporary != A64Register.None &&
                                  a64_mov_immediate(ref output, temporary, offset, true) &&
                                  a64_add_register(ref output, destination, base, temporary, true);
                    }
                    if (!encoded) {
                        return a64_lowering_error("cannot encode an AArch64 field address");
                    }
                } else {
                    let element_type: WirTypeID = pointer.element;
                    let element: WirType = program.arena.types[wir_id_index(UInt32(element_type))];
                    if (element.kind == WirTypeKind.Array) {
                        element_type = element.element;
                    }

                    let layout: WirTypeLayout = layouts[wir_id_index(UInt32(element_type))];
                    let index_id: WirValueID = instruction.operands[1];
                    let index_value: WirValue = program.arena.values[wir_id_index(UInt32(index_id))];
                    let index_bits: Int = a64_integer_bits(ref program, index_value.type_id);
                    let index: A64Register = a64_materialize(
                        ref program,
                        index_id,
                        stack.homes,
                        ref values,
                        ref output
                    );
                    let scaled: A64Register = a64_alloc_register(ref values, false);
                    if (!layout.valid || layout.size == 0UL || index == A64Register.None ||
                        scaled == A64Register.None || index_bits <= 0 || index_bits > 64) {
                        return a64_lowering_error("AArch64 index address has an invalid element layout");
                    }

                    let extended: Bool = false;
                    if (index_bits < 64) {
                        extended = a64_extend_integer(
                            ref output,
                            scaled,
                            index,
                            index_bits,
                            a64_integer_signed(ref program, index_value.type_id),
                            true
                        );
                    } else {
                        extended = a64_mov_register(ref output, scaled, index, true);
                    }
                    if (!extended) {
                        return a64_lowering_error("cannot extend an AArch64 aggregate index");
                    }

                    if (layout.size != 1UL) {
                        let stride: A64Register = a64_alloc_register(ref values, false);
                        if (stride == A64Register.None ||
                            !a64_mov_immediate(ref output, stride, layout.size, true) ||
                            !a64_multiply_register(ref output, scaled, scaled, stride, true)) {
                            return a64_lowering_error("cannot scale an AArch64 aggregate index");
                        }
                    }
                    if (!a64_add_register(ref output, destination, base, scaled, true)) {
                        return a64_lowering_error("cannot encode an AArch64 index address");
                    }
                }

                if (!a64_save_home(ref output, stack.homes, instruction.result, destination, 64)) {
                    return a64_lowering_error("cannot save an AArch64 aggregate address");
                }
            } else if (instruction.opcode == WirOpcode.Bitcast && instruction.operands.length() == 1 &&
                       (a64_scalar_float(ref program, instruction.type_id) ||
                        a64_scalar_float(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id))) {
                if (instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("floating-point bitcast has no result");
                }

                let source_id: WirValueID = instruction.operands[0];
                let source_type: WirTypeID = program.arena.values[wir_id_index(UInt32(source_id))].type_id;
                let source_width: Int = a64_scalar_width(ref program, source_type);
                let target_width: Int = a64_scalar_width(ref program, instruction.type_id);
                let source_float: Bool = a64_scalar_float(ref program, source_type);
                let target_float: Bool = a64_scalar_float(ref program, instruction.type_id);
                let source: A64Register = a64_materialize(ref program, source_id, stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, target_float);
                let encoded: Bool = source_width == target_width && (target_width == 32 || target_width == 64) &&
                                    source != A64Register.None && destination != A64Register.None;
                if (encoded && source_float && target_float) {
                    encoded = a64_float_move(ref output, destination, source, target_width == 64);
                } else if (encoded && source_float) {
                    encoded = a64_float_to_bits(ref output, destination, source, target_width == 64);
                } else if (encoded && target_float) {
                    encoded = a64_float_from_bits(ref output, destination, source, target_width == 64);
                }
                if (!encoded || !a64_save_home(ref output, stack.homes, instruction.result, destination, target_width)) {
                    return a64_lowering_error("cannot encode an AArch64 floating-point bitcast");
                }
            } else if (instruction.opcode == WirOpcode.Bitcast ||
                       instruction.opcode == WirOpcode.PointerToInt ||
                       instruction.opcode == WirOpcode.IntToPointer) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("pointer cast has an invalid WIR shape");
                }

                let source_id: WirValueID = instruction.operands[0];
                let source_type: WirTypeID = program.arena.values[wir_id_index(UInt32(source_id))].type_id;
                let source_width: Int = a64_integer_width(ref program, source_type);
                let target_width: Int = a64_integer_width(ref program, instruction.type_id);
                if (source_width == 0) { source_width = a64_scalar_width(ref program, source_type); }
                if (target_width == 0) { target_width = a64_scalar_width(ref program, instruction.type_id); }

                if (source_width == 0 || target_width == 0 || a64_scalar_float(ref program, source_type) ||
                    a64_scalar_float(ref program, instruction.type_id)) {
                    return a64_lowering_error("AArch64 pointer cast has unsupported types");
                }

                if (source_width == 128 && target_width == 128) {
                    let source: A64RegisterPair = a64_materialize_pair(
                        ref program,
                        source_id,
                        stack.homes,
                        ref values,
                        ref output
                    );
                    if (source.low == A64Register.None || source.high == A64Register.None ||
                        !a64_save_pair(ref output, stack.homes, instruction.result, source)) {
                        return a64_lowering_error("cannot encode an AArch64 128-bit bitcast");
                    }
                } else if (target_width == 128) {
                    let source: A64Register = a64_materialize_address(
                        ref program,
                        source_id,
                        stack.storage,
                        stack.homes,
                        ref values,
                        ref output
                    );
                    let destination: A64RegisterPair = a64_alloc_pair(ref values);
                    let encoded: Bool = source != A64Register.None && destination.low != A64Register.None &&
                                        destination.high != A64Register.None &&
                                        a64_mov_register(ref output, destination.low, source, true) &&
                                        a64_mov_immediate(ref output, destination.high, 0UL, true);
                    if (!encoded || !a64_save_pair(ref output, stack.homes, instruction.result, destination)) {
                        return a64_lowering_error("cannot cast an AArch64 pointer to a 128-bit integer");
                    }
                } else if (source_width == 128) {
                    let source: A64RegisterPair = a64_materialize_pair(ref program, source_id, stack.homes, ref values, ref output);
                    let destination: A64Register = a64_alloc_register(ref values, false);
                    let encoded: Bool = source.low != A64Register.None && destination != A64Register.None &&
                                        a64_mov_register(ref output, destination, source.low, target_width == 64);
                    if (!encoded || !a64_save_home(ref output, stack.homes, instruction.result, destination, target_width)) {
                        return a64_lowering_error("cannot cast a 128-bit integer to an AArch64 pointer");
                    }
                } else {
                    let source: A64Register = a64_materialize_address(
                        ref program,
                        source_id,
                        stack.storage,
                        stack.homes,
                        ref values,
                        ref output
                    );
                    let destination: A64Register = a64_alloc_register(ref values, false);
                    let encoded: Bool = source != A64Register.None && destination != A64Register.None;
                    if (encoded && instruction.opcode == WirOpcode.IntToPointer && source_width < 64) {
                        let bits: Int = a64_integer_bits(ref program, source_type);
                        encoded = bits > 0 && a64_extend_integer(ref output, destination, source, bits, false, true);
                    } else if encoded {
                        encoded = a64_mov_register(ref output, destination, source, target_width == 64);
                    }
                    if (!encoded || !a64_save_home(ref output, stack.homes, instruction.result, destination, target_width)) {
                        return a64_lowering_error("cannot encode an AArch64 pointer cast");
                    }
                }
            } else if (instruction.opcode == WirOpcode.Truncate ||
                       instruction.opcode == WirOpcode.SignExtend ||
                       instruction.opcode == WirOpcode.ZeroExtend) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer cast has an invalid WIR shape");
                }

                let source_id: WirValueID = instruction.operands[0];
                let source_type: WirTypeID = program.arena.values[wir_id_index(UInt32(source_id))].type_id;
                let source_bits: Int = a64_integer_bits(ref program, source_type);
                let target_bits: Int = a64_integer_bits(ref program, instruction.type_id);
                if (source_bits == 0 || target_bits == 0) {
                    return a64_lowering_error("AArch64 integer cast has unsupported types");
                }

                if (target_bits == 128) {
                    let source: A64Register = a64_materialize(ref program, source_id, stack.homes, ref values, ref output);
                    let destination: A64RegisterPair = a64_alloc_pair(ref values);
                    let amount: A64Register = a64_alloc_register(ref values, false);
                    let encoded: Bool = source != A64Register.None && destination.low != A64Register.None &&
                                        destination.high != A64Register.None && amount != A64Register.None;
                    if (encoded && source_bits < 64) {
                        encoded = a64_extend_integer(
                            ref output,
                            destination.low,
                            source,
                            source_bits,
                            instruction.opcode == WirOpcode.SignExtend,
                            true
                        );
                    } else if encoded {
                        encoded = a64_mov_register(ref output, destination.low, source, true);
                    }
                    if (encoded && instruction.opcode == WirOpcode.SignExtend) {
                        encoded = a64_mov_immediate(ref output, amount, 63UL, true) &&
                                  a64_shift_register(ref output, destination.high, destination.low, amount, 1, true);
                    } else if encoded {
                        encoded = a64_mov_immediate(ref output, destination.high, 0UL, true);
                    }
                    if (!encoded || !a64_save_pair(ref output, stack.homes, instruction.result, destination)) {
                        return a64_lowering_error("cannot extend an AArch64 integer to 128 bits");
                    }
                } else if (source_bits == 128) {
                    let source: A64RegisterPair = a64_materialize_pair(ref program, source_id, stack.homes, ref values, ref output);
                    let destination: A64Register = a64_alloc_register(ref values, false);
                    let target_width: Int = a64_scalar_width(ref program, instruction.type_id);
                    let encoded: Bool = source.low != A64Register.None && destination != A64Register.None && target_width != 0;
                    if (encoded && target_bits < target_width) {
                        encoded = a64_extend_integer(
                            ref output,
                            destination,
                            source.low,
                            target_bits,
                            a64_integer_signed(ref program, instruction.type_id),
                            target_width == 64
                        );
                    } else if encoded {
                        encoded = a64_mov_register(ref output, destination, source.low, target_width == 64);
                    }
                    if (!encoded || !a64_save_home(ref output, stack.homes, instruction.result, destination, target_width)) {
                        return a64_lowering_error("cannot truncate an AArch64 128-bit integer");
                    }
                } else {
                    let source: A64Register = a64_materialize(ref program, source_id, stack.homes, ref values, ref output);
                    let destination: A64Register = a64_alloc_register(ref values, false);
                    let target_width: Int = a64_scalar_width(ref program, instruction.type_id);
                    let extend_bits: Int = source_bits;
                    let signed: Bool = instruction.opcode == WirOpcode.SignExtend;
                    if (instruction.opcode == WirOpcode.Truncate) {
                        extend_bits = target_bits;
                        signed = a64_integer_signed(ref program, instruction.type_id);
                    }
                    if (source == A64Register.None || destination == A64Register.None || target_width == 0 ||
                        !a64_extend_integer(ref output, destination, source, extend_bits, signed, target_width == 64) ||
                        !a64_save_home(ref output, stack.homes, instruction.result, destination, target_width)) {
                        return a64_lowering_error("cannot encode AArch64 integer cast");
                    }
                }
            } else if (instruction.opcode == WirOpcode.FloatExtend ||
                       instruction.opcode == WirOpcode.FloatTruncate) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("floating-point width conversion has an invalid WIR shape");
                }

                let source: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, true);
                let target_width: Int = a64_scalar_width(ref program, instruction.type_id);
                let extend: Bool = instruction.opcode == WirOpcode.FloatExtend;
                if (source == A64Register.None || destination == A64Register.None ||
                    (target_width != 32 && target_width != 64) ||
                    !a64_convert_float(ref output, destination, source, extend) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, target_width)) {
                    return a64_lowering_error("cannot encode an AArch64 floating-point width conversion");
                }
            } else if (instruction.opcode == WirOpcode.SignedIntToFloat ||
                       instruction.opcode == WirOpcode.UnsignedIntToFloat) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer to float conversion has an invalid WIR shape");
                }

                let source_id: WirValueID = instruction.operands[0];
                let source_type: WirTypeID = program.arena.values[wir_id_index(UInt32(source_id))].type_id;
                let source_width: Int = a64_integer_width(ref program, source_type);
                let target_width: Int = a64_scalar_width(ref program, instruction.type_id);
                let source: A64Register = a64_materialize(ref program, source_id, stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, true);
                if ((source_width != 32 && source_width != 64) ||
                    (target_width != 32 && target_width != 64) ||
                    source == A64Register.None || destination == A64Register.None ||
                    !a64_int_to_float(
                        ref output,
                        destination,
                        source,
                        instruction.opcode == WirOpcode.SignedIntToFloat,
                        source_width == 64,
                        target_width == 64
                    ) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, target_width)) {
                    return a64_lowering_error("cannot encode an AArch64 integer to float conversion");
                }
            } else if (instruction.opcode == WirOpcode.FloatToSignedInt ||
                       instruction.opcode == WirOpcode.FloatToUnsignedInt) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("float to integer conversion has an invalid WIR shape");
                }

                let source_id: WirValueID = instruction.operands[0];
                let source_type: WirTypeID = program.arena.values[wir_id_index(UInt32(source_id))].type_id;
                let source_width: Int = a64_scalar_width(ref program, source_type);
                let target_width: Int = a64_integer_width(ref program, instruction.type_id);
                let source: A64Register = a64_materialize(ref program, source_id, stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, false);
                if ((source_width != 32 && source_width != 64) ||
                    (target_width != 32 && target_width != 64) ||
                    source == A64Register.None || destination == A64Register.None ||
                    !a64_float_to_int(
                        ref output,
                        destination,
                        source,
                        instruction.opcode == WirOpcode.FloatToSignedInt,
                        source_width == 64,
                        target_width == 64
                    ) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, target_width)) {
                    return a64_lowering_error("cannot encode an AArch64 float to integer conversion");
                }
            } else if (a64_integer_width(ref program, instruction.type_id) == 128 &&
                       (instruction.opcode == WirOpcode.Add || instruction.opcode == WirOpcode.Subtract ||
                        instruction.opcode == WirOpcode.BitAnd || instruction.opcode == WirOpcode.BitOr ||
                        instruction.opcode == WirOpcode.BitXor)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("128-bit integer operation has an invalid WIR shape");
                }

                let left: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64RegisterPair = a64_alloc_pair(ref values);
                if (left.low == A64Register.None || left.high == A64Register.None ||
                    right.low == A64Register.None || right.high == A64Register.None ||
                    destination.low == A64Register.None || destination.high == A64Register.None ||
                    !a64_wide_binary(ref output, instruction.opcode, destination, left, right) ||
                    !a64_save_pair(ref output, stack.homes, instruction.result, destination)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit integer operation");
                }
            } else if (a64_integer_width(ref program, instruction.type_id) == 128 &&
                       instruction.opcode == WirOpcode.Multiply) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("128-bit multiply has an invalid WIR shape");
                }

                let left: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64RegisterPair = a64_alloc_pair(ref values);
                let temporary: A64Register = a64_alloc_register(ref values, false);
                if (left.low == A64Register.None || left.high == A64Register.None ||
                    right.low == A64Register.None || right.high == A64Register.None ||
                    destination.low == A64Register.None || destination.high == A64Register.None ||
                    temporary == A64Register.None ||
                    !a64_wide_multiply(ref output, destination, left, right, temporary) ||
                    !a64_save_pair(ref output, stack.homes, instruction.result, destination)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit multiply");
                }
            } else if (a64_integer_width(ref program, instruction.type_id) == 128 &&
                       (instruction.opcode == WirOpcode.ShiftLeft ||
                        instruction.opcode == WirOpcode.SignedShiftRight ||
                        instruction.opcode == WirOpcode.UnsignedShiftRight)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("128-bit shift has an invalid WIR shape");
                }

                let source: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let amount: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64RegisterPair = a64_alloc_pair(ref values);
                let count: A64Register = a64_alloc_register(ref values, false);
                let work: A64Register = a64_alloc_register(ref values, false);
                let cross: A64Register = a64_alloc_register(ref values, false);
                if (source.low == A64Register.None || source.high == A64Register.None || amount.low == A64Register.None ||
                    destination.low == A64Register.None || destination.high == A64Register.None ||
                    count == A64Register.None || work == A64Register.None || cross == A64Register.None ||
                    !a64_wide_shift(ref output, instruction.opcode, destination, source, amount.low, count, work, cross) ||
                    !a64_save_pair(ref output, stack.homes, instruction.result, destination)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit shift");
                }
            } else if (a64_is_integer_binary(instruction.opcode) && !a64_scalar_float(ref program, instruction.type_id)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer arithmetic has an invalid WIR shape");
                }

                let left: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64Register = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, false);
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                if (left == A64Register.None || right == A64Register.None || destination == A64Register.None || width == 0) {
                    return a64_lowering_error("AArch64 integer arithmetic ran out of temporary registers");
                }

                let encoded: Bool = a64_emit_integer_binary(ref output, instruction.opcode, destination, left, right, width == 64);
                if (!encoded || !a64_save_home(ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 integer arithmetic");
                }
            } else if (a64_is_integer_division(instruction.opcode) &&
                       a64_integer_width(ref program, instruction.type_id) == 128) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE ||
                    !a64_materialize_pair_into(ref program, instruction.operands[0], stack.homes, A64RegisterPair(low=A64Register.X0, high=A64Register.X1), ref output) ||
                    !a64_materialize_pair_into(ref program, instruction.operands[1], stack.homes, A64RegisterPair(low=A64Register.X2, high=A64Register.X3), ref output)) {
                    return a64_lowering_error("128-bit division has an invalid WIR shape");
                }

                let signed: Bool = instruction.opcode == WirOpcode.SignedDivide || instruction.opcode == WirOpcode.SignedRemainder;
                let remainder: Bool = instruction.opcode == WirOpcode.SignedRemainder || instruction.opcode == WirOpcode.UnsignedRemainder;
                let result: A64RegisterPair = a64_wide_divide(ref output, signed, remainder);
                if (result.low == A64Register.None || result.high == A64Register.None ||
                    !a64_save_pair(ref output, stack.homes, instruction.result, result)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit division");
                }
            } else if (a64_is_integer_division(instruction.opcode)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer division has an invalid WIR shape");
                }

                let left: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64Register = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let quotient: A64Register = a64_alloc_register(ref values, false);
                let destination: A64Register = quotient;
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                let signed: Bool = instruction.opcode == WirOpcode.SignedDivide || instruction.opcode == WirOpcode.SignedRemainder;
                let remainder: Bool = instruction.opcode == WirOpcode.SignedRemainder || instruction.opcode == WirOpcode.UnsignedRemainder;
                if remainder { destination = a64_alloc_register(ref values, false); }

                let encoded: Bool = a64_divide_register(ref output, quotient, left, right, signed, width == 64);
                if (encoded && remainder) {
                    encoded = a64_multiply_subtract(ref output, destination, quotient, right, left, width == 64);
                }
                if (left == A64Register.None || right == A64Register.None || quotient == A64Register.None ||
                    destination == A64Register.None || width == 0 || !encoded ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 integer division");
                }
            } else if (a64_is_float_binary(instruction.opcode) && a64_scalar_float(ref program, instruction.type_id)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("floating-point arithmetic has an invalid WIR shape");
                }

                let left: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64Register = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, true);
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                if (left == A64Register.None || right == A64Register.None || destination == A64Register.None || width == 0 ||
                    !a64_emit_float_binary(ref output, instruction.opcode, destination, left, right, width == 64) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 floating-point arithmetic");
                }
            } else if (instruction.opcode == WirOpcode.FloatNegate) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("floating-point negate has an invalid WIR shape");
                }

                let source: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, true);
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                if (source == A64Register.None || destination == A64Register.None || width == 0 ||
                    !a64_float_negate(ref output, destination, source, width == 64) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 floating-point negate");
                }
            } else if (a64_is_integer_comparison(instruction.opcode) && instruction.operands.length() == 2 &&
                       a64_integer_width(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id) == 128) {
                if (instruction.result == NO_WIR_VALUE || instruction.type_id != program.bool_type) {
                    return a64_lowering_error("128-bit comparison has an invalid WIR shape");
                }

                let left: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, false);
                let first: A64Register = a64_alloc_register(ref values, false);
                let second: A64Register = a64_alloc_register(ref values, false);
                if (left.low == A64Register.None || left.high == A64Register.None ||
                    right.low == A64Register.None || right.high == A64Register.None ||
                    destination == A64Register.None || first == A64Register.None || second == A64Register.None ||
                    !a64_wide_compare(ref output, instruction.opcode, destination, first, second, left, right) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, 32)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit comparison");
                }
            } else if (a64_is_float_comparison(instruction.opcode) && instruction.operands.length() == 2 &&
                       a64_scalar_float(ref program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id)) {
                if (instruction.result == NO_WIR_VALUE || instruction.type_id != program.bool_type) {
                    return a64_lowering_error("floating-point comparison has an invalid WIR shape");
                }

                let left_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
                let right_value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))];
                let left: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64Register = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, false);
                let width: Int = a64_scalar_width(ref program, left_value.type_id);
                let condition: A64Condition = a64_float_condition(instruction.opcode);
                if (left_value.type_id != right_value.type_id || left == A64Register.None || right == A64Register.None ||
                    destination == A64Register.None || width == 0 || condition == A64Condition.Never ||
                    !a64_float_compare(ref output, left, right, width == 64) ||
                    !a64_set_condition(ref output, destination, condition) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, 32)) {
                    return a64_lowering_error("cannot encode AArch64 floating-point comparison");
                }
            } else if (a64_is_integer_comparison(instruction.opcode)) {
                if (instruction.operands.length() != 2 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer comparison has an invalid WIR shape");
                }

                let left: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let right: A64Register = a64_materialize(ref program, instruction.operands[1], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, false);
                let input_type: WirTypeID = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id;
                let width: Int = a64_scalar_width(ref program, input_type);
                let condition: A64Condition = a64_comparison_condition(instruction.opcode);

                if (left == A64Register.None || right == A64Register.None || destination == A64Register.None || width == 0 ||
                    condition == A64Condition.Never || !a64_compare_register(ref output, left, right, width == 64) ||
                    !a64_set_condition(ref output, destination, condition) ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, 32)) {
                    return a64_lowering_error("cannot encode AArch64 integer comparison");
                }
            } else if (a64_integer_width(ref program, instruction.type_id) == 128 &&
                       (instruction.opcode == WirOpcode.Negate || instruction.opcode == WirOpcode.Not)) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("128-bit unary operation has an invalid WIR shape");
                }

                let source: A64RegisterPair = a64_materialize_pair(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let destination: A64RegisterPair = a64_alloc_pair(ref values);
                let temporary: A64Register = a64_alloc_register(ref values, false);
                if (source.low == A64Register.None || source.high == A64Register.None ||
                    destination.low == A64Register.None || destination.high == A64Register.None ||
                    temporary == A64Register.None ||
                    !a64_wide_unary(ref output, instruction.opcode, destination, source, temporary) ||
                    !a64_save_pair(ref output, stack.homes, instruction.result, destination)) {
                    return a64_lowering_error("cannot encode AArch64 128-bit unary operation");
                }
            } else if (instruction.opcode == WirOpcode.Negate || instruction.opcode == WirOpcode.Not ||
                       instruction.opcode == WirOpcode.Abs) {
                if (instruction.operands.length() != 1 || instruction.result == NO_WIR_VALUE) {
                    return a64_lowering_error("integer unary operation has an invalid WIR shape");
                }

                let source: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let destination: A64Register = a64_alloc_register(ref values, false);
                let width: Int = a64_scalar_width(ref program, instruction.type_id);
                let encoded: Bool = false;
                if (instruction.opcode == WirOpcode.Negate) {
                    encoded = a64_sub_register(ref output, destination, A64Register.ZR, source, width == 64);
                } else if (instruction.opcode == WirOpcode.Not && instruction.type_id == program.bool_type) {
                    let one: A64Register = a64_alloc_register(ref values, false);
                    encoded = one != A64Register.None &&
                              a64_mov_immediate(ref output, one, 1UL, false) &&
                              a64_logical_register(ref output, destination, source, one, 2, false);
                } else if (instruction.opcode == WirOpcode.Not) {
                    encoded = a64_invert_register(ref output, destination, source, width == 64);
                } else {
                    let negative: A64Register = a64_alloc_register(ref values, false);
                    encoded = negative != A64Register.None &&
                              a64_compare_zero(ref output, source, width == 64) &&
                              a64_sub_register(ref output, negative, A64Register.ZR, source, width == 64) &&
                              a64_select_condition(ref output, destination, negative, source, A64Condition.Minus, width == 64);
                }
                if (source == A64Register.None || destination == A64Register.None || width == 0 || !encoded ||
                    !a64_save_home(ref output, stack.homes, instruction.result, destination, width)) {
                    return a64_lowering_error("cannot encode AArch64 integer unary operation");
                }
            } else if (instruction.opcode == WirOpcode.NullCheck) {
                if (instruction.operands.length() != 1 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("AArch64 null check has an invalid WIR shape");
                }

                let checked_id: WirValueID = instruction.operands[0];
                let checked_type: WirTypeID = program.arena.values[wir_id_index(UInt32(checked_id))].type_id;
                let type: WirType = program.arena.types[wir_id_index(UInt32(checked_type))];
                let checked: A64Register = a64_materialize(ref program, checked_id, stack.homes, ref values, ref output);
                if (type.kind != WirTypeKind.Pointer || checked == A64Register.None ||
                    !a64_compare_zero(ref output, checked, true) ||
                    !a64_conditional_branch(ref output, 12, A64Condition.NotEqual) ||
                    !a64_branch_symbol(ref output, "__wl_fail_null", true)) {
                    return a64_lowering_error("cannot encode an AArch64 null check");
                }

                a64_trap(ref output);
            } else if (instruction.opcode == WirOpcode.BoundsCheck) {
                if (instruction.operands.length() != 2 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("AArch64 bounds check has an invalid WIR shape");
                }

                let index_id: WirValueID = instruction.operands[0];
                let limit_id: WirValueID = instruction.operands[1];
                let index_value: WirValue = program.arena.values[wir_id_index(UInt32(index_id))];
                let limit_value: WirValue = program.arena.values[wir_id_index(UInt32(limit_id))];
                let index_type: WirType = program.arena.types[wir_id_index(UInt32(index_value.type_id))];
                let width: Int = a64_scalar_width(ref program, index_value.type_id);
                let index: A64Register = a64_materialize(ref program, index_id, stack.homes, ref values, ref output);
                let limit: A64Register = a64_materialize(ref program, limit_id, stack.homes, ref values, ref output);
                if (index_value.type_id != limit_value.type_id || width == 0 ||
                    (index_type.kind != WirTypeKind.SignedInt && index_type.kind != WirTypeKind.UnsignedInt) ||
                    index == A64Register.None || limit == A64Register.None ||
                    !a64_compare_register(ref output, index, limit, width == 64) ||
                    !a64_conditional_branch(ref output, 12, A64Condition.CarryClear) ||
                    !a64_branch_symbol(ref output, "__wl_fail_bounds", true)) {
                    return a64_lowering_error("cannot encode an AArch64 bounds check");
                }

                a64_trap(ref output);
            } else if (instruction.opcode == WirOpcode.Retain || instruction.opcode == WirOpcode.Release) {
                if (instruction.operands.length() != 1 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("AArch64 ownership operation has an invalid WIR shape");
                }

                let object: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                let target: String = "__wl_retain";
                if (instruction.opcode == WirOpcode.Release) {
                    target = "__wl_release";
                }
                if (object == A64Register.None ||
                    (object != A64Register.X0 && !a64_mov_register(ref output, A64Register.X0, object, true)) ||
                    !a64_branch_symbol(ref output, target, true)) {
                    return a64_lowering_error("cannot encode an AArch64 ownership call");
                }
            } else if (instruction.opcode == WirOpcode.Call) {
                if (instruction.operands.length() == 0 || instruction.call_type == NO_WIR_TYPE) {
                    return a64_lowering_error("AArch64 call has no target or function type");
                }

                let callee_id: WirValueID = instruction.operands[0];
                let callee: WirValue = program.arena.values[wir_id_index(UInt32(callee_id))];
                let direct: Bool = callee.kind == WirValueKind.Function;
                let callee_name: String = "";
                if (direct) {
                    let function_index: Int = wir_id_index(callee.owner);
                    if (function_index < 0 || function_index >= program.arena.functions.length()) {
                        return a64_lowering_error("direct call target is outside the WIR function arena");
                    }
                    callee_name = program.arena.functions[function_index].name;
                }

                let call_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.call_type))];
                if (call_type.parameters.length() != instruction.operands.length() - 1) {
                    return a64_lowering_error("AArch64 call arguments do not match the WIR function type");
                }

                if (instruction.result != NO_WIR_VALUE && a64_aggregate_type(ref program, instruction.type_id)) {
                    let result_layout: WirTypeLayout = layouts[wir_id_index(UInt32(instruction.type_id))];
                    let result_home: A64StackSlot = a64_find_stack_slot(stack.homes, instruction.result);
                    let result_hfa: A64HFA = a64_hfa_type(ref program, instruction.type_id, layouts);
                    if (!result_layout.valid || result_home.value == NO_WIR_VALUE) {
                        return a64_lowering_error("AArch64 aggregate call result has no valid home");
                    }
                    if (result_layout.size > 16UL && !result_hfa.valid &&
                        !a64_stack_address(ref output, A64Register.X8, result_home.offset)) {
                        return a64_lowering_error("cannot pass the AArch64 aggregate result pointer");
                    }
                }

                let argument_state: A64ArgumentState = A64ArgumentState(integer=0, floating=0, stack=0);
                let argument_index: Int = 1;
                while (argument_index < instruction.operands.length()) {
                    let argument: WirValueID = instruction.operands[argument_index];
                    let argument_type: WirTypeID = program.arena.values[wir_id_index(UInt32(argument))].type_id;
                    let width: Int = a64_integer_width(ref program, argument_type);
                    let floating: Bool = a64_scalar_float(ref program, argument_type);
                    let location: A64ArgumentLocation = a64_argument_location(ref program, argument_type, layouts, ref argument_state);
                    if (!location.valid) {
                        return a64_lowering_error("AArch64 call argument has no valid ABI location");
                    }

                    if (a64_aggregate_type(ref program, argument_type)) {
                        let layout: WirTypeLayout = layouts[wir_id_index(UInt32(argument_type))];
                        let home: A64StackSlot = a64_find_stack_slot(stack.homes, argument);
                        let hfa: A64HFA = a64_hfa_type(ref program, argument_type, layouts);
                        let register_count: Int = a64_aggregate_register_count(layout);
                        if (!layout.valid || home.value == NO_WIR_VALUE) {
                            return a64_lowering_error("AArch64 aggregate call argument has no valid home");
                        }

                        if (location.on_stack) {
                            let stored: Bool = false;
                            if (location.indirect) {
                                stored = a64_stack_address(ref output, A64Register.X9, home.offset) &&
                                         a64_store_integer_at(ref output, A64Register.X9, A64Register.SP, location.offset, 64);
                            } else {
                                stored = a64_copy_memory(
                                    ref output,
                                    A64Register.SP,
                                    location.offset,
                                    A64Register.SP,
                                    home.offset,
                                    Int(layout.size),
                                    A64Register.X9
                                );
                            }
                            if (!stored) {
                                return a64_lowering_error("cannot store an AArch64 stack aggregate argument");
                            }
                        } else if (hfa.valid) {
                            if (!a64_load_hfa_registers(ref output, home, location.first, hfa)) {
                                return a64_lowering_error("cannot load an AArch64 homogeneous float argument");
                            }
                        } else if (!location.indirect) {
                            if (!a64_load_aggregate_registers(ref output, home, location.first, register_count)) {
                                return a64_lowering_error("cannot load an AArch64 aggregate call argument");
                            }
                        } else {
                            let destination: A64Register = a64_argument_register(location.first, false);
                            if (destination == A64Register.None ||
                                !a64_stack_address(ref output, destination, home.offset)) {
                                return a64_lowering_error("cannot pass an indirect AArch64 aggregate argument");
                            }
                        }

                        argument_index++;
                        continue;
                    }

                    if (width == 128) {
                        let pair: A64RegisterPair = a64_materialize_pair(ref program, argument, stack.homes, ref values, ref output);
                        let assigned: Bool = pair.low != A64Register.None && pair.high != A64Register.None;
                        if (assigned && location.on_stack) {
                            assigned = a64_store_integer_at(ref output, pair.low, A64Register.SP, location.offset, 64) &&
                                       a64_store_integer_at(ref output, pair.high, A64Register.SP, location.offset + 8, 64);
                        } else if assigned {
                            let low: A64Register = a64_argument_register(location.first, false);
                            let high: A64Register = a64_argument_register(location.first + 1, false);
                            assigned = low != A64Register.None && high != A64Register.None &&
                                       a64_mov_register(ref output, low, pair.low, true) &&
                                       a64_mov_register(ref output, high, pair.high, true);
                        }
                        if (!assigned) {
                            return a64_lowering_error("cannot assign an AArch64 128-bit call argument");
                        }

                        argument_index++;
                        continue;
                    }

                    width = a64_scalar_width(ref program, argument_type);
                    let source: A64Register = a64_materialize_address(
                        ref program,
                        argument,
                        stack.storage,
                        stack.homes,
                        ref values,
                        ref output
                    );
                    let assigned: Bool = source != A64Register.None && width != 0;
                    if (assigned && location.on_stack) {
                        if floating {
                            assigned = a64_store_float_at(ref output, source, A64Register.SP, location.offset, width == 64);
                        } else {
                            assigned = a64_store_integer_at(ref output, source, A64Register.SP, location.offset, width);
                        }
                    } else if assigned {
                        let destination: A64Register = a64_argument_register(location.first, floating);
                        assigned = destination != A64Register.None;
                        if (assigned && source != destination && floating) {
                            assigned = a64_float_move(ref output, destination, source, width == 64);
                        } else if (assigned && source != destination) {
                            assigned = a64_mov_register(ref output, destination, source, width == 64);
                        }
                    }
                    if (!assigned) {
                        return a64_lowering_error("cannot assign an AArch64 call argument");
                    }
                    argument_index++;
                }

                let called: Bool = false;
                if (direct) {
                    called = a64_branch_symbol(ref output, callee_name, true);
                } else {
                    let target: A64Register = a64_materialize_address(
                        ref program,
                        callee_id,
                        stack.storage,
                        stack.homes,
                        ref values,
                        ref output
                    );
                    called = target != A64Register.None &&
                             a64_mov_register(ref output, A64Register.X16, target, true) &&
                             a64_branch_register(ref output, A64Register.X16, true);
                }
                if (!called) {
                    return a64_lowering_error("cannot encode an AArch64 call target");
                }

                if (instruction.result != NO_WIR_VALUE && a64_aggregate_type(ref program, instruction.type_id)) {
                    let result_layout: WirTypeLayout = layouts[wir_id_index(UInt32(instruction.type_id))];
                    let result_home: A64StackSlot = a64_find_stack_slot(stack.homes, instruction.result);
                    let result_hfa: A64HFA = a64_hfa_type(ref program, instruction.type_id, layouts);
                    let register_count: Int = a64_aggregate_register_count(result_layout);
                    if (result_hfa.valid &&
                        !a64_save_hfa_registers(ref output, result_home, 0, result_hfa)) {
                        return a64_lowering_error("cannot save an AArch64 homogeneous float result");
                    }
                    if (!result_hfa.valid && register_count != 0 &&
                        !a64_save_aggregate_registers(ref output, result_home, 0, register_count)) {
                        return a64_lowering_error("cannot save an AArch64 aggregate call result");
                    }

                    instruction_index++;
                    continue;
                }

                let result_width: Int = a64_integer_width(ref program, instruction.type_id);
                if (instruction.result != NO_WIR_VALUE && result_width == 128) {
                    if (!a64_save_pair(
                        ref output,
                        stack.homes,
                        instruction.result,
                        A64RegisterPair(low=A64Register.X0, high=A64Register.X1)
                    )) {
                        return a64_lowering_error("cannot bind the AArch64 128-bit call result");
                    }

                    instruction_index++;
                    continue;
                }

                result_width = a64_scalar_width(ref program, instruction.type_id);
                let result_register: A64Register = A64Register.X0;
                if (a64_scalar_float(ref program, instruction.type_id)) { result_register = A64Register.V0; }
                if (instruction.result != NO_WIR_VALUE &&
                    (result_width == 0 || !a64_save_home(ref output, stack.homes, instruction.result, result_register, result_width))) {
                    return a64_lowering_error("cannot bind the AArch64 call result");
                }
            } else if (instruction.opcode == WirOpcode.Trap || instruction.opcode == WirOpcode.Unreachable) {
                if (instruction.operands.length() != 0 || instruction.result != NO_WIR_VALUE) {
                    return a64_lowering_error("AArch64 trap instruction has an invalid WIR shape");
                }

                a64_trap(ref output);
            } else if (instruction.opcode == WirOpcode.Jump) {
                if (instruction.operands.length() != 0 || instruction.edges.length() != 1 ||
                    !a64_write_edge(ref program, instruction.edges[0], stack.homes, layouts, ref values, ref output)) {
                    return a64_lowering_error("cannot lower AArch64 jump arguments");
                }

                let patch: Int = output.bytes.length();
                if (!a64_branch(ref output, 0, false)) { return a64_lowering_error("cannot encode AArch64 jump"); }
                fixups.append(A64BranchFixup(offset=patch, target=instruction.edges[0].target, condition=A64Condition.Always, conditional=false));
            } else if (instruction.opcode == WirOpcode.Branch) {
                if (instruction.operands.length() != 1 || instruction.edges.length() != 2) {
                    return a64_lowering_error("branch has an invalid WIR shape");
                }

                let condition: A64Register = a64_materialize(ref program, instruction.operands[0], stack.homes, ref values, ref output);
                if (condition == A64Register.None || !a64_compare_zero(ref output, condition, false)) {
                    return a64_lowering_error("cannot materialize the AArch64 branch condition");
                }

                let false_copy: Int = output.bytes.length();
                if (!a64_conditional_branch(ref output, 0, A64Condition.Equal)) {
                    return a64_lowering_error("cannot encode AArch64 conditional branch");
                }

                if (!a64_write_edge(ref program, instruction.edges[0], stack.homes, layouts, ref values, ref output)) {
                    return a64_lowering_error("cannot lower the true AArch64 branch arguments");
                }
                let true_patch: Int = output.bytes.length();
                if (!a64_branch(ref output, 0, false)) { return a64_lowering_error("cannot encode AArch64 true branch"); }
                fixups.append(A64BranchFixup(offset=true_patch, target=instruction.edges[0].target, condition=A64Condition.Always, conditional=false));

                if (!a64_patch_branch(ref output, false_copy, output.bytes.length(), A64Condition.Equal, true)) {
                    return a64_lowering_error("cannot patch AArch64 branch argument path");
                }

                if (!a64_write_edge(ref program, instruction.edges[1], stack.homes, layouts, ref values, ref output)) {
                    return a64_lowering_error("cannot lower the false AArch64 branch arguments");
                }
                let false_patch: Int = output.bytes.length();
                if (!a64_branch(ref output, 0, false)) { return a64_lowering_error("cannot encode AArch64 branch fallback"); }
                fixups.append(A64BranchFixup(offset=false_patch, target=instruction.edges[1].target, condition=A64Condition.Always, conditional=false));
            } else if (instruction.opcode == WirOpcode.Return) {
                if (instruction.operands.length() > 1) {
                    return a64_lowering_error("return has too many operands");
                }
                if (instruction.operands.length() == 1) {
                    let value: WirValueID = instruction.operands[0];
                    let value_type: WirTypeID = program.arena.values[wir_id_index(UInt32(value))].type_id;
                    if (a64_aggregate_type(ref program, value_type)) {
                        let layout: WirTypeLayout = layouts[wir_id_index(UInt32(value_type))];
                        let home: A64StackSlot = a64_find_stack_slot(stack.homes, value);
                        let hfa: A64HFA = a64_hfa_type(ref program, value_type, layouts);
                        let register_count: Int = a64_aggregate_register_count(layout);
                        if (!layout.valid || home.value == NO_WIR_VALUE) {
                            return a64_lowering_error("AArch64 aggregate return value has no valid home");
                        }

                        if (hfa.valid) {
                            if (!a64_load_hfa_registers(ref output, home, 0, hfa)) {
                                return a64_lowering_error("cannot load the AArch64 homogeneous float result");
                            }
                        } else if (register_count != 0) {
                            if (!a64_load_aggregate_registers(ref output, home, 0, register_count)) {
                                return a64_lowering_error("cannot load the AArch64 aggregate return registers");
                            }
                        } else {
                            let destination: A64Register = A64Register.X9;
                            let temporary: A64Register = A64Register.X10;
                            if (stack.result_pointer_offset < 0 ||
                                !a64_load_integer(
                                    ref output,
                                    destination,
                                    A64Register.SP,
                                    stack.result_pointer_offset,
                                    64
                                ) ||
                                !a64_copy_memory(
                                    ref output,
                                    destination,
                                    0,
                                    A64Register.SP,
                                    home.offset,
                                    Int(layout.size),
                                    temporary
                                )) {
                                return a64_lowering_error("cannot copy the indirect AArch64 aggregate return value");
                            }
                        }
                    } else if (a64_integer_width(ref program, value_type) == 128) {
                        let pair: A64RegisterPair = a64_materialize_pair(ref program, value, stack.homes, ref values, ref output);
                        if (pair.low == A64Register.None || pair.high == A64Register.None ||
                            !a64_mov_register(ref output, A64Register.X0, pair.low, true) ||
                            !a64_mov_register(ref output, A64Register.X1, pair.high, true)) {
                            return a64_lowering_error("cannot move the AArch64 128-bit return value");
                        }
                    } else {
                    let source: A64Register = a64_materialize(ref program, value, stack.homes, ref values, ref output);
                    let width: Int = a64_scalar_width(ref program, value_type);
                    if (source == A64Register.None || width == 0) {
                        return a64_lowering_error("cannot materialize the AArch64 return value");
                    }
                    let result_register: A64Register = A64Register.X0;
                    let floating: Bool = a64_scalar_float(ref program, program.arena.values[wir_id_index(UInt32(value))].type_id);
                    if floating { result_register = A64Register.V0; }
                    let moved: Bool = source == result_register;
                    if (!moved && floating) {
                        moved = a64_float_move(ref output, result_register, source, width == 64);
                    } else if (!moved) {
                        moved = a64_mov_register(ref output, result_register, source, width == 64);
                    }
                    if (!moved) {
                        return a64_lowering_error("cannot move the AArch64 return value");
                    }
                    }
                }
                if has_frame {
                    if (!a64_leave_sized_frame(ref output, stack.frame_size)) {
                        return a64_lowering_error("cannot encode the AArch64 function epilogue");
                    }
                } else if (!a64_return(ref output, A64Register.X30)) {
                    return a64_lowering_error("cannot encode the AArch64 return instruction");
                }
            } else {
                return a64_lowering_error("WIR opcode " + Int(instruction.opcode) + " is not covered by initial AArch64 lowering");
            }
            instruction_index++;
        }
        i++;
    }

    if (!a64_patch_branches(ref output, offsets, fixups)) {
        return a64_lowering_error("cannot patch AArch64 control-flow edges");
    }

    return A64LoweringResult(bytes=output.bytes, errors=[], relocations=output.relocations);
}

func a64_lower_module(ref program: WirModule) -> A64ModuleResult {
    if (program.target != "aarch64-unknown-linux-gnu" || program.pointer_bits != 64) {
        return a64_module_error("the AArch64 machine backend does not support this target");
    }

    let text: Vector(Byte) = [];
    let symbols: Vector(A64Symbol) = [];
    let relocations: Vector(A64Relocation) = [];
    let i: Int = 0;

    while (i < program.arena.functions.length()) {
        let function: WirFunction = program.arena.functions[i];
        if (function.blocks.length() != 0) {
            let offset: Int = text.length();
            let lowered: A64LoweringResult = a64_lower_function(ref program, WirFuncID(UInt32(i + 1)));
            if (lowered.errors.length() != 0) {
                return a64_module_error("in function '" + function.name + "': " + lowered.errors[0]);
            }

            let byte_index: Int = 0;
            while (byte_index < lowered.bytes.length()) {
                text.append(lowered.bytes[byte_index]);
                byte_index++;
            }
            let relocation_index: Int = 0;
            while (relocation_index < lowered.relocations.length()) {
                let relocation: A64Relocation = lowered.relocations[relocation_index];
                relocation.offset += UInt32(offset);
                relocations.append(relocation);
                relocation_index++;
            }
            symbols.append(A64Symbol(name=function.name, section=".text", offset=UInt32(offset), external=function.linkage == WirLinkage.Exported));
        } else if (function.linkage == WirLinkage.External) {
            symbols.append(A64Symbol(name=function.name, section="", offset=0U, external=true));
        }
        i++;
    }

    let data: MachineDataResult = machine_emit_globals(ref program, wir_type_layouts(program), ".data.rel.ro", true);
    if (data.message.length() != 0) { return a64_module_error(data.message); }

    i = 0;
    while (i < data.symbols.length()) {
        let symbol: MachineSymbol = data.symbols[i];
        symbols.append(A64Symbol(name=symbol.name, section=symbol.section, offset=symbol.offset, external=symbol.external));
        i++;
    }
    i = 0;
    while (i < data.relocations.length()) {
        let relocation: MachineDataRelocation = data.relocations[i];
        relocations.append(A64Relocation(section=relocation.section, offset=relocation.offset, kind=A64RelocationKind.Abs64, symbol=relocation.symbol, addend=relocation.addend));
        i++;
    }

    if (symbols.length() == 0) {
        return a64_module_error("the AArch64 module contains no defined functions");
    }

    let sections: Vector(A64Section) = [A64Section(name=".text", bytes=text, alignment=4, executable=true, writable=false)];
    i = 0;
    while (i < data.sections.length()) {
        let section: MachineSection = data.sections[i];
        sections.append(A64Section(name=section.name, bytes=section.bytes, alignment=section.alignment, executable=section.executable, writable=section.writable));
        i++;
    }

    return A64ModuleResult(
        errors=[],
        sections=sections,
        symbols=symbols,
        relocations=relocations
    );
}
