// compiler/wir/verify.wl
import * from "model.wl"
import wir_value_type from "builder.wl"
import wir_type_layout from "layout.wl"

func wir_type_valid(program: WirModule, id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(id));
    return index >= 0 && index < program.arena.types.length();
}

func wir_value_valid(program: WirModule, id: WirValueID) -> Bool {
    let index: Int = wir_id_index(UInt32(id));
    return index >= 0 && index < program.arena.values.length();
}

func wir_inst_valid(program: WirModule, id: WirInstID) -> Bool {
    let index: Int = wir_id_index(UInt32(id));
    return index >= 0 && index < program.arena.instructions.length();
}

func wir_block_valid(program: WirModule, id: WirBlockID) -> Bool {
    let index: Int = wir_id_index(UInt32(id));
    return index >= 0 && index < program.arena.blocks.length();
}

func wir_func_valid(program: WirModule, id: WirFuncID) -> Bool {
    let index: Int = wir_id_index(UInt32(id));
    return index >= 0 && index < program.arena.functions.length();
}

func wir_global_valid(program: WirModule, id: WirGlobalID) -> Bool {
    let index: Int = wir_id_index(UInt32(id));
    return index >= 0 && index < program.arena.globals.length();
}

func wir_const_valid(program: WirModule, id: WirConstID) -> Bool {
    let index: Int = wir_id_index(UInt32(id));
    return index >= 0 && index < program.arena.constants.length();
}

func wir_is_integer_type(program: WirModule, id: WirTypeID) -> Bool {
    if (!wir_type_valid(program, id)) { return false; }
    let kind: WirTypeKind = program.arena.types[wir_id_index(UInt32(id))].kind;
    return kind == WirTypeKind.SignedInt || kind == WirTypeKind.UnsignedInt;
}

func wir_is_float_type(program: WirModule, id: WirTypeID) -> Bool {
    return wir_type_valid(program, id) && program.arena.types[wir_id_index(UInt32(id))].kind == WirTypeKind.FloatType;
}

func wir_is_pointer_type(program: WirModule, id: WirTypeID) -> Bool {
    return wir_type_valid(program, id) && program.arena.types[wir_id_index(UInt32(id))].kind == WirTypeKind.Pointer;
}

func wir_is_constant_value(program: WirModule, id: WirValueID) -> Bool {
    if (!wir_value_valid(program, id)) { return false; }
    let kind: WirValueKind = program.arena.values[wir_id_index(UInt32(id))].kind;
    return kind == WirValueKind.Integer || kind == WirValueKind.FloatValue || kind == WirValueKind.BoolValue ||
           kind == WirValueKind.Null || kind == WirValueKind.Constant || kind == WirValueKind.Global || kind == WirValueKind.Function;
}

func wir_type_can_zero(program: WirModule, type_id: WirTypeID) -> Bool {
    if (!wir_type_valid(program, type_id)) { return false; }
    let kind: WirTypeKind = program.arena.types[wir_id_index(UInt32(type_id))].kind;
    return kind == WirTypeKind.BoolType || kind == WirTypeKind.SignedInt || kind == WirTypeKind.UnsignedInt ||
           kind == WirTypeKind.FloatType || kind == WirTypeKind.Pointer || kind == WirTypeKind.Array || kind == WirTypeKind.Struct;
}

func wir_report(errors: Vector(String), message: String) -> Void {
    errors.append(message);
}

func wir_check_location(program: WirModule, location: WirLocation, errors: Vector(String)) -> Void {
    if (location.file != NO_WIR_FILE) {
        let file_index: Int = wir_id_index(UInt32(location.file));
        if (file_index < 0 || file_index >= program.files.length()) {
            wir_report(errors, "instruction refers to an unknown source file");
        }
    }
    if (location.end < location.start) { wir_report(errors, "instruction source range ends before it starts"); }
}

func wir_check_types(program: WirModule, errors: Vector(String)) -> Void {
    let i: Int = 0;
    while (i < program.arena.types.length()) {
        let value: WirType = program.arena.types[i];
        if (value.kind == WirTypeKind.Invalid) {
            wir_report(errors, "type table contains an invalid type");
        } else if (value.kind != WirTypeKind.Function && value.abi != WirABI.White) {
            wir_report(errors, "non-function type contains an ABI");
        } else if (value.kind == WirTypeKind.Struct && !value.complete) {
            wir_report(errors, "struct type was declared but never defined");
        } else if (value.kind == WirTypeKind.BoolType && value.bits != 1) {
            wir_report(errors, "Bool type must have a width of one bit");
        } else if ((value.kind == WirTypeKind.SignedInt || value.kind == WirTypeKind.UnsignedInt) && value.bits <= 0) {
            wir_report(errors, "numeric type has an invalid bit width");
        } else if (value.kind == WirTypeKind.FloatType && value.bits != 32 && value.bits != 64) {
            wir_report(errors, "floating-point type must be 32 or 64 bits wide");
        } else if ((value.kind == WirTypeKind.Pointer || value.kind == WirTypeKind.Array) && !wir_type_valid(program, value.element)) {
            wir_report(errors, "aggregate type refers to an unknown element type");
        }

        let j: Int = 0;
        while (j < value.fields.length()) {
            if (!wir_type_valid(program, value.fields[j])) {
                wir_report(errors, "struct type contains an unknown field type");
            } else if (program.arena.types[wir_id_index(UInt32(value.fields[j]))].kind == WirTypeKind.VoidType) {
                wir_report(errors, "struct type contains a Void field");
            }
            j++;
        }
        j = 0;
        while (j < value.parameters.length()) {
            if (!wir_type_valid(program, value.parameters[j])) {
                wir_report(errors, "function type contains an unknown parameter type");
            } else if (program.arena.types[wir_id_index(UInt32(value.parameters[j]))].kind == WirTypeKind.VoidType) {
                wir_report(errors, "function type contains a Void parameter");
            }
            j++;
        }
        if (value.kind == WirTypeKind.Array && wir_type_valid(program, value.element)) {
            let element: WirType = program.arena.types[wir_id_index(UInt32(value.element))];
            if (element.kind == WirTypeKind.VoidType) { wir_report(errors, "array type has a Void element"); }
        }
        if (value.kind == WirTypeKind.Function && !wir_type_valid(program, value.result)) {
            wir_report(errors, "function type has an unknown return type");
        }
        if (value.kind == WirTypeKind.Function && value.variadic && value.abi != WirABI.C) {
            wir_report(errors, "variadic function type does not use the C ABI");
        }
        i++;
    }
}

func wir_check_sized_type(program: WirModule, type_id: WirTypeID, states: Vector(Int), errors: Vector(String)) -> Void {
    if (!wir_type_valid(program, type_id)) { return; }
    let index: Int = wir_id_index(UInt32(type_id));
    if (states[index] == 2) { return; }
    if (states[index] == 1) {
        wir_report(errors, "aggregate type contains itself by value");
        return;
    }

    let type: WirType = program.arena.types[index];
    if (type.kind != WirTypeKind.Array && type.kind != WirTypeKind.Struct) {
        states[index] = 2;
        return;
    }

    states[index] = 1;
    if (type.kind == WirTypeKind.Array) {
        wir_check_sized_type(program, type.element, states, errors);
    } else {
        let i: Int = 0;
        while (i < type.fields.length()) {
            wir_check_sized_type(program, type.fields[i], states, errors);
            i++;
        }
    }
    states[index] = 2;
}

func wir_check_sized_types(program: WirModule, errors: Vector(String)) -> Void {
    let states: Vector(Int) = [];
    let i: Int = 0;
    while (i < program.arena.types.length()) {
        states.append(0);
        i++;
    }
    i = 0;
    while (i < program.arena.types.length()) {
        wir_check_sized_type(program, WirTypeID(UInt32(i + 1)), states, errors);
        i++;
    }
}

