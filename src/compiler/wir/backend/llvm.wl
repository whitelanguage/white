// compiler/wir/backend/llvm.wl
import "strings"
import * from "../model.wl"
import * from "../verify.wl"
import wir_value_type from "../builder.wl"

struct WirLLVMResult(text: String, errors: Vector(String))

func llvm_value_name(value: WirValueID) -> String { return "%v" + UInt32(value); }
func llvm_block_name(block: WirBlockID) -> String { return "b" + UInt32(block); }
func llvm_type_name(type_id: WirTypeID) -> String { return "%wir.t" + UInt32(type_id); }

func llvm_write_type(output: strings.Builder, program: WirModule, type_id: WirTypeID) -> Void? {
    let type: WirType = program.arena.types[wir_id_index(UInt32(type_id))];
    if (type.kind == WirTypeKind.VoidType) { output.write("void")?; }
    else if (type.kind == WirTypeKind.BoolType) { output.write("i1")?; }
    else if (type.kind == WirTypeKind.SignedInt || type.kind == WirTypeKind.UnsignedInt) {
        output.write("i")?;
        output.write_int(type.bits)?;
    } else if (type.kind == WirTypeKind.FloatType) {
        if (type.bits == 32) { output.write("float")?; }
        else { output.write("double")?; }
    }
    else if (type.kind == WirTypeKind.Pointer || type.kind == WirTypeKind.Function) { output.write("ptr")?; }
    else if (type.kind == WirTypeKind.Array) {
        output.write("[")?;
        output.write_uint(UInt64(type.length))?;
        output.write(" x ")?;
        llvm_write_type(output, program, type.element)?;
        output.write("]")?;
    }
    else if (type.kind == WirTypeKind.Struct) { output.write(llvm_type_name(type_id))?; }
    else { throw Error.Unsupported; }
    return;
}

func llvm_write_integer(output: strings.Builder, type: WirType, value: UInt128) -> Void? {
    if (type.kind == WirTypeKind.SignedInt && type.bits < 128) {
        let limit: UInt128 = UInt128(1U) << UInt128(type.bits);
        let sign: UInt128 = UInt128(1U) << UInt128(type.bits - 1);
        if ((value & sign) != UInt128(0U)) {
            output.write("-")?;
            output.write(String(limit - value))?;
            return;
        }
    }
    if (type.kind == WirTypeKind.SignedInt && type.bits == 128) { output.write(String(Int128(value)))?; }
    else { output.write(String(value))?; }
    return;
}

func llvm_write_float_bits(output: strings.Builder, bits: UInt64) -> Void? {
    let alphabet: String = "0123456789ABCDEF";
    output.write("0x")?;
    let shift: Int = 60;
    while (shift >= 0) {
        let digit: Int = Int((bits >> UInt64(shift)) & UInt64(15));
        output.write(alphabet.slice(digit, digit + 1))?;
        shift -= 4;
    }
    return;
}

func llvm_float32_bits(bits: UInt64) -> UInt64 {
    let sign: UInt64 = (bits & 2147483648UL) << 32UL;
    let exponent: UInt64 = (bits >> 23UL) & 255UL;
    let fraction: UInt64 = bits & 8388607UL;

    if (exponent == 255UL) { return sign | 9218868437227405312UL | (fraction << 29UL); }
    if (exponent != 0UL) { return sign | ((exponent + 896UL) << 52UL) | (fraction << 29UL); }
    if (fraction == 0UL) { return sign; }

    let leading: Int = 22;
    while ((fraction & (1UL << UInt64(leading))) == 0UL) { leading--; }
    let leading_bit: UInt64 = 1UL << UInt64(leading);
    let double_exponent: UInt64 = UInt64(leading + 874) << 52UL;
    let double_fraction: UInt64 = (fraction - leading_bit) << UInt64(52 - leading);
    return sign | double_exponent | double_fraction;
}

func llvm_write_byte_string(output: strings.Builder, bytes: String) -> Void? {
    output.write("c\"")?;
    let alphabet: String = "0123456789ABCDEF";
    let i: Int = 0;
    while (i < bytes.length()) {
        let byte: Byte = bytes[i];
        if (byte >= Byte(32) && byte <= Byte(126) && byte != Byte(34) && byte != Byte(92)) {
            output.write_byte(byte)?;
        } else {
            output.write("\\")?;
            output.write(alphabet.slice(Int(byte >> 4) & 15, (Int(byte >> 4) & 15) + 1))?;
            output.write(alphabet.slice(Int(byte) & 15, (Int(byte) & 15) + 1))?;
        }
        i++;
    }
    output.write("\"")?;
    return;
}

