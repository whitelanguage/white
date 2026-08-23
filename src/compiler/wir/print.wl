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

func wir_write_instruction(output: strings.Builder, program: WirModule, instruction: WirInstruction) -> Void? {
    if (instruction.result != NO_WIR_VALUE) {
        wir_write_value(output, program, instruction.result)?;
        output.write(":")?;
        wir_write_type(output, program, instruction.type_id)?;
        output.write(" = ")?;
    }

    if (instruction.opcode == WirOpcode.Add) {
        output.write("add ")?;
        wir_write_value(output, program, instruction.operands[0])?;
        output.write(", ")?;
        wir_write_value(output, program, instruction.operands[1])?;
    } else if (instruction.opcode == WirOpcode.Jump) {
        output.write("jmp ")?;
        wir_write_edge(output, program, instruction.edges[0])?;
    } else if (instruction.opcode == WirOpcode.Return) {
        output.write("ret")?;
        if (instruction.operands.length() != 0) {
            output.write(" ")?;
            wir_write_value(output, program, instruction.operands[0])?;
        }
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

func wir_write_function(output: strings.Builder, program: WirModule, function: WirFunction) -> Void? {
    if (function.linkage == WirLinkage.External || program.arena.types[wir_id_index(UInt32(function.type_id))].variadic) { throw Error.Unsupported; }
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    output.write("func @")?;
    output.write(function.name)?;
    output.write("(")?;
    let i: Int = 0;
    while (i < function.parameters.length()) {
        if (i != 0) { output.write(", ")?; }
        wir_write_value(output, program, function.parameters[i])?;
        output.write(":")?;
        wir_write_type(output, program, signature.parameters[i])?;
        i++;
    }
    output.write(") -> ")?;
    wir_write_type(output, program, signature.result)?;
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
    if (wrote_types && program.arena.functions.length() != 0) { output.write("\n")?; }

    let i: Int = 0;
    while (i < program.arena.functions.length()) {
        if (i != 0) { output.write("\n")?; }
        wir_write_function(output, program, program.arena.functions[i])?;
        i++;
    }
    return output.build()?;
}