func wir_check_values(program: WirModule, errors: Vector(String)) -> Void {
    let i: Int = 0;
    while (i < program.arena.values.length()) {
        let value: WirValue = program.arena.values[i];
        if (!wir_type_valid(program, value.type_id)) {
            wir_report(errors, "value has an unknown type");
            i++;
            continue;
        }

        let type: WirType = program.arena.types[wir_id_index(UInt32(value.type_id))];
        if (value.kind == WirValueKind.Invalid) {
            wir_report(errors, "value table contains an invalid value");
        } else if (value.kind == WirValueKind.Integer && !wir_is_integer_type(program, value.type_id)) {
            wir_report(errors, "integer constant does not have an integer type");
        } else if (value.kind == WirValueKind.FloatValue && !wir_is_float_type(program, value.type_id)) {
            wir_report(errors, "floating-point constant does not have a floating-point type");
        } else if (value.kind == WirValueKind.FloatValue && type.bits == 32 && value.float_bits > UInt64(4294967295)) {
            wir_report(errors, "f32 constant contains bits outside its representation");
        } else if (value.kind == WirValueKind.BoolValue && value.type_id != program.bool_type) {
            wir_report(errors, "Bool constant does not use the program Bool type");
        } else if (value.kind == WirValueKind.Null && type.kind != WirTypeKind.Pointer) {
            wir_report(errors, "null value does not have a pointer type");
        } else if (value.kind == WirValueKind.Constant) {
            let constant_id: WirConstID = WirConstID(value.owner);
            if (!wir_const_valid(program, constant_id)) {
                wir_report(errors, "constant value refers to an unknown constant");
            } else if (program.arena.constants[wir_id_index(UInt32(constant_id))].type_id != value.type_id) {
                wir_report(errors, "constant value and constant definition disagree");
            }
        } else if (value.kind == WirValueKind.FunctionParameter) {
            let function_id: WirFuncID = WirFuncID(value.owner);
            if (!wir_func_valid(program, function_id)) {
                wir_report(errors, "function parameter belongs to an unknown function");
            }
        } else if (value.kind == WirValueKind.BlockParameter) {
            let block_id: WirBlockID = WirBlockID(value.owner);
            if (!wir_block_valid(program, block_id)) { wir_report(errors, "block parameter belongs to an unknown block"); }
        } else if (value.kind == WirValueKind.Instruction) {
            let instruction_id: WirInstID = WirInstID(value.owner);
            if (!wir_inst_valid(program, instruction_id)) {
                wir_report(errors, "instruction result refers to an unknown instruction");
            } else if (program.arena.instructions[wir_id_index(UInt32(instruction_id))].result != WirValueID(UInt32(i + 1))) {
                wir_report(errors, "instruction result and value definition disagree");
            }
        } else if (value.kind == WirValueKind.Global && !wir_global_valid(program, WirGlobalID(value.owner))) {
            wir_report(errors, "global address refers to an unknown global");
        } else if (value.kind == WirValueKind.Function && !wir_func_valid(program, WirFuncID(value.owner))) {
            wir_report(errors, "function address refers to an unknown function");
        }
        i++;
    }
}

func wir_check_constant(program: WirModule, constant_id: WirConstID, states: Vector(Int), errors: Vector(String)) -> Void {
    let index: Int = wir_id_index(UInt32(constant_id));
    if (states[index] == 2) { return; }
    if (states[index] == 1) {
        wir_report(errors, "constant initializer contains a cycle");
        return;
    }

    states[index] = 1;
    let constant: WirConstant = program.arena.constants[index];
    if (!wir_type_valid(program, constant.type_id)) {
        wir_report(errors, "constant has an unknown type");
        states[index] = 2;
        return;
    }

    let type: WirType = program.arena.types[wir_id_index(UInt32(constant.type_id))];
    if (constant.kind == WirConstKind.Zero) {
        if (constant.elements.length() != 0 || constant.bytes.length() != 0 ||
            constant.target != NO_WIR_VALUE || constant.addend != 0L) {
            wir_report(errors, "zero constant contains unused payload data");
        }
        if (!wir_type_can_zero(program, constant.type_id)) { wir_report(errors, "zero constant has an unsupported type"); }
    } else if (constant.kind == WirConstKind.Aggregate) {
        if (constant.bytes.length() != 0 || constant.target != NO_WIR_VALUE || constant.addend != 0L) {
            wir_report(errors, "aggregate constant contains unused payload data");
        }
        let expected_count: UIntSize = UIntSize(0U);
        if (type.kind == WirTypeKind.Struct) {
            expected_count = UIntSize(type.fields.length());
        } else if (type.kind == WirTypeKind.Array) {
            expected_count = type.length;
        } else {
            wir_report(errors, "aggregate constant does not have an aggregate type");
        }

        if (UIntSize(constant.elements.length()) != expected_count) {
            wir_report(errors, "aggregate constant has the wrong element count");
        }
        let i: Int = 0;
        while (i < constant.elements.length()) {
            let element_id: WirValueID = constant.elements[i];
            if (!wir_is_constant_value(program, element_id)) {
                wir_report(errors, "aggregate constant contains a non-constant value");
            } else {
                let element: WirValue = program.arena.values[wir_id_index(UInt32(element_id))];
                let expected_type: WirTypeID = NO_WIR_TYPE;
                if (type.kind == WirTypeKind.Struct && i < type.fields.length()) { expected_type = type.fields[i]; }
                else if (type.kind == WirTypeKind.Array && UIntSize(i) < type.length) { expected_type = type.element; }
                if (expected_type != NO_WIR_TYPE && element.type_id != expected_type) { wir_report(errors, "aggregate constant element has the wrong type"); }
                if (element.kind == WirValueKind.Constant && wir_const_valid(program, WirConstID(element.owner))) {
                    wir_check_constant(program, WirConstID(element.owner), states, errors);
                }
            }
            i++;
        }
    } else if (constant.kind == WirConstKind.Bytes) {
        if (constant.elements.length() != 0 || constant.target != NO_WIR_VALUE || constant.addend != 0L) {
            wir_report(errors, "byte constant contains unused payload data");
        }
        if (type.kind != WirTypeKind.Array || !wir_type_valid(program, type.element)) {
            wir_report(errors, "byte constant does not have an array type");
        } else {
            let element: WirType = program.arena.types[wir_id_index(UInt32(type.element))];
            if (element.kind != WirTypeKind.UnsignedInt || element.bits != 8) { wir_report(errors, "byte constant element type is not u8"); }
            if (type.length != UIntSize(constant.bytes.length())) { wir_report(errors, "byte constant length does not match its array type"); }
        }
    } else if (constant.kind == WirConstKind.Address) {
        if (constant.elements.length() != 0 || constant.bytes.length() != 0) {
            wir_report(errors, "address constant contains unused payload data");
        }
        if (!wir_value_valid(program, constant.target)) {
            wir_report(errors, "address constant refers to an unknown symbol");
        } else {
            let target: WirValue = program.arena.values[wir_id_index(UInt32(constant.target))];
            if (target.kind != WirValueKind.Global && target.kind != WirValueKind.Function) {
                wir_report(errors, "address constant target is not a symbol");
            }
            if (type.kind != WirTypeKind.Pointer && type.kind != WirTypeKind.Function) {
                wir_report(errors, "address constant does not have an address type");
            } else if (type.kind == WirTypeKind.Function && target.type_id != constant.type_id) {
                wir_report(errors, "function address constant has the wrong type");
            }
        }
    } else {
        wir_report(errors, "constant table contains an invalid constant");
    }
    states[index] = 2;
}

func wir_check_constants(program: WirModule, errors: Vector(String)) -> Void {
    let states: Vector(Int) = [];
    let owners: Vector(Int) = [];
    let i: Int = 0;
    while (i < program.arena.constants.length()) {
        states.append(0);
        owners.append(0);
        i++;
    }
    i = 0;
    while (i < program.arena.values.length()) {
        let value: WirValue = program.arena.values[i];
        if (value.kind == WirValueKind.Constant && wir_const_valid(program, WirConstID(value.owner))) {
            let index: Int = wir_id_index(value.owner);
            owners[index] = owners[index] + 1;
        }
        i++;
    }
    i = 0;
    while (i < program.arena.constants.length()) {
        let constant_id: WirConstID = WirConstID(UInt32(i + 1));
        if (owners[i] != 1) { wir_report(errors, "constant does not have exactly one value definition"); }
        wir_check_constant(program, constant_id, states, errors);
        i++;
    }
}

func wir_same_operand_types(program: WirModule, instruction: WirInstruction) -> Bool {
    if (instruction.operands.length() != 2 || !wir_value_valid(program, instruction.operands[0]) || !wir_value_valid(program, instruction.operands[1])) { return false; }
    let left: WirTypeID = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id;
    let right: WirTypeID = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))].type_id;
    return left == right && left == instruction.type_id;
}

func wir_check_binary(program: WirModule, instruction: WirInstruction, errors: Vector(String)) -> Void {
    if (!wir_same_operand_types(program, instruction)) {
        wir_report(errors, "binary instruction operands do not match its type");
        return;
    }
    let integer: Bool = wir_is_integer_type(program, instruction.type_id);
    let floating: Bool = wir_is_float_type(program, instruction.type_id);
    if (!integer && !floating) { wir_report(errors, "binary instruction requires a numeric type"); }
}

