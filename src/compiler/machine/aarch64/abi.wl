// src/compiler/machine/aarch64/abi.wl
import A64Register from "model.wl"


func a64_argument_register(index: Int, floating: Bool) -> A64Register {
// AAPCS64 has independent banks for the first eight integer and FP arguments.
    if (index < 0 || index > 7) {
        return A64Register.None;
    }

    if floating {
        if (index == 0) { return A64Register.V0; }
        if (index == 1) { return A64Register.V1; }
        if (index == 2) { return A64Register.V2; }
        if (index == 3) { return A64Register.V3; }
        if (index == 4) { return A64Register.V4; }
        if (index == 5) { return A64Register.V5; }
        if (index == 6) { return A64Register.V6; }

        return A64Register.V7;
    }

    if (index == 0) { return A64Register.X0; }
    if (index == 1) { return A64Register.X1; }
    if (index == 2) { return A64Register.X2; }
    if (index == 3) { return A64Register.X3; }
    if (index == 4) { return A64Register.X4; }
    if (index == 5) { return A64Register.X5; }
    if (index == 6) { return A64Register.X6; }

    return A64Register.X7;
}

func a64_result_register(floating: Bool) -> A64Register {
    if floating { return A64Register.V0; }

    return A64Register.X0;
}

func a64_indirect_result_register() -> A64Register {
// Unlike an ordinary argument, an indirect result pointer is passed in X8.
    return A64Register.X8;
}

func a64_stack_argument_offset(index: Int) -> Int {
    if (index < 8) { return -1; }

    return (index - 8) * 8;
}

func a64_call_frame(argument_count: Int) -> Int {
    let bytes: Int = 0;

    if (argument_count > 8) {
        bytes = (argument_count - 8) * 8;
    }

    return (bytes + 15) & -16;
}
