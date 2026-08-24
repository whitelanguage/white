// compiler/wir/print.wl
import "strings"
import * from "model.wl"
import * from "verify.wl"

func wir_type_name(program: WirModule, type_id: WirTypeID) -> String {
    let type: WirType = program.arena.types[wir_id_index(UInt32(type_id))];
    if (type.name.length() != 0) { return type.name; }
    return "t" + wir_id_index(UInt32(type_id));
}

func wir_write_type(output: strings.Builder, program: WirModule, type_id: WirTypeID) -> Void? {
    let type: WirType = program.arena.types[wir_id_index(UInt32(type_id))];
    if (type.kind == WirTypeKind.VoidType) {
        output.write("void")?;
    } else if (type.kind == WirTypeKind.BoolType) {
        output.write("bool")?;
    } else if (type.kind == WirTypeKind.SignedInt) {
        output.write("i")?;
        output.write_int(type.bits)?;
    } else if (type.kind == WirTypeKind.UnsignedInt) {
        output.write("u")?;
        output.write_int(type.bits)?;
    } else if (type.kind == WirTypeKind.FloatType) {
        output.write("f")?;
        output.write_int(type.bits)?;
    } else if (type.kind == WirTypeKind.Pointer) {
        output.write("ptr<")?;
        wir_write_type(output, program, type.element)?;
        output.write(">")?;
    } else if (type.kind == WirTypeKind.Array) {
        output.write("[")?;
        wir_write_type(output, program, type.element)?;
        output.write("; ")?;
        output.write_uint(UInt64(type.length))?;
        output.write("]")?;
    } else if (type.kind == WirTypeKind.Struct) {
        output.write("!")?;
        output.write(wir_type_name(program, type_id))?;
    } else if (type.kind == WirTypeKind.Function) {
        output.write("func(")?;
        let i: Int = 0;
        while (i < type.parameters.length()) {
            if (i != 0) { output.write(", ")?; }
            wir_write_type(output, program, type.parameters[i])?;
            i++;
        }
        if (type.variadic) {
            if (type.parameters.length() != 0) { output.write(", ")?; }
            output.write("...")?;
        }
        output.write(") -> ")?;
        wir_write_type(output, program, type.result)?;
    } else {
        throw Error.InvalidData;
    }
    return;
}

func wir_write_hex(output: strings.Builder, value: UInt64, digits: Int) -> Void? {
    let alphabet: String = "0123456789ABCDEF";
    let shift: Int = (digits - 1) * 4;
    while (shift >= 0) {
        let digit: Int = Int((value >> UInt64(shift)) & UInt64(15));
        output.write(alphabet.slice(digit, digit + 1))?;
        shift -= 4;
    }
    return;
}

func wir_write_value(output: strings.Builder, program: WirModule, value_id: WirValueID) -> Void? {
    let value: WirValue = program.arena.values[wir_id_index(UInt32(value_id))];
    if (value.kind == WirValueKind.Integer) {
        output.write(String(value.integer))?;
    } else if (value.kind == WirValueKind.FloatValue) {
        let type: WirType = program.arena.types[wir_id_index(UInt32(value.type_id))];
        output.write("f")?;
        output.write_int(type.bits)?;
        output.write("(0x")?;
        if (type.bits == 32) { wir_write_hex(output, value.float_bits, 8)?; } else { wir_write_hex(output, value.float_bits, 16)?; }
        output.write(")")?;
    } else if (value.kind == WirValueKind.BoolValue) {
        if (value.integer == UInt128(0U)) { output.write("false")?; } else { output.write("true")?; }
    } else if (value.kind == WirValueKind.Null) {
        output.write("null")?;
    } else if (value.kind == WirValueKind.Global || value.kind == WirValueKind.Function) {
        output.write("@")?;
        output.write(value.name)?;
    } else {
        output.write("%")?;
        if (value.name.length() != 0) {
            output.write(value.name)?;
        } else {
            output.write_int(wir_id_index(UInt32(value_id)))?;
        }
    }
    return;
}

func wir_write_edge(output: strings.Builder, program: WirModule, edge: WirEdge) -> Void? {
    let target: WirBlock = program.arena.blocks[wir_id_index(UInt32(edge.target))];
    output.write("^")?;
    output.write(target.name)?;
    output.write("(")?;
    let i: Int = 0;
    while (i < edge.arguments.length()) {
        if (i != 0) { output.write(", ")?; }
        wir_write_value(output, program, edge.arguments[i])?;
        i++;
    }
    output.write(")")?;
    return;
}