func wir_check_unary(program: WirModule, instruction: WirInstruction, errors: Vector(String)) -> Void {
    if (instruction.operands.length() != 1 || !wir_value_valid(program, instruction.operands[0])) {
        wir_report(errors, "unary instruction requires one valid operand");
        return;
    }
    if (wir_value_type(program, instruction.operands[0]) != instruction.type_id) { wir_report(errors, "unary instruction operand does not match its type"); }
}

func wir_numeric_kind(kind: WirTypeKind) -> Bool {
    return kind == WirTypeKind.SignedInt || kind == WirTypeKind.UnsignedInt || kind == WirTypeKind.FloatType;
}

func wir_type_is(program: WirModule, type_id: WirTypeID, kind: WirTypeKind) -> Bool {
    if (!wir_type_valid(program, type_id)) { return false; }
    return program.arena.types[wir_id_index(UInt32(type_id))].kind == kind;
}

func wir_is_cast(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.Truncate || opcode == WirOpcode.SignExtend || opcode == WirOpcode.ZeroExtend ||
           opcode == WirOpcode.FloatExtend || opcode == WirOpcode.FloatTruncate ||
           opcode == WirOpcode.SignedIntToFloat || opcode == WirOpcode.UnsignedIntToFloat ||
           opcode == WirOpcode.FloatToSignedInt || opcode == WirOpcode.FloatToUnsignedInt ||
           opcode == WirOpcode.Bitcast || opcode == WirOpcode.PointerToInt || opcode == WirOpcode.IntToPointer;
}

func wir_cast_matches(program: WirModule, opcode: WirOpcode, source_id: WirTypeID, target_id: WirTypeID) -> Bool {
    if (!wir_type_valid(program, source_id) || !wir_type_valid(program, target_id) || source_id == target_id) { return false; }
    let source: WirType = program.arena.types[wir_id_index(UInt32(source_id))];
    let target: WirType = program.arena.types[wir_id_index(UInt32(target_id))];
    let source_integer: Bool = source.kind == WirTypeKind.BoolType || source.kind == WirTypeKind.SignedInt || source.kind == WirTypeKind.UnsignedInt;
    let target_integer: Bool = target.kind == WirTypeKind.BoolType || target.kind == WirTypeKind.SignedInt || target.kind == WirTypeKind.UnsignedInt;

    if (opcode == WirOpcode.Truncate) { return source_integer && target_integer && source.bits > target.bits; }
    if (opcode == WirOpcode.SignExtend) { return source.kind == WirTypeKind.SignedInt && target_integer && source.bits < target.bits; }
    if (opcode == WirOpcode.ZeroExtend) { return source_integer && source.kind != WirTypeKind.SignedInt && target_integer && source.bits < target.bits; }
    if (opcode == WirOpcode.FloatExtend) { return source.kind == WirTypeKind.FloatType && target.kind == WirTypeKind.FloatType && source.bits < target.bits; }
    if (opcode == WirOpcode.FloatTruncate) { return source.kind == WirTypeKind.FloatType && target.kind == WirTypeKind.FloatType && source.bits > target.bits; }
    if (opcode == WirOpcode.SignedIntToFloat) { return source.kind == WirTypeKind.SignedInt && target.kind == WirTypeKind.FloatType; }
    if (opcode == WirOpcode.UnsignedIntToFloat) { return source.kind == WirTypeKind.UnsignedInt && target.kind == WirTypeKind.FloatType; }
    if (opcode == WirOpcode.FloatToSignedInt) { return source.kind == WirTypeKind.FloatType && target.kind == WirTypeKind.SignedInt; }
    if (opcode == WirOpcode.FloatToUnsignedInt) { return source.kind == WirTypeKind.FloatType && target.kind == WirTypeKind.UnsignedInt; }
    if (opcode == WirOpcode.PointerToInt) { return source.kind == WirTypeKind.Pointer && target_integer; }
    if (opcode == WirOpcode.IntToPointer) { return source_integer && target.kind == WirTypeKind.Pointer; }
    if (opcode != WirOpcode.Bitcast) { return false; }
    if (source.kind == WirTypeKind.Pointer && target.kind == WirTypeKind.Pointer) { return true; }
    return wir_numeric_kind(source.kind) && wir_numeric_kind(target.kind) && source.bits == target.bits;
}

func wir_equality_type(program: WirModule, type_id: WirTypeID) -> Bool {
    if (!wir_type_valid(program, type_id)) { return false; }
    let kind: WirTypeKind = program.arena.types[wir_id_index(UInt32(type_id))].kind;
    if (kind == WirTypeKind.BoolType || kind == WirTypeKind.Pointer) { return true; }
    return wir_numeric_kind(kind);
}

func wir_signed_comparison(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.SignedLess || opcode == WirOpcode.SignedLessEqual || opcode == WirOpcode.SignedGreater || opcode == WirOpcode.SignedGreaterEqual;
}

func wir_unsigned_comparison(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.UnsignedLess || opcode == WirOpcode.UnsignedLessEqual || opcode == WirOpcode.UnsignedGreater || opcode == WirOpcode.UnsignedGreaterEqual;
}

func wir_float_comparison(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.FloatLess || opcode == WirOpcode.FloatLessEqual || opcode == WirOpcode.FloatGreater || opcode == WirOpcode.FloatGreaterEqual;
}

func wir_check_no_result(program: WirModule, instruction: WirInstruction, errors: Vector(String)) -> Void {
    if (instruction.type_id != program.void_type || instruction.result != NO_WIR_VALUE) { wir_report(errors, "side-effect instruction produces a value"); }
}

func wir_atomic_load_order(order: WirMemoryOrder) -> Bool {
    return order == WirMemoryOrder.Relaxed || order == WirMemoryOrder.Acquire || order == WirMemoryOrder.SequentiallyConsistent;
}

func wir_atomic_store_order(order: WirMemoryOrder) -> Bool {
    return order == WirMemoryOrder.Relaxed || order == WirMemoryOrder.Release || order == WirMemoryOrder.SequentiallyConsistent;
}

func wir_atomic_rmw_order(order: WirMemoryOrder) -> Bool {
    return order == WirMemoryOrder.Relaxed || order == WirMemoryOrder.Acquire || order == WirMemoryOrder.Release ||
           order == WirMemoryOrder.AcquireRelease || order == WirMemoryOrder.SequentiallyConsistent;
}

func wir_atomic_rmw_op(operation: WirAtomicOp) -> Bool {
    return operation == WirAtomicOp.Exchange || operation == WirAtomicOp.Add || operation == WirAtomicOp.Subtract ||
           operation == WirAtomicOp.BitAnd || operation == WirAtomicOp.BitOr || operation == WirAtomicOp.BitXor;
}

func wir_check_atomic_pointer(program: WirModule, instruction: WirInstruction, address_index: Int, errors: Vector(String)) -> WirTypeID {
    if (address_index >= instruction.operands.length() || !wir_value_valid(program, instruction.operands[address_index])) {
        wir_report(errors, "atomic instruction requires a valid address");
        return NO_WIR_TYPE;
    }
    let pointer_type: WirTypeID = wir_value_type(program, instruction.operands[address_index]);
    if (!wir_is_pointer_type(program, pointer_type)) {
        wir_report(errors, "atomic instruction address is not a pointer");
        return NO_WIR_TYPE;
    }
    let element: WirTypeID = program.arena.types[wir_id_index(UInt32(pointer_type))].element;
    if (!wir_is_integer_type(program, element)) {
        wir_report(errors, "atomic instruction requires integer storage");
        return NO_WIR_TYPE;
    }
    return element;
}

func wir_constant_index(program: WirModule, value_id: WirValueID) -> Int {
    if (!wir_value_valid(program, value_id)) { return -1; }
    let value: WirValue = program.arena.values[wir_id_index(UInt32(value_id))];
    if (value.kind != WirValueKind.Integer || !wir_is_integer_type(program, value.type_id)) { return -1; }
    return Int(value.integer);
}