func llvm_write_constant(output: strings.Builder, program: WirModule, constant: WirConstant) -> Void? {
    if (constant.kind == WirConstKind.Zero) {
        output.write("zeroinitializer")?;
    } else if (constant.kind == WirConstKind.Bytes) {
        llvm_write_byte_string(output, constant.bytes)?;
    } else if (constant.kind == WirConstKind.Aggregate) {
        let type: WirType = program.arena.types[wir_id_index(UInt32(constant.type_id))];
        if (type.kind == WirTypeKind.Array) { output.write("[")?; } else { output.write("{")?; }
        let i: Int = 0;
        while (i < constant.elements.length()) {
            if (i != 0) { output.write(", ")?; }
            llvm_write_typed_value(output, program, constant.elements[i])?;
            i++;
        }
        if (type.kind == WirTypeKind.Array) { output.write("]")?; } else { output.write("}")?; }
    } else if (constant.kind == WirConstKind.Address) {
        if (constant.addend == 0L) {
            llvm_write_value(output, program, constant.target)?;
        } else {
            output.write("getelementptr (i8, ptr ")?;
            llvm_write_value(output, program, constant.target)?;
            output.write(", i64 ")?;
            output.write_long(constant.addend)?;
            output.write(")")?;
        }
    } else {
        throw Error.InvalidData;
    }
    return;
}

func llvm_write_value(output: strings.Builder, program: WirModule, value_id: WirValueID) -> Void? {
    let value: WirValue = program.arena.values[wir_id_index(UInt32(value_id))];
    if (value.kind == WirValueKind.Integer) {
        llvm_write_integer(output, program.arena.types[wir_id_index(UInt32(value.type_id))], value.integer)?;
    } else if (value.kind == WirValueKind.BoolValue) {
        if (value.integer == UInt128(0U)) { output.write("false")?; }
        else { output.write("true")?; }
    } else if (value.kind == WirValueKind.FloatValue) {
        let type: WirType = program.arena.types[wir_id_index(UInt32(value.type_id))];
        if (type.bits == 32) { llvm_write_float_bits(output, llvm_float32_bits(value.float_bits))?; }
        else if (type.bits == 64) { llvm_write_float_bits(output, value.float_bits)?; }
        else { throw Error.Unsupported; }
    }
    else if (value.kind == WirValueKind.Null) { output.write("null")?; }
    else if (value.kind == WirValueKind.Constant) { llvm_write_constant(output, program, program.arena.constants[wir_id_index(value.owner)])?; }
    else if (value.kind == WirValueKind.Global) {
        output.write("@")?;
        output.write(program.arena.globals[wir_id_index(value.owner)].name)?;
    } else if (value.kind == WirValueKind.Function) {
        output.write("@")?;
        output.write(program.arena.functions[wir_id_index(value.owner)].name)?;
    } else if (value.kind == WirValueKind.Instruction) {
        let instruction: WirInstruction = program.arena.instructions[wir_id_index(value.owner)];
        if (llvm_noop_cast(program, instruction)) { llvm_write_value(output, program, instruction.operands[0])?; }
        else { output.write(llvm_value_name(value_id))?; }
    }
    else { output.write(llvm_value_name(value_id))?; }
    return;
}

func llvm_write_typed_value(output: strings.Builder, program: WirModule, value: WirValueID) -> Void? {
    llvm_write_type(output, program, wir_value_type(program, value))?;
    output.write(" ")?;
    llvm_write_value(output, program, value)?;
    return;
}

func llvm_binary_opcode(program: WirModule, instruction: WirInstruction) -> String {
    let opcode: WirOpcode = instruction.opcode;
    let type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
    if (type.kind == WirTypeKind.FloatType) {
        if (opcode == WirOpcode.Add) { return "fadd"; }
        if (opcode == WirOpcode.Subtract) { return "fsub"; }
        if (opcode == WirOpcode.Multiply) { return "fmul"; }
    }
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
    return "";
}

