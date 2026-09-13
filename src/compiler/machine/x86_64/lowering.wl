// compiler/machine/x86_64/lowering.wl
import * from "model.wl"
import * from "encoder.wl"
import * from "../../wir/model.wl"

struct X86LoweringResult(
    bytes: Vector(Byte),
    errors: Vector(String)
)

func x86_lowering_error(message: String) -> X86LoweringResult {
    return X86LoweringResult(bytes=[], errors=[message]);
}

func x86_lower_return(program: WirModule, instruction: WirInstruction, ref output: X86CodeBuffer) -> Bool {
    if (instruction.operands.length() == 0) {
        x86_return(ref output);
        return true;
    }

    if (instruction.operands.length() != 1) {
        return false;
    }

    let value: WirValue = program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
    if (value.kind != WirValueKind.Integer) { return false; }
    let type: WirType = program.arena.types[wir_id_index(UInt32(value.type_id))];
    if (type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt) {
        return false;
    }

    if (type.bits <= 32) {
        x86_mov_eax_imm32(ref output, UInt32(value.integer));
    } else if (type.bits <= 64) {
        x86_mov_rax_imm64(ref output, UInt64(value.integer));
    } else {
        return false;
    }

    x86_return(ref output);
    return true;
}

func x86_lower_function(program: WirModule, function_id: WirFuncID) -> X86LoweringResult {
    let function_index: Int = wir_id_index(UInt32(function_id));
    if (function_index < 0 || function_index >= program.arena.functions.length()) {
        return x86_lowering_error("function id is outside the WIR function table");
    }

    let function: WirFunction = program.arena.functions[function_index];
    if (function.linkage == WirLinkage.External) {
        return x86_lowering_error("external functions do not have machine code");
    }
    if (function.blocks.length() != 1) {
        return x86_lowering_error("the initial x86_64 lowering supports one basic block");
    }

    let block_index: Int = wir_id_index(UInt32(function.blocks[0]));
    if (block_index < 0 || block_index >= program.arena.blocks.length()) {
        return x86_lowering_error("function refers to an unknown basic block");
    }
    let block: WirBlock = program.arena.blocks[block_index];
    if (block.function != function_id) {
        return x86_lowering_error("function refers to a basic block owned by another function");
    }
    if (block.instructions.length() == 0) {
        return x86_lowering_error("the initial x86_64 lowering requires a non-empty basic block");
    }

    let output: X86CodeBuffer = x86_new_code_buffer();
    let i = 0;
    while (i < block.instructions.length()) {
        let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[i]))];
        if (instruction.opcode == WirOpcode.Return) {
            if (!x86_lower_return(program, instruction, ref output)) {
                return x86_lowering_error("unsupported return operand in the initial x86_64 lowering");
            }
        } else {
            return x86_lowering_error("unsupported instruction in the initial x86_64 lowering");
        }
        i += 1;
    }
    return X86LoweringResult(bytes=output.bytes, errors=[]);
}