func wir_check_field(program: WirModule, instruction: WirInstruction, address: Bool, errors: Vector(String)) -> Void {
    if (instruction.operands.length() != 2 || instruction.edges.length() != 0 || !wir_value_valid(program, instruction.operands[0])) {
        wir_report(errors, "field instruction requires an aggregate and a constant field index");
        return;
    }

    let aggregate_type_id: WirTypeID = wir_value_type(program, instruction.operands[0]);
    if address {
        if (!wir_is_pointer_type(program, aggregate_type_id)) {
            wir_report(errors, "field.addr requires a pointer to a struct");
            return;
        }
        aggregate_type_id = program.arena.types[wir_id_index(UInt32(aggregate_type_id))].element;
    }
    if (!wir_type_is(program, aggregate_type_id, WirTypeKind.Struct)) {
        wir_report(errors, "field instruction requires a struct operand");
        return;
    }

    let aggregate_type: WirType = program.arena.types[wir_id_index(UInt32(aggregate_type_id))];
    let field: Int = wir_constant_index(program, instruction.operands[1]);
    if (field < 0 || field >= aggregate_type.fields.length()) {
        wir_report(errors, "field index is outside the struct layout");
        return;
    }

    let expected: WirTypeID = aggregate_type.fields[field];
    if (!wir_type_valid(program, instruction.type_id)) {
        wir_report(errors, "field instruction has an unknown result type");
        return;
    }
    if ((!address && instruction.type_id != expected) || (address && (!wir_is_pointer_type(program, instruction.type_id) || program.arena.types[wir_id_index(UInt32(instruction.type_id))].element != expected))) {
        wir_report(errors, "field result type does not match the struct field");
    }
}

func wir_check_index(program: WirModule, instruction: WirInstruction, address: Bool, errors: Vector(String)) -> Void {
    if (instruction.operands.length() != 2 || instruction.edges.length() != 0 || !wir_value_valid(program, instruction.operands[0]) || !wir_value_valid(program, instruction.operands[1])) {
        wir_report(errors, "index instruction requires an aggregate and an integer index");
        return;
    }
    if (!wir_is_integer_type(program, wir_value_type(program, instruction.operands[1]))) {
        wir_report(errors, "index operand is not an integer");
        return;
    }

    let aggregate_type_id: WirTypeID = wir_value_type(program, instruction.operands[0]);
    if address {
        if (!wir_is_pointer_type(program, aggregate_type_id)) {
            wir_report(errors, "index.addr requires a pointer operand");
            return;
        }
        aggregate_type_id = program.arena.types[wir_id_index(UInt32(aggregate_type_id))].element;
    }
    if (!address && !wir_type_is(program, aggregate_type_id, WirTypeKind.Array)) {
        wir_report(errors, "index instruction requires an array operand");
        return;
    }

    let aggregate_type: WirType = program.arena.types[wir_id_index(UInt32(aggregate_type_id))];
    let element_type: WirTypeID = aggregate_type_id;
    if (aggregate_type.kind == WirTypeKind.Array) { element_type = aggregate_type.element; }
    if (address && aggregate_type.kind == WirTypeKind.VoidType) {
        wir_report(errors, "index.addr cannot perform arithmetic on a Void pointer");
        return;
    }
    if (!wir_type_valid(program, instruction.type_id)) {
        wir_report(errors, "index instruction has an unknown result type");
        return;
    }
    if (!address && instruction.type_id != element_type) {
        wir_report(errors, "index result type does not match the array element");
    } else if (address && (!wir_is_pointer_type(program, instruction.type_id) || program.arena.types[wir_id_index(UInt32(instruction.type_id))].element != element_type)) {
        wir_report(errors, "index.addr result does not point to the indexed element");
    }
}

func wir_check_aggregate_value(program: WirModule, instruction: WirInstruction, kind: WirTypeKind, errors: Vector(String)) -> Void {
    if (instruction.edges.length() != 0 || instruction.result == NO_WIR_VALUE || !wir_type_is(program, instruction.type_id, kind)) {
        wir_report(errors, "aggregate constructor has an invalid result type or shape");
        return;
    }
    let type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
    let count: Int = type.fields.length();
    if (kind == WirTypeKind.Array) { count = Int(type.length); }
    if (instruction.operands.length() > count) {
        wir_report(errors, "aggregate constructor has too many elements");
        return;
    }
    let i: Int = 0;
    while (i < instruction.operands.length()) {
        if (wir_value_valid(program, instruction.operands[i])) {
            let expected: WirTypeID = type.element;
            if (kind == WirTypeKind.Struct) { expected = type.fields[i]; }
            if (wir_value_type(program, instruction.operands[i]) != expected) {
                wir_report(errors, "aggregate element type does not match its layout");
            }
        }
        i++;
    }
}