func llvm_compare_opcode(program: WirModule, instruction: WirInstruction) -> String {
    let opcode: WirOpcode = instruction.opcode;
    if (opcode == WirOpcode.Equal || opcode == WirOpcode.NotEqual) {
        let operand_type: WirType = program.arena.types[wir_id_index(UInt32(wir_value_type(program, instruction.operands[0])))];
        if (operand_type.kind == WirTypeKind.FloatType) {
            if (opcode == WirOpcode.Equal) { return "fcmp oeq"; }
            return "fcmp une";
        }
        if (opcode == WirOpcode.Equal) { return "icmp eq"; }
        return "icmp ne";
    }
    if (opcode == WirOpcode.SignedLess) { return "icmp slt"; }
    if (opcode == WirOpcode.SignedLessEqual) { return "icmp sle"; }
    if (opcode == WirOpcode.SignedGreater) { return "icmp sgt"; }
    if (opcode == WirOpcode.SignedGreaterEqual) { return "icmp sge"; }
    if (opcode == WirOpcode.UnsignedLess) { return "icmp ult"; }
    if (opcode == WirOpcode.UnsignedLessEqual) { return "icmp ule"; }
    if (opcode == WirOpcode.UnsignedGreater) { return "icmp ugt"; }
    if (opcode == WirOpcode.UnsignedGreaterEqual) { return "icmp uge"; }
    if (opcode == WirOpcode.FloatLess) { return "fcmp olt"; }
    if (opcode == WirOpcode.FloatLessEqual) { return "fcmp ole"; }
    if (opcode == WirOpcode.FloatGreater) { return "fcmp ogt"; }
    if (opcode == WirOpcode.FloatGreaterEqual) { return "fcmp oge"; }
    return "";
}

func llvm_noop_cast(program: WirModule, instruction: WirInstruction) -> Bool {
    if (instruction.opcode != WirOpcode.Bitcast || instruction.operands.length() != 1) { return false; }
    let source: WirType = program.arena.types[wir_id_index(UInt32(wir_value_type(program, instruction.operands[0])))];
    let target: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
    if (source.kind == WirTypeKind.Pointer && target.kind == WirTypeKind.Pointer) { return true; }
    let source_integer: Bool = source.kind == WirTypeKind.SignedInt || source.kind == WirTypeKind.UnsignedInt;
    let target_integer: Bool = target.kind == WirTypeKind.SignedInt || target.kind == WirTypeKind.UnsignedInt;
    if (source_integer && target_integer) { return source.bits == target.bits; }
    return false;
}

func llvm_cast_opcode(opcode: WirOpcode) -> String {
    if (opcode == WirOpcode.Truncate) { return "trunc"; }
    if (opcode == WirOpcode.SignExtend) { return "sext"; }
    if (opcode == WirOpcode.ZeroExtend) { return "zext"; }
    if (opcode == WirOpcode.FloatExtend) { return "fpext"; }
    if (opcode == WirOpcode.FloatTruncate) { return "fptrunc"; }
    if (opcode == WirOpcode.SignedIntToFloat) { return "sitofp"; }
    if (opcode == WirOpcode.UnsignedIntToFloat) { return "uitofp"; }
    if (opcode == WirOpcode.FloatToSignedInt) { return "fptosi"; }
    if (opcode == WirOpcode.FloatToUnsignedInt) { return "fptoui"; }
    if (opcode == WirOpcode.Bitcast) { return "bitcast"; }
    if (opcode == WirOpcode.PointerToInt) { return "ptrtoint"; }
    if (opcode == WirOpcode.IntToPointer) { return "inttoptr"; }
    return "";
}

func llvm_callconv(program: WirModule, abi: WirABI) -> String {
    if (abi == WirABI.C) { return "ccc "; }
    if (abi != WirABI.System) { return ""; }
    if (program.target.starts_with("i686-pc-windows")) { return "x86_stdcallcc "; }
    if (program.target.starts_with("x86_64-pc-windows")) { return "win64cc "; }
    return "ccc ";
}

func llvm_function_callconv(program: WirModule, function: WirFunction) -> String {
    return llvm_callconv(program, function.abi);
}

func llvm_callee_callconv(program: WirModule, value_id: WirValueID) -> String {
    let value: WirValue = program.arena.values[wir_id_index(UInt32(value_id))];
    let type: WirType = program.arena.types[wir_id_index(UInt32(value.type_id))];
    if (type.kind != WirTypeKind.Function) { return ""; }
    return llvm_callconv(program, type.abi);
}

