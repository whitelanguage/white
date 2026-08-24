// compiler/wir/verify.wl
import * from "model.wl"
import wir_value_type from "builder.wl"

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

func wir_cast_allowed(program: WirModule, source: WirTypeID, target: WirTypeID) -> Bool {
    if (!wir_type_valid(program, source) || !wir_type_valid(program, target)) { return false; }
    let source_type: WirType = program.arena.types[wir_id_index(UInt32(source))];
    let target_type: WirType = program.arena.types[wir_id_index(UInt32(target))];
    if (wir_numeric_kind(source_type.kind) && wir_numeric_kind(target_type.kind)) { return true; }
    return source_type.kind == WirTypeKind.Pointer && target_type.kind == WirTypeKind.Pointer;
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
    } else if (opcode == WirOpcode.BitAnd || opcode == WirOpcode.BitOr || opcode == WirOpcode.BitXor || opcode == WirOpcode.ShiftLeft) {
        wir_check_binary(program, instruction, errors);
        if (!wir_is_integer_type(program, instruction.type_id)) { wir_report(errors, "bitwise instruction requires an integer type"); }
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
        if (instruction.operands.length() != 0 || instruction.edges.length() != 0 || !wir_is_pointer_type(program, instruction.type_id)) { wir_report(errors, "stack allocation must produce a pointer"); }
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
                wir_report(errors, "stored value does not match the pointer element type");
            }
        }
    } else if (opcode == WirOpcode.Cast) {
        if (instruction.operands.length() != 1 || instruction.edges.length() != 0 || !wir_value_valid(program, instruction.operands[0]) || instruction.result == NO_WIR_VALUE) {
            wir_report(errors, "cast requires one operand and one result");
        } else if (!wir_cast_allowed(program, wir_value_type(program, instruction.operands[0]), instruction.type_id)) {
            wir_report(errors, "cast uses incompatible source and target types");
        }
    } else if (opcode == WirOpcode.Call) {
        if (instruction.edges.length() != 0) { wir_report(errors, "call cannot contain control-flow edges"); }
        if (instruction.operands.length() == 0 || !wir_value_valid(program, instruction.operands[0])) {
            wir_report(errors, "call has no valid callee");
        } else {
            let callee: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
            if (!wir_type_valid(program, callee.type_id) || program.arena.types[wir_id_index(UInt32(callee.type_id))].kind != WirTypeKind.Function) {
                wir_report(errors, "call target does not have a function type");
            } else {
                let signature: WirType = program.arena.types[wir_id_index(UInt32(callee.type_id))];
                let argument_count: Int = instruction.operands.length() - 1;
                if ((!signature.variadic && argument_count != signature.parameters.length()) || (signature.variadic && argument_count < signature.parameters.length())) { wir_report(errors, "call argument count does not match the function type"); }
                let argument_index: Int = 0;
                while (argument_index < signature.parameters.length() && argument_index < argument_count) {
                    let argument_id: WirValueID = instruction.operands[argument_index + 1];
                    if (wir_value_valid(program, argument_id)) {
                        let argument: WirValue = program.arena.values[wir_id_index(UInt32(argument_id))];
                        if (argument.type_id != signature.parameters[argument_index]) { wir_report(errors, "call argument type does not match the function type"); }
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
        if (function.linkage == WirLinkage.External && function.abi == WirABI.White) { wir_report(errors, "external function uses the White ABI"); }
        if (function.linkage != WirLinkage.External && function.abi != WirABI.White) { wir_report(errors, "defined function uses a foreign ABI"); }
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
        if (function.blocks.length() == 0 || function.entry == NO_WIR_BLOCK) { wir_report(errors, "defined function has no entry block"); }

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
        if (!entry_found) { wir_report(errors, "function entry block is not part of the function"); }
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
        if (!wir_type_valid(program, global.type_id)) { wir_report(errors, "global has an unknown type"); }
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
                if (initializer.kind == WirValueKind.Instruction || initializer.kind == WirValueKind.FunctionParameter || initializer.kind == WirValueKind.BlockParameter) { wir_report(errors, "global initializer is not a constant value"); }
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

func verify_wir(program: WirModule) -> Vector(String) {
    let errors: Vector(String) = [];
    if (program.pointer_bits != 32 && program.pointer_bits != 64) { wir_report(errors, "module has an unsupported pointer width"); }
    if (!wir_type_valid(program, program.void_type) || program.arena.types[wir_id_index(UInt32(program.void_type))].kind != WirTypeKind.VoidType) { wir_report(errors, "module has no canonical Void type"); }
    if (!wir_type_valid(program, program.bool_type) || program.arena.types[wir_id_index(UInt32(program.bool_type))].kind != WirTypeKind.BoolType) { wir_report(errors, "module has no canonical Bool type"); }
    wir_check_types(program, errors);
    wir_check_values(program, errors);
    wir_check_symbols(program, errors);
    wir_check_globals(program, errors);
    wir_check_functions(program, errors);
    return errors;
}