func wir_check_instruction(program: WirModule, instruction_id: WirInstID, block_id: WirBlockID, errors: Vector(String)) -> Void {
    let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(instruction_id))];
    wir_check_location(program, instruction.location, errors);

    let i: Int = 0;
    while (i < instruction.operands.length()) {
        if (!wir_value_valid(program, instruction.operands[i])) { wir_report(errors, "instruction uses an unknown value"); }
        i++;
    }
    i = 0;
    while (i < instruction.edges.length()) {
        let edge: WirEdge = instruction.edges[i];
        if (!wir_block_valid(program, edge.target)) {
            wir_report(errors, "instruction branches to an unknown block");
        } else {
            let target: WirBlock = program.arena.blocks[wir_id_index(UInt32(edge.target))];
            if (target.function != program.arena.blocks[wir_id_index(UInt32(block_id))].function) {
                wir_report(errors, "instruction branches outside its function");
            }
            if (edge.arguments.length() != target.parameters.length()) {
                wir_report(errors, "branch argument count does not match the target block");
            }
            let argument_index: Int = 0;
            while (argument_index < edge.arguments.length() && argument_index < target.parameters.length()) {
                let argument_id: WirValueID = edge.arguments[argument_index];
                let parameter_id: WirValueID = target.parameters[argument_index];
                if (!wir_value_valid(program, argument_id)) {
                    wir_report(errors, "branch passes an unknown value");
                } else if (!wir_value_valid(program, parameter_id)) {
                    wir_report(errors, "target block contains an unknown parameter");
                } else if (program.arena.values[wir_id_index(UInt32(argument_id))].type_id != program.arena.values[wir_id_index(UInt32(parameter_id))].type_id) {
                    wir_report(errors, "branch argument type does not match the target block");
                }
                argument_index++;
            }
        }
        i++;
    }

    if (instruction.result == NO_WIR_VALUE) {
        if (instruction.type_id != program.void_type) { wir_report(errors, "value-producing instruction has no result"); }
    } else if (!wir_value_valid(program, instruction.result)) {
        wir_report(errors, "instruction has an unknown result value");
    } else if (program.arena.values[wir_id_index(UInt32(instruction.result))].type_id != instruction.type_id) {
        wir_report(errors, "instruction result type does not match the instruction type");
    }

    let opcode: WirOpcode = instruction.opcode;
    if (opcode != WirOpcode.Call && instruction.call_type != NO_WIR_TYPE) { wir_report(errors, "non-call instruction contains a call signature"); }
    if (!wir_is_terminator(opcode) && instruction.edges.length() != 0) { wir_report(errors, "non-terminator instruction contains control-flow edges"); }
    if (opcode == WirOpcode.Invalid) {
        wir_report(errors, "instruction has an invalid opcode");
    } else if (opcode == WirOpcode.Add || opcode == WirOpcode.Subtract || opcode == WirOpcode.Multiply) {
        wir_check_binary(program, instruction, errors);
    } else if (opcode == WirOpcode.SignedDivide || opcode == WirOpcode.SignedRemainder || opcode == WirOpcode.SignedShiftRight) {
        wir_check_binary(program, instruction, errors);
        if (wir_type_valid(program, instruction.type_id) && program.arena.types[wir_id_index(UInt32(instruction.type_id))].kind != WirTypeKind.SignedInt) { wir_report(errors, "signed instruction requires a signed integer type"); }
    } else if (opcode == WirOpcode.UnsignedDivide || opcode == WirOpcode.UnsignedRemainder || opcode == WirOpcode.UnsignedShiftRight) {
        wir_check_binary(program, instruction, errors);
        if (wir_type_valid(program, instruction.type_id) && program.arena.types[wir_id_index(UInt32(instruction.type_id))].kind != WirTypeKind.UnsignedInt) { wir_report(errors, "unsigned instruction requires an unsigned integer type"); }
    } else if (opcode == WirOpcode.FloatDivide || opcode == WirOpcode.FloatRemainder) {
        wir_check_binary(program, instruction, errors);
        if (!wir_is_float_type(program, instruction.type_id)) { wir_report(errors, "floating-point instruction requires a floating-point type"); }
    } else if (opcode == WirOpcode.BitAnd || opcode == WirOpcode.BitOr || opcode == WirOpcode.BitXor) {
        if (instruction.type_id == program.bool_type) {
            if (instruction.operands.length() != 2 || !wir_value_valid(program, instruction.operands[0]) || !wir_value_valid(program, instruction.operands[1])) {
                wir_report(errors, "boolean instruction requires two valid operands");
            } else if (wir_value_type(program, instruction.operands[0]) != program.bool_type || wir_value_type(program, instruction.operands[1]) != program.bool_type) {
                wir_report(errors, "boolean instruction requires Bool operands");
            }
        } else {
            wir_check_binary(program, instruction, errors);
            if (!wir_is_integer_type(program, instruction.type_id)) { wir_report(errors, "bitwise instruction requires an integer type"); }
        }
    } else if (opcode == WirOpcode.ShiftLeft) {
        wir_check_binary(program, instruction, errors);
        if (!wir_is_integer_type(program, instruction.type_id)) { wir_report(errors, "shift instruction requires an integer type"); }
    } else if (opcode == WirOpcode.Negate) {
        wir_check_unary(program, instruction, errors);
        if (!wir_is_integer_type(program, instruction.type_id)) { wir_report(errors, "integer negation requires an integer type"); }
    } else if (opcode == WirOpcode.FloatNegate) {
        wir_check_unary(program, instruction, errors);
        if (!wir_is_float_type(program, instruction.type_id)) { wir_report(errors, "floating-point negation requires a floating-point type"); }
    } else if (opcode == WirOpcode.Not) {
        wir_check_unary(program, instruction, errors);
        if (!wir_is_integer_type(program, instruction.type_id) && instruction.type_id != program.bool_type) { wir_report(errors, "not requires a Bool or integer type"); }
    } else if (opcode == WirOpcode.Equal || opcode == WirOpcode.NotEqual || wir_signed_comparison(opcode) || wir_unsigned_comparison(opcode) || wir_float_comparison(opcode)) {
        if (instruction.operands.length() != 2 || !wir_value_valid(program, instruction.operands[0]) || !wir_value_valid(program, instruction.operands[1])) {
            wir_report(errors, "comparison requires two valid operands");
        } else {
            let left: WirTypeID = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id;
            let right: WirTypeID = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))].type_id;
            if (left != right) { wir_report(errors, "comparison operands have different types"); }
            if (instruction.type_id != program.bool_type) { wir_report(errors, "comparison result is not Bool"); }
            if (left == right && (opcode == WirOpcode.Equal || opcode == WirOpcode.NotEqual) && !wir_equality_type(program, left)) {
                wir_report(errors, "equality comparison requires a scalar or pointer type");
            }
            if (left == right && wir_signed_comparison(opcode) && !wir_type_is(program, left, WirTypeKind.SignedInt)) {
                wir_report(errors, "signed comparison requires a signed integer type");
            }
            if (left == right && wir_unsigned_comparison(opcode) && !wir_type_is(program, left, WirTypeKind.UnsignedInt)) {
                wir_report(errors, "unsigned comparison requires an unsigned integer type");
            }
            if (left == right && wir_float_comparison(opcode) && !wir_type_is(program, left, WirTypeKind.FloatType)) {
                wir_report(errors, "floating-point comparison requires a floating-point type");
            }
        }
    } else if (opcode == WirOpcode.StackAlloc) {
        if (instruction.operands.length() != 0 || instruction.edges.length() != 0 || !wir_is_pointer_type(program, instruction.type_id)) {
            wir_report(errors, "stack allocation must produce a pointer");
        } else {
            let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];
            if (wir_func_valid(program, block.function)) {
                let function: WirFunction = program.arena.functions[wir_id_index(UInt32(block.function))];
                if (function.entry != block_id) { wir_report(errors, "stack allocation is outside the function entry block"); }
            }
            let pointer: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
            if (pointer.element == program.void_type) { wir_report(errors, "stack allocation has no storage type"); }
            else if (!wir_type_layout(program, pointer.element).valid) { wir_report(errors, "stack allocation has an unsized storage type"); }
        }
    } else if (opcode == WirOpcode.Load) {
        if (instruction.operands.length() != 1 || !wir_value_valid(program, instruction.operands[0])) {
            wir_report(errors, "load requires one valid pointer operand");
        } else {
            let pointer_type_id: WirTypeID = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id;
            if (!wir_is_pointer_type(program, pointer_type_id)) {
                wir_report(errors, "load operand is not a pointer");
            } else if (program.arena.types[wir_id_index(UInt32(pointer_type_id))].element != instruction.type_id) {
                wir_report(errors, "load result does not match the pointer element type");
            }
        }
    } else if (opcode == WirOpcode.Store) {
        wir_check_no_result(program, instruction, errors);
        if (instruction.operands.length() != 2 || instruction.edges.length() != 0 || instruction.result != NO_WIR_VALUE) {
            wir_report(errors, "store requires a value and a pointer and cannot produce a result");
        } else if (wir_value_valid(program, instruction.operands[0]) && wir_value_valid(program, instruction.operands[1])) {
            let value_type_id: WirTypeID = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id;
            let pointer_type_id: WirTypeID = program.arena.values[wir_id_index(UInt32(instruction.operands[1]))].type_id;
            if (!wir_is_pointer_type(program, pointer_type_id) || program.arena.types[wir_id_index(UInt32(pointer_type_id))].element != value_type_id) {
                let expected_type_id: WirTypeID = NO_WIR_TYPE;
                if (wir_is_pointer_type(program, pointer_type_id)) { expected_type_id = program.arena.types[wir_id_index(UInt32(pointer_type_id))].element; }
                let function_name: String = "<unknown>";
                let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];
                if (wir_func_valid(program, block.function)) { function_name = program.arena.functions[wir_id_index(UInt32(block.function))].name; }
                wir_report(errors, "stored value type " + UInt32(value_type_id) + " does not match pointer element type " + UInt32(expected_type_id) + " in function '" + function_name + "'");
            }
        }
    } else if (opcode == WirOpcode.AtomicLoad) {
        if (instruction.operands.length() != 1 || instruction.edges.length() != 0 || instruction.result == NO_WIR_VALUE) {
            wir_report(errors, "atomic load requires one address and one result");
        }
        let element: WirTypeID = wir_check_atomic_pointer(program, instruction, 0, errors);
        if (element != NO_WIR_TYPE && instruction.type_id != element) { wir_report(errors, "atomic load result does not match the pointer element type"); }
        if (!wir_atomic_load_order(instruction.memory_order)) { wir_report(errors, "atomic load has an invalid memory order"); }
        if (instruction.atomic_op != WirAtomicOp.None) { wir_report(errors, "atomic load contains an RMW operation"); }
    } else if (opcode == WirOpcode.AtomicStore) {
        wir_check_no_result(program, instruction, errors);
        if (instruction.operands.length() != 2 || instruction.edges.length() != 0) {
            wir_report(errors, "atomic store requires a value and an address");
        }
        let element: WirTypeID = wir_check_atomic_pointer(program, instruction, 1, errors);
        if (element != NO_WIR_TYPE && (!wir_value_valid(program, instruction.operands[0]) || wir_value_type(program, instruction.operands[0]) != element)) {
            wir_report(errors, "atomic store value does not match the pointer element type");
        }
        if (!wir_atomic_store_order(instruction.memory_order)) { wir_report(errors, "atomic store has an invalid memory order"); }
        if (instruction.atomic_op != WirAtomicOp.None) { wir_report(errors, "atomic store contains an RMW operation"); }
    } else if (opcode == WirOpcode.AtomicRmw) {
        if (instruction.operands.length() != 2 || instruction.edges.length() != 0 || instruction.result == NO_WIR_VALUE) {
            wir_report(errors, "atomic RMW requires an address, a value, and a result");
        }
        let element: WirTypeID = wir_check_atomic_pointer(program, instruction, 0, errors);
        if (element != NO_WIR_TYPE && (!wir_value_valid(program, instruction.operands[1]) || wir_value_type(program, instruction.operands[1]) != element || instruction.type_id != element)) {
            wir_report(errors, "atomic RMW value and result must match the pointer element type");
        }
        if (!wir_atomic_rmw_op(instruction.atomic_op)) { wir_report(errors, "atomic RMW has an invalid operation"); }
        if (!wir_atomic_rmw_order(instruction.memory_order)) { wir_report(errors, "atomic RMW has an invalid memory order"); }
    } else if (opcode == WirOpcode.Field) {
        wir_check_field(program, instruction, false, errors);
    } else if (opcode == WirOpcode.FieldAddress) {
        wir_check_field(program, instruction, true, errors);
    } else if (opcode == WirOpcode.Index) {
        wir_check_index(program, instruction, false, errors);
    } else if (opcode == WirOpcode.IndexAddress) {
        wir_check_index(program, instruction, true, errors);
    } else if (opcode == WirOpcode.StructValue) {
        wir_check_aggregate_value(program, instruction, WirTypeKind.Struct, errors);
    } else if (opcode == WirOpcode.ArrayValue) {
        wir_check_aggregate_value(program, instruction, WirTypeKind.Array, errors);
    } else if (wir_is_cast(opcode)) {
        if (instruction.operands.length() != 1 || instruction.edges.length() != 0 || !wir_value_valid(program, instruction.operands[0]) || instruction.result == NO_WIR_VALUE) {
            wir_report(errors, "cast requires one operand and one result");
        } else if (!wir_cast_matches(program, opcode, wir_value_type(program, instruction.operands[0]), instruction.type_id)) {
            wir_report(errors, "cast opcode does not match its source and target types");
        }
    } else if (opcode == WirOpcode.Call) {
        if (instruction.edges.length() != 0) { wir_report(errors, "call cannot contain control-flow edges"); }
        if (instruction.operands.length() == 0 || !wir_value_valid(program, instruction.operands[0])) {
            wir_report(errors, "call has no valid callee");
        } else {
            let callee: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
            if (!wir_type_valid(program, instruction.call_type) || program.arena.types[wir_id_index(UInt32(instruction.call_type))].kind != WirTypeKind.Function) {
                wir_report(errors, "call does not have a function signature");
            } else if (!wir_type_valid(program, callee.type_id) || (program.arena.types[wir_id_index(UInt32(callee.type_id))].kind != WirTypeKind.Function && program.arena.types[wir_id_index(UInt32(callee.type_id))].kind != WirTypeKind.Pointer)) {
                wir_report(errors, "call target is not an address");
            } else {
                let signature: WirType = program.arena.types[wir_id_index(UInt32(instruction.call_type))];
                if (program.arena.types[wir_id_index(UInt32(callee.type_id))].kind == WirTypeKind.Function && callee.type_id != instruction.call_type) {
                    wir_report(errors, "direct call signature does not match the function");
                }
                let argument_count: Int = instruction.operands.length() - 1;
                if ((!signature.variadic && argument_count != signature.parameters.length()) || (signature.variadic && argument_count < signature.parameters.length())) {
                    let callee_name: String = "indirect call";
                    if (callee.kind == WirValueKind.Function && wir_func_valid(program, WirFuncID(callee.owner))) {
                        callee_name = "call to '" + program.arena.functions[wir_id_index(callee.owner)].name + "'";
                    }
                    let caller_name: String = "unknown function";
                    if (wir_block_valid(program, block_id)) {
                        let caller: WirFuncID = program.arena.blocks[wir_id_index(UInt32(block_id))].function;
                        if (wir_func_valid(program, caller)) { caller_name = "function '" + program.arena.functions[wir_id_index(UInt32(caller))].name + "'"; }
                    }
                    wir_report(errors, callee_name + " in " + caller_name + " expects " + signature.parameters.length() + " arguments, got " + argument_count);
                }
                let argument_index: Int = 0;
                while (argument_index < signature.parameters.length() && argument_index < argument_count) {
                    let argument_id: WirValueID = instruction.operands[argument_index + 1];
                    if (wir_value_valid(program, argument_id)) {
                        let argument: WirValue = program.arena.values[wir_id_index(UInt32(argument_id))];
                        if (argument.type_id != signature.parameters[argument_index]) {
                            let callee_name: String = "indirect call";
                            if (callee.kind == WirValueKind.Function && wir_func_valid(program, WirFuncID(callee.owner))) {
                                callee_name = "call to '" + program.arena.functions[wir_id_index(callee.owner)].name + "'";
                            }
                            let actual_type: WirType = program.arena.types[wir_id_index(UInt32(argument.type_id))];
                            let expected_type: WirType = program.arena.types[wir_id_index(UInt32(signature.parameters[argument_index]))];
                            let actual_element: String = "";
                            let expected_element: String = "";
                            if (wir_type_valid(program, actual_type.element)) { actual_element = program.arena.types[wir_id_index(UInt32(actual_type.element))].name; }
                            if (wir_type_valid(program, expected_type.element)) { expected_element = program.arena.types[wir_id_index(UInt32(expected_type.element))].name; }
                            let caller_name: String = "unknown function";
                            if (wir_block_valid(program, block_id)) {
                                let caller: WirFuncID = program.arena.blocks[wir_id_index(UInt32(block_id))].function;
                                if (wir_func_valid(program, caller)) { caller_name = "function '" + program.arena.functions[wir_id_index(UInt32(caller))].name + "'"; }
                            }
                            wir_report(errors, callee_name + " argument " + argument_index + " in " + caller_name + " has WIR type " + Int(argument.type_id) + "/" + actual_element + ", expected " + Int(signature.parameters[argument_index]) + "/" + expected_element);
                        }
                    }
                    argument_index++;
                }
                if (instruction.type_id != signature.result) { wir_report(errors, "call result does not match the function return type"); }
            }
        }
    } else if (opcode == WirOpcode.Retain || opcode == WirOpcode.Release) {
        wir_check_no_result(program, instruction, errors);
        if (instruction.operands.length() != 1 || instruction.edges.length() != 0 || !wir_value_valid(program, instruction.operands[0])) {
            wir_report(errors, "ownership instruction requires one valid operand");
        } else if (!wir_is_pointer_type(program, wir_value_type(program, instruction.operands[0]))) {
            wir_report(errors, "ownership instruction requires a pointer operand");
        }
    } else if (opcode == WirOpcode.Jump) {
        wir_check_no_result(program, instruction, errors);
        if (instruction.operands.length() != 0 || instruction.edges.length() != 1 || instruction.result != NO_WIR_VALUE) { wir_report(errors, "jump has an invalid shape"); }
    } else if (opcode == WirOpcode.Branch) {
        wir_check_no_result(program, instruction, errors);
        if (instruction.operands.length() != 1 || instruction.edges.length() != 2 || instruction.result != NO_WIR_VALUE) {
            wir_report(errors, "branch has an invalid shape");
        } else if (wir_value_valid(program, instruction.operands[0]) && program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id != program.bool_type) {
            wir_report(errors, "branch condition is not Bool");
        }
    } else if (opcode == WirOpcode.Return) {
        wir_check_no_result(program, instruction, errors);
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];
        if (!wir_func_valid(program, block.function)) {
            wir_report(errors, "return belongs to a block with no function");
            return;
        }
        let function: WirFunction = program.arena.functions[wir_id_index(UInt32(block.function))];
        let function_type: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
        if (instruction.edges.length() != 0) { wir_report(errors, "return cannot contain control-flow edges"); }
        if (function_type.result == program.void_type) {
            if (instruction.operands.length() != 0) { wir_report(errors, "Void function returns a value"); }
        } else if (instruction.operands.length() != 1) {
            wir_report(errors, "non-Void function does not return one value");
        } else if (wir_value_valid(program, instruction.operands[0]) && program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id != function_type.result) {
            wir_report(errors, "return value does not match the function return type");
        }
    } else if (opcode == WirOpcode.Trap) {
        wir_check_no_result(program, instruction, errors);
        if (instruction.operands.length() != 0 || instruction.edges.length() != 0 || instruction.result != NO_WIR_VALUE) { wir_report(errors, "trap instruction has an invalid shape"); }
    } else if (opcode == WirOpcode.Unreachable) {
        wir_check_no_result(program, instruction, errors);
        if (instruction.operands.length() != 0 || instruction.edges.length() != 0 || instruction.result != NO_WIR_VALUE) { wir_report(errors, "unreachable instruction has an invalid shape"); }
    } else if (opcode == WirOpcode.NullCheck) {
        wir_check_no_result(program, instruction, errors);
        if (instruction.operands.length() != 1 || instruction.edges.length() != 0 || !wir_value_valid(program, instruction.operands[0]) || !wir_is_pointer_type(program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id)) {
            wir_report(errors, "null check requires one pointer operand");
        }
    } else if (opcode == WirOpcode.BoundsCheck) {
        wir_check_no_result(program, instruction, errors);
        if (instruction.operands.length() != 2 || instruction.edges.length() != 0 || !wir_value_valid(program, instruction.operands[0]) || !wir_value_valid(program, instruction.operands[1]) || !wir_is_integer_type(program, program.arena.values[wir_id_index(UInt32(instruction.operands[0]))].type_id) || !wir_is_integer_type(program, program.arena.values[wir_id_index(UInt32(instruction.operands[1]))].type_id)) {
            wir_report(errors, "bounds check requires integer index and length operands");
        } else if (wir_value_type(program, instruction.operands[0]) != wir_value_type(program, instruction.operands[1])) {
            wir_report(errors, "bounds check operands have different types");
        }
    }
}