func llvm_instruction_supported(program: WirModule, instruction: WirInstruction) -> Bool {
    let opcode: WirOpcode = instruction.opcode;
    return llvm_binary_opcode(program, instruction).length() != 0 || llvm_compare_opcode(program, instruction).length() != 0 ||
           llvm_cast_opcode(opcode).length() != 0 || llvm_noop_cast(program, instruction) ||
           opcode == WirOpcode.Field || opcode == WirOpcode.FieldAddress || opcode == WirOpcode.Index || opcode == WirOpcode.IndexAddress ||
           opcode == WirOpcode.StructValue || opcode == WirOpcode.ArrayValue ||
           opcode == WirOpcode.NullCheck || opcode == WirOpcode.BoundsCheck ||
           opcode == WirOpcode.Retain || opcode == WirOpcode.Release ||
           opcode == WirOpcode.StackAlloc || opcode == WirOpcode.Load || opcode == WirOpcode.Store || opcode == WirOpcode.Call ||
           opcode == WirOpcode.Jump || opcode == WirOpcode.Branch || opcode == WirOpcode.Return || opcode == WirOpcode.Unreachable ||
           opcode == WirOpcode.Negate || opcode == WirOpcode.FloatNegate || opcode == WirOpcode.Not;
}

func llvm_collect_backend_errors(program: WirModule) -> Vector(String) {
    let errors: Vector(String) = verify_wir(program);
    let i: Int = 0;
    while (i < program.arena.instructions.length()) {
        let instruction: WirInstruction = program.arena.instructions[i];
        if (!llvm_instruction_supported(program, instruction)) {
            errors.append("WIR opcode " + Int(instruction.opcode) + " is not supported by the LLVM backend yet");
        }
        i++;
    }
    return errors;
}

func llvm_write_result(output: strings.Builder, instruction: WirInstruction) -> Void? {
    output.write("  ")?;
    if (instruction.result != NO_WIR_VALUE) {
        output.write(llvm_value_name(instruction.result))?;
        output.write(" = ")?;
    }
    return;
}

func llvm_write_aggregate_value(output: strings.Builder, program: WirModule, instruction: WirInstruction) -> Void? {
    if (instruction.operands.length() == 0) {
        output.write("  ")?;
        output.write(llvm_value_name(instruction.result))?;
        output.write(" = freeze ")?;
        llvm_write_type(output, program, instruction.type_id)?;
        output.write(" zeroinitializer\n")?;
        return;
    }

    let aggregate_type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
    let i: Int = 0;
    while (i < instruction.operands.length()) {
        output.write("  ")?;
        if (i == instruction.operands.length() - 1) {
            output.write(llvm_value_name(instruction.result))?;
        } else {
            output.write(llvm_value_name(instruction.result))?;
            output.write(".insert.")?;
            output.write_int(i)?;
        }
        output.write(" = insertvalue ")?;
        llvm_write_type(output, program, instruction.type_id)?;
        output.write(" ")?;
        if (i == 0) {
            output.write("zeroinitializer")?;
        } else {
            output.write(llvm_value_name(instruction.result))?;
            output.write(".insert.")?;
            output.write_int(i - 1)?;
        }
        output.write(", ")?;
        let element_type: WirTypeID = aggregate_type.element;
        if (instruction.opcode == WirOpcode.StructValue) { element_type = aggregate_type.fields[i]; }
        llvm_write_type(output, program, element_type)?;
        output.write(" ")?;
        llvm_write_value(output, program, instruction.operands[i])?;
        output.write(", ")?;
        output.write_int(i)?;
        output.write("\n")?;
        i++;
    }
    return;
}

func llvm_write_index_value(output: strings.Builder, program: WirModule, instruction: WirInstruction) -> Void? {
    let aggregate_type: WirTypeID = wir_value_type(program, instruction.operands[0]);
    let storage: String = llvm_value_name(instruction.result) + ".storage";
    let address: String = llvm_value_name(instruction.result) + ".address";
    output.write("  store ")?;
    llvm_write_typed_value(output, program, instruction.operands[0])?;
    output.write(", ptr ")?;
    output.write(storage)?;
    output.write("\n  ")?;
    output.write(address)?;
    output.write(" = getelementptr ")?;
    llvm_write_type(output, program, aggregate_type)?;
    output.write(", ptr ")?;
    output.write(storage)?;
    output.write(", i32 0, ")?;
    llvm_write_typed_value(output, program, instruction.operands[1])?;
    output.write("\n  ")?;
    output.write(llvm_value_name(instruction.result))?;
    output.write(" = load ")?;
    llvm_write_type(output, program, instruction.type_id)?;
    output.write(", ptr ")?;
    output.write(address)?;
    output.write("\n")?;
    return;
}

