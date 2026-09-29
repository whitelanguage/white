// Test: X86_64_REGISTER_ALLOCATOR
// File: tests/machine/x86_64/test_allocator.wl
// Focus: Keep register selection linear and evict the value used farthest ahead.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/x86_64/model.wl"
import * from "../../../src/compiler/machine/x86_64/allocator.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(ref program, "allocate", [], int_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let first: WirValueID = wir_const_int(ref program, int_type, UInt128(1U));
    let second: WirValueID = wir_const_int(ref program, int_type, UInt128(2U));
    let third: WirValueID = wir_const_int(ref program, int_type, UInt128(3U));
    let near: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, int_type, first, second, "near", no_wir_location());
    let far: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, int_type, third, second, "far", no_wir_location());
    wir_binary(ref program, entry, WirOpcode.Add, int_type, near, third, "consume_near", no_wir_location());
    wir_return(ref program, entry, far, no_wir_location());

    let order: Vector(WirBlockID) = [entry];
    let plan: X86RegisterPlan = x86_new_register_plan(ref program, order);
    let free: X86RegisterChoice = x86_choose_register(ref program, plan, 0);
    if (free.register != X86Register.RAX || free.evicted != NO_WIR_VALUE) {
        print("FAIL: allocator did not select the first free register");
        return 1;
    }

    x86_bind_register(plan, X86Register.RAX, near);
    x86_bind_register(plan, X86Register.R10, far);
    x86_bind_register(plan, X86Register.R11, third);
    let victim: X86RegisterChoice = x86_choose_register(ref program, plan, 0);
    if (victim.register != X86Register.R10 || victim.evicted != far) {
        print("FAIL: allocator did not evict the farthest next use");
        return 1;
    }

    x86_clear_register(plan, X86Register.R11);
    let reused: X86RegisterChoice = x86_choose_register(ref program, plan, 1);
    if (reused.register != X86Register.R11 || reused.evicted != NO_WIR_VALUE) {
        print("FAIL: allocator did not reuse a free register");
        return 1;
    }

    if (x86_pending_use(plan.uses, near, 2) != 2 || x86_next_use(plan.uses, near, 2) != X86_NO_NEXT_USE) {
        print("FAIL: allocator treated an unread current operand as dead");
        return 1;
    }
    x86_consume_uses(plan.uses, near, 2);
    if (x86_pending_use(plan.uses, near, 2) != X86_NO_NEXT_USE) {
        print("FAIL: allocator kept a consumed operand live");
        return 1;
    }

    print("PASS: x86_64 register allocator");
    return 0;
}