func wir_check_functions(program: WirModule, errors: Vector(String)) -> Void {
    let seen_instructions: Vector(Bool) = [];
    let i: Int = 0;
    while (i < program.arena.instructions.length()) { seen_instructions.append(false); i++; }

    i = 0;
    while (i < program.arena.functions.length()) {
        let function_id: WirFuncID = WirFuncID(UInt32(i + 1));
        let function: WirFunction = program.arena.functions[i];
        if (function.name.length() == 0) { wir_report(errors, "function has no name"); }
        if (!wir_type_valid(program, function.type_id) || program.arena.types[wir_id_index(UInt32(function.type_id))].kind != WirTypeKind.Function) {
            wir_report(errors, "function does not have a function type");
            i++;
            continue;
        }

        let function_type: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
        if (!wir_value_valid(program, function.address)) {
            wir_report(errors, "function has no address value");
        } else {
            let address: WirValue = program.arena.values[wir_id_index(UInt32(function.address))];
            if (address.kind != WirValueKind.Function || address.owner != UInt32(function_id) || address.type_id != function.type_id) { wir_report(errors, "function address has invalid ownership metadata"); }
        }
        if (function.parameters.length() != function_type.parameters.length()) { wir_report(errors, "function parameter count does not match its type"); }
        if (function.abi != function_type.abi) { wir_report(errors, "function ABI does not match its type"); }
        if (function.linkage == WirLinkage.External && function.abi == WirABI.White) { wir_report(errors, "external function uses the White ABI"); }
        if (function_type.variadic && function.abi != WirABI.C) { wir_report(errors, "variadic function does not use the C ABI"); }
        let j: Int = 0;
        while (j < function.parameters.length()) {
            if (!wir_value_valid(program, function.parameters[j])) {
                wir_report(errors, "function contains an unknown parameter value");
            } else {
                let parameter: WirValue = program.arena.values[wir_id_index(UInt32(function.parameters[j]))];
                if (parameter.kind != WirValueKind.FunctionParameter || parameter.owner != UInt32(function_id) || parameter.index != j) { wir_report(errors, "function parameter has invalid ownership metadata"); }
                if (j < function_type.parameters.length() && parameter.type_id != function_type.parameters[j]) { wir_report(errors, "function parameter type does not match its signature"); }
            }
            j++;
        }

        if (function.linkage == WirLinkage.External) {
            if (function.blocks.length() != 0 || function.entry != NO_WIR_BLOCK) { wir_report(errors, "external function contains a body"); }
            i++;
            continue;
        }
        if (function.blocks.length() == 0 || function.entry == NO_WIR_BLOCK) { wir_report(errors, "defined function '" + function.name + "' has no entry block"); }

        let entry_found: Bool = false;
        j = 0;
        while (j < function.blocks.length()) {
            let block_id: WirBlockID = function.blocks[j];
            if (block_id == function.entry) { entry_found = true; }
            if (!wir_block_valid(program, block_id)) {
                wir_report(errors, "function contains an unknown block");
                j++;
                continue;
            }
            let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];
            if (block.function != function_id) { wir_report(errors, "block belongs to a different function"); }
            if (block.instructions.length() == 0) { wir_report(errors, "block has no terminator"); }

            let parameter_index: Int = 0;
            while (parameter_index < block.parameters.length()) {
                let parameter_id: WirValueID = block.parameters[parameter_index];
                if (!wir_value_valid(program, parameter_id)) {
                    wir_report(errors, "block contains an unknown parameter value");
                } else {
                    let parameter: WirValue = program.arena.values[wir_id_index(UInt32(parameter_id))];
                    if (parameter.kind != WirValueKind.BlockParameter || parameter.owner != UInt32(block_id) || parameter.index != parameter_index) { wir_report(errors, "block parameter has invalid ownership metadata"); }
                }
                parameter_index++;
            }

            let k: Int = 0;
            while (k < block.instructions.length()) {
                let instruction_id: WirInstID = block.instructions[k];
                if (!wir_inst_valid(program, instruction_id)) {
                    wir_report(errors, "block contains an unknown instruction");
                    k++;
                    continue;
                }
                let instruction_index: Int = wir_id_index(UInt32(instruction_id));
                if (seen_instructions[instruction_index]) { wir_report(errors, "instruction is attached to more than one block"); }
                seen_instructions[instruction_index] = true;
                let terminator: Bool = wir_is_terminator(program.arena.instructions[instruction_index].opcode);
                if (terminator && k + 1 != block.instructions.length()) { wir_report(errors, "terminator is not the last instruction in its block"); }
                if (!terminator && k + 1 == block.instructions.length()) { wir_report(errors, "block does not end in a terminator"); }
                wir_check_instruction(program, instruction_id, block_id, errors);
                k++;
            }
            j++;
        }
        if (!entry_found) { wir_report(errors, "entry block is not part of function '" + function.name + "'"); }
        i++;
    }

    i = 0;
    while (i < seen_instructions.length()) {
        if (!seen_instructions[i]) { wir_report(errors, "instruction is not attached to a block"); }
        i++;
    }
}