func llvm_write_check(output: strings.Builder, program: WirModule, instruction_id: WirInstID, instruction: WirInstruction) -> Void? {
    let suffix: String = String(UInt32(instruction_id));
    if (instruction.opcode == WirOpcode.NullCheck) {
        output.write("  %check.null.")?;
        output.write(suffix)?;
        output.write(" = icmp eq ptr ")?;
        llvm_write_value(output, program, instruction.operands[0])?;
        output.write(", null\n")?;
    } else {
        let type_id: WirTypeID = wir_value_type(program, instruction.operands[0]);
        let type: WirType = program.arena.types[wir_id_index(UInt32(type_id))];
        if (type.kind == WirTypeKind.SignedInt) {
            output.write("  %check.bounds.low.")?;
            output.write(suffix)?;
            output.write(" = icmp slt ")?;
            llvm_write_type(output, program, type_id)?;
            output.write(" ")?;
            llvm_write_value(output, program, instruction.operands[0])?;
            output.write(", 0\n  %check.bounds.high.")?;
            output.write(suffix)?;
            output.write(" = icmp sge ")?;
            llvm_write_type(output, program, type_id)?;
            output.write(" ")?;
            llvm_write_value(output, program, instruction.operands[0])?;
            output.write(", ")?;
            llvm_write_value(output, program, instruction.operands[1])?;
            output.write("\n  %check.bounds.")?;
            output.write(suffix)?;
            output.write(" = or i1 %check.bounds.low.")?;
            output.write(suffix)?;
            output.write(", %check.bounds.high.")?;
            output.write(suffix)?;
            output.write("\n")?;
        } else {
            output.write("  %check.bounds.")?;
            output.write(suffix)?;
            output.write(" = icmp uge ")?;
            llvm_write_type(output, program, type_id)?;
            output.write(" ")?;
            llvm_write_value(output, program, instruction.operands[0])?;
            output.write(", ")?;
            llvm_write_value(output, program, instruction.operands[1])?;
            output.write("\n")?;
        }
    }
    output.write("  br i1 %check.")?;
    if (instruction.opcode == WirOpcode.NullCheck) { output.write("null.")?; }
    else { output.write("bounds.")?; }
    output.write(suffix)?;
    output.write(", label %check.trap.")?;
    output.write(suffix)?;
    output.write(", label %check.cont.")?;
    output.write(suffix)?;
    output.write("\ncheck.trap.")?;
    output.write(suffix)?;
    output.write(":\n  call void @llvm.trap()\n  unreachable\ncheck.cont.")?;
    output.write(suffix)?;
    output.write(":\n")?;
    return;
}

func llvm_write_ownership(output: strings.Builder, program: WirModule, instruction: WirInstruction) -> Void? {
    output.write("  call void @__wl_")?;
    if (instruction.opcode == WirOpcode.Retain) { output.write("retain")?; }
    else { output.write("release")?; }
    output.write("(ptr ")?;
    llvm_write_value(output, program, instruction.operands[0])?;
    output.write(")\n")?;
    return;
}