func wir_binary_name(opcode: WirOpcode) -> String {
    if (opcode == WirOpcode.Add) { return "add"; }
    if (opcode == WirOpcode.Subtract) { return "sub"; }
    if (opcode == WirOpcode.Multiply) { return "mul"; }
    if (opcode == WirOpcode.SignedDivide) { return "sdiv"; }
    if (opcode == WirOpcode.UnsignedDivide) { return "udiv"; }
    if (opcode == WirOpcode.FloatDivide) { return "fdiv"; }
    if (opcode == WirOpcode.SignedRemainder) { return "srem"; }
    if (opcode == WirOpcode.UnsignedRemainder) { return "urem"; }
    if (opcode == WirOpcode.FloatRemainder) { return "frem"; }
    if (opcode == WirOpcode.BitAnd) { return "and"; }
    if (opcode == WirOpcode.BitOr) { return "or"; }
    if (opcode == WirOpcode.BitXor) { return "xor"; }
    if (opcode == WirOpcode.ShiftLeft) { return "shl"; }
    if (opcode == WirOpcode.SignedShiftRight) { return "ashr"; }
    if (opcode == WirOpcode.UnsignedShiftRight) { return "lshr"; }
    if (opcode == WirOpcode.Equal) { return "eq"; }
    if (opcode == WirOpcode.NotEqual) { return "ne"; }
    if (opcode == WirOpcode.SignedLess) { return "slt"; }
    if (opcode == WirOpcode.SignedLessEqual) { return "sle"; }
    if (opcode == WirOpcode.SignedGreater) { return "sgt"; }
    if (opcode == WirOpcode.SignedGreaterEqual) { return "sge"; }
    if (opcode == WirOpcode.UnsignedLess) { return "ult"; }
    if (opcode == WirOpcode.UnsignedLessEqual) { return "ule"; }
    if (opcode == WirOpcode.UnsignedGreater) { return "ugt"; }
    if (opcode == WirOpcode.UnsignedGreaterEqual) { return "uge"; }
    if (opcode == WirOpcode.FloatLess) { return "flt"; }
    if (opcode == WirOpcode.FloatLessEqual) { return "fle"; }
    if (opcode == WirOpcode.FloatGreater) { return "fgt"; }
    if (opcode == WirOpcode.FloatGreaterEqual) { return "fge"; }
    return "";
}

func wir_unary_name(opcode: WirOpcode) -> String {
    if (opcode == WirOpcode.Negate) { return "neg"; }
    if (opcode == WirOpcode.FloatNegate) { return "fneg"; }
    if (opcode == WirOpcode.Not) { return "not"; }
    return "";
}

func wir_write_operands(output: strings.Builder, program: WirModule, operands: Vector(WirValueID), start: Int) -> Void? {
    let i: Int = start;
    while (i < operands.length()) {
        if (i != start) { output.write(", ")?; }
        wir_write_value(output, program, operands[i])?;
        i++;
    }
    return;
}

func wir_write_instruction(output: strings.Builder, program: WirModule, instruction: WirInstruction) -> Void? {
    if (instruction.result != NO_WIR_VALUE) {
        wir_write_value(output, program, instruction.result)?;
        output.write(":")?;
        wir_write_type(output, program, instruction.type_id)?;
        output.write(" = ")?;
    }

    let binary: String = wir_binary_name(instruction.opcode);
    if (binary.length() != 0) {
        output.write(binary)?;
        output.write(" ")?;
        wir_write_operands(output, program, instruction.operands, 0)?;
    } else if (wir_unary_name(instruction.opcode).length() != 0) {
        output.write(wir_unary_name(instruction.opcode))?;
        output.write(" ")?;
        wir_write_value(output, program, instruction.operands[0])?;
    } else if (instruction.opcode == WirOpcode.StackAlloc) {
        output.write("alloca ")?;
        let pointer: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        wir_write_type(output, program, pointer.element)?;
    } else if (instruction.opcode == WirOpcode.Load) {
        output.write("load ")?;
        wir_write_value(output, program, instruction.operands[0])?;
    } else if (instruction.opcode == WirOpcode.Store) {
        output.write("store ")?;
        wir_write_operands(output, program, instruction.operands, 0)?;
    } else if (instruction.opcode == WirOpcode.Cast) {
        output.write("cast ")?;
        wir_write_value(output, program, instruction.operands[0])?;
    } else if (instruction.opcode == WirOpcode.Call) {
        output.write("call ")?;
        wir_write_value(output, program, instruction.operands[0])?;
        output.write("(")?;
        wir_write_operands(output, program, instruction.operands, 1)?;
        output.write(")")?;
    } else if (instruction.opcode == WirOpcode.Retain) {
        output.write("retain ")?;
        wir_write_value(output, program, instruction.operands[0])?;
    } else if (instruction.opcode == WirOpcode.Release) {
        output.write("release ")?;
        wir_write_value(output, program, instruction.operands[0])?;
    } else if (instruction.opcode == WirOpcode.NullCheck) {
        output.write("check.null ")?;
        wir_write_value(output, program, instruction.operands[0])?;
    } else if (instruction.opcode == WirOpcode.BoundsCheck) {
        output.write("check.bounds ")?;
        wir_write_operands(output, program, instruction.operands, 0)?;
    } else if (instruction.opcode == WirOpcode.Jump) {
        output.write("jmp ")?;
        wir_write_edge(output, program, instruction.edges[0])?;
    } else if (instruction.opcode == WirOpcode.Branch) {
        output.write("br ")?;
        wir_write_value(output, program, instruction.operands[0])?;
        output.write(", ")?;
        wir_write_edge(output, program, instruction.edges[0])?;
        output.write(", ")?;
        wir_write_edge(output, program, instruction.edges[1])?;
    } else if (instruction.opcode == WirOpcode.Return) {
        output.write("ret")?;
        if (instruction.operands.length() != 0) {
            output.write(" ")?;
            wir_write_value(output, program, instruction.operands[0])?;
        }
    } else if (instruction.opcode == WirOpcode.Unreachable) {
        output.write("unreachable")?;
    } else {
        throw Error.Unsupported;
    }
    return;
}