func wir_check_globals(program: WirModule, errors: Vector(String)) -> Void {
    let i: Int = 0;
    while (i < program.arena.globals.length()) {
        let global: WirGlobal = program.arena.globals[i];
        let global_id: WirGlobalID = WirGlobalID(UInt32(i + 1));
        if (global.name.length() == 0) { wir_report(errors, "global has no name"); }
        if (global.alignment < 0 || (global.alignment != 0 && (global.alignment & (global.alignment - 1)) != 0)) {
            wir_report(errors, "global alignment is not a power of two");
        }
        if (!wir_type_valid(program, global.type_id)) {
            wir_report(errors, "global has an unknown type");
        } else {
            let layout: WirTypeLayout = wir_type_layout(program, global.type_id);
            if (!layout.valid) { wir_report(errors, "global has an unsized type"); }
            else if (global.alignment != 0 && global.alignment < layout.alignment) { wir_report(errors, "global alignment is smaller than the type alignment"); }
        }
        if (!wir_value_valid(program, global.address)) {
            wir_report(errors, "global has no address value");
        } else {
            let address: WirValue = program.arena.values[wir_id_index(UInt32(global.address))];
            if (address.kind != WirValueKind.Global || address.owner != UInt32(global_id) || !wir_is_pointer_type(program, address.type_id)) {
                wir_report(errors, "global address has invalid ownership metadata");
            } else if (program.arena.types[wir_id_index(UInt32(address.type_id))].element != global.type_id) {
                wir_report(errors, "global address does not point to the global type");
            }
        }
        if (global.initializer != NO_WIR_VALUE) {
            if (!wir_value_valid(program, global.initializer)) {
                wir_report(errors, "global initializer is an unknown value");
            } else {
                let initializer: WirValue = program.arena.values[wir_id_index(UInt32(global.initializer))];
                if (initializer.type_id != global.type_id) { wir_report(errors, "global initializer does not match the global type"); }
                if (!wir_is_constant_value(program, global.initializer)) { wir_report(errors, "global initializer is not a constant value"); }
            }
        }
        if (global.linkage == WirLinkage.External && global.initializer != NO_WIR_VALUE) {
            wir_report(errors, "external global has an initializer");
        } else if (global.linkage != WirLinkage.External && global.initializer == NO_WIR_VALUE) {
            wir_report(errors, "defined global has no initializer");
        }
        i++;
    }
}

func wir_check_symbols(program: WirModule, errors: Vector(String)) -> Void {
    let values: Dict(String, Bool) = Dict();
    let types: Dict(String, Bool) = Dict();
    let i: Int = 0;
    while (i < program.arena.types.length()) {
        let type: WirType = program.arena.types[i];
        if (type.kind == WirTypeKind.Struct && type.name.length() != 0) {
            if (types.contains_key(type.name)) {
                wir_report(errors, "named struct is declared more than once");
            } else {
                types.put(type.name, true);
            }
        }
        i++;
    }

    i = 0;
    while (i < program.arena.globals.length()) {
        let name: String = program.arena.globals[i].name;
        if (name.length() != 0) {
            if (values.contains_key(name)) {
                wir_report(errors, "symbol is defined more than once");
            } else {
                values.put(name, true);
            }
        }
        i++;
    }

    i = 0;
    while (i < program.arena.functions.length()) {
        let name: String = program.arena.functions[i].name;
        if (name.length() != 0) {
            if (values.contains_key(name)) {
                wir_report(errors, "symbol is defined more than once");
            } else {
                values.put(name, true);
            }
        }
        i++;
    }
}