func llvm_write_instruction(output: strings.Builder, program: WirModule, instruction_id: WirInstID, instruction: WirInstruction) -> Void? {
    if (llvm_noop_cast(program, instruction)) { return; }
    if (instruction.opcode == WirOpcode.StructValue || instruction.opcode == WirOpcode.ArrayValue) {
        llvm_write_aggregate_value(output, program, instruction)?;
        return;
    }
    if (instruction.opcode == WirOpcode.Index) {
        llvm_write_index_value(output, program, instruction)?;
        return;
    }
    if (instruction.opcode == WirOpcode.NullCheck || instruction.opcode == WirOpcode.BoundsCheck) {
        llvm_write_check(output, program, instruction_id, instruction)?;
        return;
    }
    if (instruction.opcode == WirOpcode.Retain || instruction.opcode == WirOpcode.Release) {
        llvm_write_ownership(output, program, instruction)?;
        return;
    }
    let binary: String = llvm_binary_opcode(program, instruction);
    let comparison: String = llvm_compare_opcode(program, instruction);
    llvm_write_result(output, instruction)?;
    if (binary.length() != 0 || comparison.length() != 0) {
        if (binary.length() != 0) { output.write(binary)?; } else { output.write(comparison)?; }
        output.write(" ")?;
        llvm_write_type(output, program, wir_value_type(program, instruction.operands[0]))?;
        output.write(" ")?;
        llvm_write_value(output, program, instruction.operands[0])?;
        output.write(", ")?;
        llvm_write_value(output, program, instruction.operands[1])?;
    } else if (instruction.opcode == WirOpcode.StackAlloc) {
        output.write("alloca ")?;
        let pointer: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        llvm_write_type(output, program, pointer.element)?;
    } else if (instruction.opcode == WirOpcode.Load) {
        output.write("load ")?;
        llvm_write_type(output, program, instruction.type_id)?;
        output.write(", ptr ")?;
        llvm_write_value(output, program, instruction.operands[0])?;
    } else if (instruction.opcode == WirOpcode.Store) {
        output.write("store ")?;
        llvm_write_typed_value(output, program, instruction.operands[0])?;
        output.write(", ptr ")?;
        llvm_write_value(output, program, instruction.operands[1])?;
    } else if (instruction.opcode == WirOpcode.Negate) {
        output.write("sub ")?;
        llvm_write_type(output, program, instruction.type_id)?;
        output.write(" 0, ")?;
        llvm_write_value(output, program, instruction.operands[0])?;
    } else if (instruction.opcode == WirOpcode.FloatNegate) {
        output.write("fneg ")?;
        llvm_write_typed_value(output, program, instruction.operands[0])?;
    } else if (instruction.opcode == WirOpcode.Not) {
        output.write("xor ")?;
        llvm_write_typed_value(output, program, instruction.operands[0])?;
        let type: WirType = program.arena.types[wir_id_index(UInt32(instruction.type_id))];
        if (type.kind == WirTypeKind.BoolType) { output.write(", true")?; }
        else { output.write(", -1")?; }
    } else if (llvm_cast_opcode(instruction.opcode).length() != 0) {
        output.write(llvm_cast_opcode(instruction.opcode))?;
        output.write(" ")?;
        llvm_write_typed_value(output, program, instruction.operands[0])?;
        output.write(" to ")?;
        llvm_write_type(output, program, instruction.type_id)?;
    } else if (instruction.opcode == WirOpcode.Field) {
        output.write("extractvalue ")?;
        llvm_write_typed_value(output, program, instruction.operands[0])?;
        output.write(", ")?;
        llvm_write_value(output, program, instruction.operands[1])?;
    } else if (instruction.opcode == WirOpcode.FieldAddress) {
        let pointer: WirType = program.arena.types[wir_id_index(UInt32(wir_value_type(program, instruction.operands[0])))];
        output.write("getelementptr ")?;
        llvm_write_type(output, program, pointer.element)?;
        output.write(", ptr ")?;
        llvm_write_value(output, program, instruction.operands[0])?;
        output.write(", i32 0, i32 ")?;
        llvm_write_value(output, program, instruction.operands[1])?;
    } else if (instruction.opcode == WirOpcode.IndexAddress) {
        let pointer: WirType = program.arena.types[wir_id_index(UInt32(wir_value_type(program, instruction.operands[0])))];
        output.write("getelementptr ")?;
        llvm_write_type(output, program, pointer.element)?;
        output.write(", ptr ")?;
        llvm_write_value(output, program, instruction.operands[0])?;
        output.write(", i32 0, ")?;
        llvm_write_typed_value(output, program, instruction.operands[1])?;
    } else if (instruction.opcode == WirOpcode.Call) {
        let signature: WirType = program.arena.types[wir_id_index(UInt32(instruction.call_type))];
        output.write("call ")?;
        output.write(llvm_callconv(program, signature.abi))?;
        llvm_write_type(output, program, signature.result)?;
        output.write(" ")?;
        llvm_write_value(output, program, instruction.operands[0])?;
        output.write("(")?;
        let i: Int = 1;
        while (i < instruction.operands.length()) {
            if (i != 1) { output.write(", ")?; }
            llvm_write_typed_value(output, program, instruction.operands[i])?;
            i++;
        }
        output.write(")")?;
    } else if (instruction.opcode == WirOpcode.Jump) {
        output.write("br label %")?;
        output.write(llvm_block_name(instruction.edges[0].target))?;
    } else if (instruction.opcode == WirOpcode.Branch) {
        output.write("br i1 ")?;
        llvm_write_value(output, program, instruction.operands[0])?;
        output.write(", label %")?;
        output.write(llvm_block_name(instruction.edges[0].target))?;
        output.write(", label %")?;
        output.write(llvm_block_name(instruction.edges[1].target))?;
    } else if (instruction.opcode == WirOpcode.Return) {
        output.write("ret ")?;
        if (instruction.operands.length() == 0) { output.write("void")?; }
        else { llvm_write_typed_value(output, program, instruction.operands[0])?; }
    } else if (instruction.opcode == WirOpcode.Unreachable) { output.write("unreachable")?; }
    output.write("\n")?;
    return;
}