func wir_write_structs(output: strings.Builder, program: WirModule) -> Bool? {
    let wrote: Bool = false;
    let i: Int = 0;
    while (i < program.arena.types.length()) {
        let type: WirType = program.arena.types[i];
        if (type.kind == WirTypeKind.Struct) {
            if wrote { output.write("\n")?; }
            wrote = true;
            output.write("type !")?;
            output.write(wir_type_name(program, WirTypeID(UInt32(i + 1))))?;
            output.write(" = {")?;
            let field_index: Int = 0;
            while (field_index < type.fields.length()) {
                if (field_index != 0) { output.write(", ")?; }
                wir_write_type(output, program, type.fields[field_index])?;
                field_index++;
            }
            output.write("}\n")?;
        }
        i++;
    }
    return wrote;
}

func wir_linkage_name(linkage: WirLinkage) -> String? {
    if (linkage == WirLinkage.Private) { return "private"; }
    if (linkage == WirLinkage.Internal) { return "internal"; }
    if (linkage == WirLinkage.Exported) { return "export"; }
    if (linkage == WirLinkage.External) { return "extern"; }
    throw Error.InvalidData;
}

func wir_write_global(output: strings.Builder, program: WirModule, item: WirGlobal) -> Void? {
    output.write(wir_linkage_name(item.linkage)?)?;
    output.write(" ")?;
    if (item.is_const) {
        output.write("const @")?;
    } else {
        output.write("global @")?;
    }
    output.write(item.name)?;
    output.write(":")?;
    wir_write_type(output, program, item.type_id)?;
    if (item.initializer != NO_WIR_VALUE) {
        output.write(" = ")?;
        wir_write_value(output, program, item.initializer)?;
    }
    output.write("\n")?;
    return;
}

func wir_write_function(output: strings.Builder, program: WirModule, function: WirFunction) -> Void? {
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    output.write(wir_linkage_name(function.linkage)?)?;
    if (function.linkage == WirLinkage.External && function.abi == WirABI.System) { output.write(" \"system\"")?; }
    output.write(" func @")?;
    output.write(function.name)?;
    output.write("(")?;
    let i: Int = 0;
    while (i < function.parameters.length()) {
        if (i != 0) { output.write(", ")?; }
        if (function.linkage != WirLinkage.External) {
            wir_write_value(output, program, function.parameters[i])?;
            output.write(":")?;
        }
        wir_write_type(output, program, signature.parameters[i])?;
        i++;
    }
    if (signature.variadic) {
        if (function.parameters.length() != 0) { output.write(", ")?; }
        output.write("...")?;
    }
    output.write(") -> ")?;
    wir_write_type(output, program, signature.result)?;
    if (function.linkage == WirLinkage.External) {
        output.write("\n")?;
        return;
    }
    output.write(" {\n")?;

    i = 0;
    while (i < function.blocks.length()) {
        if (i != 0) { output.write("\n")?; }
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(function.blocks[i]))];
        output.write("^")?;
        output.write(block.name)?;
        if (block.parameters.length() != 0) {
            output.write("(")?;
            let parameter_index: Int = 0;
            while (parameter_index < block.parameters.length()) {
                if (parameter_index != 0) { output.write(", ")?; }
                let parameter_id: WirValueID = block.parameters[parameter_index];
                wir_write_value(output, program, parameter_id)?;
                output.write(":")?;
                wir_write_type(output, program, program.arena.values[wir_id_index(UInt32(parameter_id))].type_id)?;
                parameter_index++;
            }
            output.write(")")?;
        }
        output.write(":\n")?;

        let instruction_index: Int = 0;
        while (instruction_index < block.instructions.length()) {
            output.write("    ")?;
            wir_write_instruction(output, program, program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))])?;
            output.write("\n")?;
            instruction_index++;
        }
        i++;
    }
    output.write("}\n")?;
    return;
}

func print_wir(program: WirModule) -> String? {
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) { throw Error.InvalidData; }

    let output: strings.Builder = strings.Builder(1024);
    let wrote_types: Bool = wir_write_structs(output, program)?;
    if (wrote_types && (program.arena.globals.length() != 0 || program.arena.functions.length() != 0)) { output.write("\n")?; }

    let i: Int = 0;
    while (i < program.arena.globals.length()) {
        wir_write_global(output, program, program.arena.globals[i])?;
        i++;
    }
    if (program.arena.globals.length() != 0 && program.arena.functions.length() != 0) { output.write("\n")?; }

    i = 0;
    while (i < program.arena.functions.length()) {
        if (i != 0) { output.write("\n")?; }
        wir_write_function(output, program, program.arena.functions[i])?;
        i++;
    }
    return output.build()?;
}