func wir_function_block_index(function: WirFunction, block_id: WirBlockID) -> Int {
    let i: Int = 0;
    while (i < function.blocks.length()) {
        if (function.blocks[i] == block_id) { return i; }
        i++;
    }
    return -1;
}

func wir_block_reaches(program: WirModule, source_id: WirBlockID, target_id: WirBlockID) -> Bool {
    if (!wir_block_valid(program, source_id)) { return false; }
    let source: WirBlock = program.arena.blocks[wir_id_index(UInt32(source_id))];
    if (source.instructions.length() == 0) { return false; }
    let terminator_id: WirInstID = source.instructions[source.instructions.length() - 1];
    if (!wir_inst_valid(program, terminator_id)) { return false; }
    let terminator: WirInstruction = program.arena.instructions[wir_id_index(UInt32(terminator_id))];
    let i: Int = 0;
    while (i < terminator.edges.length()) {
        if (terminator.edges[i].target == target_id) { return true; }
        i++;
    }
    return false;
}

func wir_bool_row(length: Int, value: Bool) -> Vector(Bool) {
    let row: Vector(Bool) = [];
    let i: Int = 0;
    while (i < length) {
        row.append(value);
        i++;
    }
    return row;
}

func wir_dominators(program: WirModule, function: WirFunction) -> Vector(Vector(Bool)) {
    let count: Int = function.blocks.length();
    let entry: Int = wir_function_block_index(function, function.entry);
    let dominators: Vector(Vector(Bool)) = [];
    let i: Int = 0;
    while (i < count) {
        if (i == entry) {
            let row: Vector(Bool) = wir_bool_row(count, false);
            row[i] = true;
            dominators.append(row);
        } else {
            dominators.append(wir_bool_row(count, true));
        }
        i++;
    }

    let changed: Bool = true;
    while changed {
        changed = false;
        i = 0;
        while (i < count) {
            if (i == entry) { i++; continue; }
            let next: Vector(Bool) = wir_bool_row(count, true);
            let has_predecessor: Bool = false;
            let predecessor: Int = 0;
            while (predecessor < count) {
                if (wir_block_reaches(program, function.blocks[predecessor], function.blocks[i])) {
                    has_predecessor = true;
                    let bit: Int = 0;
                    while (bit < count) {
                        next[bit] = next[bit] && dominators[predecessor][bit];
                        bit++;
                    }
                }
                predecessor++;
            }
            if (!has_predecessor) { next = wir_bool_row(count, false); }
            next[i] = true;

            let bit: Int = 0;
            while (bit < count) {
                if (dominators[i][bit] != next[bit]) { changed = true; }
                bit++;
            }
            dominators[i] = next;
            i++;
        }
    }
    return dominators;
}

func wir_instruction_blocks(program: WirModule) -> Vector(WirBlockID) {
    let blocks: Vector(WirBlockID) = [];
    let i: Int = 0;
    while (i < program.arena.instructions.length()) {
        blocks.append(NO_WIR_BLOCK);
        i++;
    }
    i = 0;
    while (i < program.arena.blocks.length()) {
        let block_id: WirBlockID = WirBlockID(UInt32(i + 1));
        let block: WirBlock = program.arena.blocks[i];
        let j: Int = 0;
        while (j < block.instructions.length()) {
            blocks[wir_id_index(UInt32(block.instructions[j]))] = block_id;
            j++;
        }
        i++;
    }
    return blocks;
}

func wir_instruction_position(block: WirBlock, instruction_id: WirInstID) -> Int {
    let i: Int = 0;
    while (i < block.instructions.length()) {
        if (block.instructions[i] == instruction_id) { return i; }
        i++;
    }
    return -1;
}

func wir_value_in_scope(program: WirModule, function_id: WirFuncID, function: WirFunction, block_id: WirBlockID, instruction_id: WirInstID, value_id: WirValueID, instruction_blocks: Vector(WirBlockID), dominators: Vector(Vector(Bool))) -> Bool {
    let value: WirValue = program.arena.values[wir_id_index(UInt32(value_id))];
    if (value.kind == WirValueKind.Integer || value.kind == WirValueKind.FloatValue || value.kind == WirValueKind.BoolValue || value.kind == WirValueKind.Null || value.kind == WirValueKind.Constant || value.kind == WirValueKind.Global || value.kind == WirValueKind.Function) { return true; }
    if (value.kind == WirValueKind.FunctionParameter) { return value.owner == UInt32(function_id); }

    let definition_block: WirBlockID = NO_WIR_BLOCK;
    if (value.kind == WirValueKind.BlockParameter) {
        definition_block = WirBlockID(value.owner);
    } else if (value.kind == WirValueKind.Instruction) {
        definition_block = instruction_blocks[wir_id_index(value.owner)];
    } else {
        return false;
    }

    if (!wir_block_valid(program, definition_block)) { return false; }
    let definition: WirBlock = program.arena.blocks[wir_id_index(UInt32(definition_block))];
    if (definition.function != function_id) { return false; }
    if (definition_block == block_id) {
        if (value.kind == WirValueKind.BlockParameter) { return true; }
        return wir_instruction_position(definition, WirInstID(value.owner)) < wir_instruction_position(definition, instruction_id);
    }

    let definition_index: Int = wir_function_block_index(function, definition_block);
    let use_index: Int = wir_function_block_index(function, block_id);
    return definition_index >= 0 && use_index >= 0 && dominators[use_index][definition_index];
}

func wir_check_value_scopes(program: WirModule, errors: Vector(String)) -> Void {
    let instruction_blocks: Vector(WirBlockID) = wir_instruction_blocks(program);
    let function_index: Int = 0;
    while (function_index < program.arena.functions.length()) {
        let function_id: WirFuncID = WirFuncID(UInt32(function_index + 1));
        let function: WirFunction = program.arena.functions[function_index];
        if (function.linkage == WirLinkage.External) { function_index++; continue; }
        let dominators: Vector(Vector(Bool)) = wir_dominators(program, function);
        let block_index: Int = 0;
        while (block_index < function.blocks.length()) {
            let block_id: WirBlockID = function.blocks[block_index];
            let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];
            let instruction_index: Int = 0;
            while (instruction_index < block.instructions.length()) {
                let instruction_id: WirInstID = block.instructions[instruction_index];
                let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(instruction_id))];
                let operand_index: Int = 0;
                while (operand_index < instruction.operands.length()) {
                    if (!wir_value_in_scope(program, function_id, function, block_id, instruction_id, instruction.operands[operand_index], instruction_blocks, dominators)) {
                        wir_report(errors, "instruction uses a value outside its SSA scope");
                    }
                    operand_index++;
                }
                let edge_index: Int = 0;
                while (edge_index < instruction.edges.length()) {
                    let argument_index: Int = 0;
                    while (argument_index < instruction.edges[edge_index].arguments.length()) {
                        let argument: WirValueID = instruction.edges[edge_index].arguments[argument_index];
                        if (!wir_value_in_scope(program, function_id, function, block_id, instruction_id, argument, instruction_blocks, dominators)) {
                            wir_report(errors, "branch uses a value outside its SSA scope");
                        }
                        argument_index++;
                    }
                    edge_index++;
                }
                instruction_index++;
            }
            block_index++;
        }
        function_index++;
    }
}

func verify_wir(program: WirModule) -> Vector(String) {
    let errors: Vector(String) = [];
    if (program.target.length() == 0) { wir_report(errors, "module has no target triple"); }
    if (program.pointer_bits != 32 && program.pointer_bits != 64) { wir_report(errors, "module has an unsupported pointer width"); }
    if (!program.data_layout.valid) { wir_report(errors, "module has no data layout for its target"); }
    else if (program.data_layout.pointer_bits != program.pointer_bits) { wir_report(errors, "module pointer width does not match its data layout"); }
    if (!wir_type_valid(program, program.void_type) || program.arena.types[wir_id_index(UInt32(program.void_type))].kind != WirTypeKind.VoidType) { wir_report(errors, "module has no canonical Void type"); }
    if (!wir_type_valid(program, program.bool_type) || program.arena.types[wir_id_index(UInt32(program.bool_type))].kind != WirTypeKind.BoolType) { wir_report(errors, "module has no canonical Bool type"); }
    wir_check_types(program, errors);
    wir_check_sized_types(program, errors);
    wir_check_values(program, errors);
    wir_check_constants(program, errors);
    wir_check_symbols(program, errors);
    wir_check_globals(program, errors);
    wir_check_functions(program, errors);
    if (errors.length() == 0) { wir_check_value_scopes(program, errors); }
    return errors;
}