func llvm_block_exit_name(program: WirModule, block_id: WirBlockID) -> String {
    let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];
    let name: String = llvm_block_name(block_id);
    let i: Int = 0;
    while (i < block.instructions.length()) {
        let instruction_id: WirInstID = block.instructions[i];
        let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(instruction_id))];
        if (instruction.opcode == WirOpcode.NullCheck || instruction.opcode == WirOpcode.BoundsCheck) {
            name = "check.cont." + UInt32(instruction_id);
        }
        i++;
    }
    return name;
}

func llvm_write_phis(output: strings.Builder, program: WirModule, function: WirFunction, block_id: WirBlockID) -> Void? {
    let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];
    let parameter_index: Int = 0;
    while (parameter_index < block.parameters.length()) {
        let parameter: WirValueID = block.parameters[parameter_index];
        output.write("  ")?;
        output.write(llvm_value_name(parameter))?;
        output.write(" = phi ")?;
        llvm_write_type(output, program, wir_value_type(program, parameter))?;
        output.write(" ")?;
        let first: Bool = true;
        let source_index: Int = 0;
        while (source_index < function.blocks.length()) {
            let source_id: WirBlockID = function.blocks[source_index];
            let source: WirBlock = program.arena.blocks[wir_id_index(UInt32(source_id))];
            if (source.instructions.length() != 0) {
                let terminator: WirInstruction = program.arena.instructions[wir_id_index(UInt32(source.instructions[source.instructions.length() - 1]))];
                let edge_index: Int = 0;
                while (edge_index < terminator.edges.length()) {
                    let edge: WirEdge = terminator.edges[edge_index];
                    if (edge.target == block_id) {
                        if (!first) { output.write(", ")?; }
                        first = false;
                        output.write("[ ")?;
                        llvm_write_value(output, program, edge.arguments[parameter_index])?;
                        output.write(", %")?;
                        output.write(llvm_block_exit_name(program, source_id))?;
                        output.write(" ]")?;
                    }
                    edge_index++;
                }
            }
            source_index++;
        }
        output.write("\n")?;
        parameter_index++;
    }
    return;
}

func llvm_linkage(linkage: WirLinkage) -> String {
    if (linkage == WirLinkage.Private) { return "private "; }
    if (linkage == WirLinkage.Internal) { return "internal "; }
    return "";
}

func llvm_write_index_storage(output: strings.Builder, program: WirModule, function: WirFunction) -> Void? {
    let block_index: Int = 0;
    while (block_index < function.blocks.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(function.blocks[block_index]))];
        let instruction_index: Int = 0;
        while (instruction_index < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];
            if (instruction.opcode == WirOpcode.Index) {
                output.write("  ")?;
                output.write(llvm_value_name(instruction.result))?;
                output.write(".storage = alloca ")?;
                llvm_write_type(output, program, wir_value_type(program, instruction.operands[0]))?;
                output.write("\n")?;
            }
            instruction_index++;
        }
        block_index++;
    }
    return;
}

func llvm_write_function(output: strings.Builder, program: WirModule, function: WirFunction) -> Void? {
    let signature: WirType = program.arena.types[wir_id_index(UInt32(function.type_id))];
    if (function.linkage == WirLinkage.External) {
        output.write("declare ")?;
    } else {
        output.write("define ")?;
        output.write(llvm_linkage(function.linkage))?;
    }
    output.write(llvm_function_callconv(program, function))?;
    llvm_write_type(output, program, signature.result)?;
    output.write(" @")?;
    output.write(function.name)?;
    output.write("(")?;
    let i: Int = 0;
    while (i < signature.parameters.length()) {
        if (i != 0) { output.write(", ")?; }
        llvm_write_type(output, program, signature.parameters[i])?;
        if (function.linkage != WirLinkage.External) {
            output.write(" ")?;
            output.write(llvm_value_name(function.parameters[i]))?;
        }
        i++;
    }
    if (signature.variadic) {
        if (signature.parameters.length() != 0) { output.write(", ")?; }
        output.write("...")?;
    }
    output.write(")")?;
    if (function.linkage == WirLinkage.External) { output.write("\n")?; return; }
    output.write(" {\n")?;
    i = 0;
    while (i < function.blocks.length()) {
        let block_id: WirBlockID = function.blocks[i];
        output.write(llvm_block_name(block_id))?;
        output.write(":\n")?;
        llvm_write_phis(output, program, function, block_id)?;
        if (block_id == function.entry) { llvm_write_index_storage(output, program, function)?; }
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(block_id))];
        let j: Int = 0;
        while (j < block.instructions.length()) {
            let instruction_id: WirInstID = block.instructions[j];
            llvm_write_instruction(output, program, instruction_id, program.arena.instructions[wir_id_index(UInt32(instruction_id))])?;
            j++;
        }
        i++;
    }
    output.write("}\n")?;
    return;
}

