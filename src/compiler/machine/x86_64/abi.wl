// compiler/machine/x86_64/abi.wl
import * from "model.wl"


struct X86Win64ABI(
    pointer_bits: Int,
    stack_alignment: Int,
    shadow_space: Int,
    integer_arguments: Vector(X86Register),
    floating_arguments: Vector(X86Register),
    callee_saved: Vector(X86Register)
)


func x86_win64_abi() -> X86Win64ABI {
    // keep this table in one place. Lowering uses it for both incoming values and
    // calls, and a disagreement there usually survives until link or runtime.
    //
    // Win64 has four argument positions, not two independent banks of four. The
    // type of an argument decides whether its position names RCX..R9 or XMM0..3.
    return X86Win64ABI(
        pointer_bits=64,
        stack_alignment=16,
        shadow_space=32,
        integer_arguments=[X86Register.RCX, X86Register.RDX, X86Register.R8, X86Register.R9],
        floating_arguments=[X86Register.XMM0, X86Register.XMM1, X86Register.XMM2, X86Register.XMM3],
        callee_saved=[
            X86Register.RBX, X86Register.RBP, X86Register.RDI, X86Register.RSI, X86Register.RSP,
            X86Register.R12, X86Register.R13, X86Register.R14, X86Register.R15,
            X86Register.XMM6, X86Register.XMM7, X86Register.XMM8, X86Register.XMM9,
            X86Register.XMM10, X86Register.XMM11, X86Register.XMM12, X86Register.XMM13,
            X86Register.XMM14, X86Register.XMM15
        ]
    );
}

func x86_win64_argument_register(index: Int, floating: Bool) -> X86Register {
    let abi: X86Win64ABI = x86_win64_abi();
    if (index < 0) {
        return X86Register.None;
    }

    if floating {
        if (index >= abi.floating_arguments.length()) {
            return X86Register.None;
        }

        return abi.floating_arguments[index];
    }
    if (index >= abi.integer_arguments.length()) {
        return X86Register.None;
    }

    return abi.integer_arguments[index];
}

func x86_win64_stack_arg_offset(index: Int) -> Int {
    if (index < 4) {
        return -1;
    }

    return 32 + (index - 4) * 8;
}

func x86_win64_stack_param_offset(index: Int) -> Int {
    if (index < 4) {
        return -1;
    }

    return 48 + (index - 4) * 8;
}

func x86_win64_call_frame(argument_count: Int) -> Int {
    let size: Int = 32;
    if (argument_count > 4) { size += (argument_count - 4) * 8; }
    return (size + 15) & -16;
}

func x86_win64_is_callee_saved(register: X86Register) -> Bool {
    let abi: X86Win64ABI = x86_win64_abi();

    let i: Int = 0;
    while (i < abi.callee_saved.length()) {
        if (abi.callee_saved[i] == register) {
            return true;
        }
        i++;
    }

    return false;
}