func llvm_write_global(output: strings.Builder, program: WirModule, global: WirGlobal) -> Void? {
    output.write("@")?;
    output.write(global.name)?;
    output.write(" = ")?;
    if (global.linkage == WirLinkage.External) {
        output.write("external ")?;
        if (global.is_const) { output.write("constant ")?; } else { output.write("global ")?; }
        llvm_write_type(output, program, global.type_id)?;
        if (global.alignment != 0) {
            output.write(", align ")?;
            output.write_int(global.alignment)?;
        }
        output.write("\n")?;
        return;
    }
    output.write(llvm_linkage(global.linkage))?;
    if (global.is_const) { output.write("constant ")?; } else { output.write("global ")?; }
    llvm_write_type(output, program, global.type_id)?;
    output.write(" ")?;
    if (global.initializer == NO_WIR_VALUE) { output.write("zeroinitializer")?; } else { llvm_write_value(output, program, global.initializer)?; }
    if (global.alignment != 0) {
        output.write(", align ")?;
        output.write_int(global.alignment)?;
    }
    output.write("\n")?;
    return;
}

func llvm_module_uses_trap(program: WirModule) -> Bool {
    let i: Int = 0;
    while (i < program.arena.instructions.length()) {
        let opcode: WirOpcode = program.arena.instructions[i].opcode;
        if (opcode == WirOpcode.NullCheck || opcode == WirOpcode.BoundsCheck) { return true; }
        i++;
    }
    return false;
}

func llvm_module_uses_opcode(program: WirModule, opcode: WirOpcode) -> Bool {
    let i: Int = 0;
    while (i < program.arena.instructions.length()) {
        if (program.arena.instructions[i].opcode == opcode) { return true; }
        i++;
    }
    return false;
}

func llvm_has_function(program: WirModule, name: String) -> Bool {
    let i: Int = 0;
    while (i < program.arena.functions.length()) {
        if (program.arena.functions[i].name == name) { return true; }
        i++;
    }
    return false;
}

func llvm_write_arc_declarations(output: strings.Builder, program: WirModule) -> Void? {
    let wrote: Bool = false;
    if (llvm_module_uses_opcode(program, WirOpcode.Retain) && !llvm_has_function(program, "__wl_retain")) {
        output.write("declare void @__wl_retain(ptr)\n")?;
        wrote = true;
    }
    if (llvm_module_uses_opcode(program, WirOpcode.Release) && !llvm_has_function(program, "__wl_release")) {
        output.write("declare void @__wl_release(ptr)\n")?;
        wrote = true;
    }
    if (wrote) { output.write("\n")?; }
    return;
}

func emit_wir_llvm(program: WirModule) -> WirLLVMResult? {
    let errors: Vector(String) = llvm_collect_backend_errors(program);
    if (errors.length() != 0) { return WirLLVMResult(text="", errors=errors); }
    let output: strings.Builder = strings.Builder(4096);
    output.write("target triple = \"")?;
    output.write(program.target)?;
    output.write("\"\n\n")?;
    if (llvm_module_uses_trap(program)) { output.write("declare void @llvm.trap()\n\n")?; }
    llvm_write_arc_declarations(output, program)?;
    let wrote_struct: Bool = false;
    let i: Int = 0;
    while (i < program.arena.types.length()) {
        let type_id: WirTypeID = WirTypeID(UInt32(i + 1));
        let type: WirType = program.arena.types[i];
        if (type.kind == WirTypeKind.Struct) {
            wrote_struct = true;
            output.write(llvm_type_name(type_id))?;
            output.write(" = type { ")?;
            let field: Int = 0;
            while (field < type.fields.length()) {
                if (field != 0) { output.write(", ")?; }
                llvm_write_type(output, program, type.fields[field])?;
                field++;
            }
            output.write(" }\n")?;
        }
        i++;
    }
    if (wrote_struct) { output.write("\n")?; }
    i = 0;
    while (i < program.arena.globals.length()) {
        llvm_write_global(output, program, program.arena.globals[i])?;
        i++;
    }
    if (program.arena.globals.length() != 0) { output.write("\n")?; }
    i = 0;
    while (i < program.arena.functions.length()) {
        if (i != 0) { output.write("\n")?; }
        llvm_write_function(output, program, program.arena.functions[i])?;
        i++;
    }
    return WirLLVMResult(text=output.build()?, errors=[]);
}
