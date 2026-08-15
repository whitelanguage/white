// compiler/backend/windows.wl
import "sys"
import * from "../context.wl"
import * from "../../frontend/diagnostics.wl"
import * from "../target.wl"

func emit_freestanding_memops(c: Compiler) -> Void {
// volatile loops stop LLVM from turning these definitions back into CRT calls
    let size_ty: String = get_size_llvm_type();
    c.output_file.write("define i8* @memcpy(i8* %dest, i8* %src, " + size_ty + " %count) noinline optnone {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  br label %copy.cond\n\n");
    c.output_file.write("copy.cond:\n");
    c.output_file.write("  %index = phi " + size_ty + " [ 0, %entry ], [ %next, %copy.body ]\n");
    c.output_file.write("  %done = icmp uge " + size_ty + " %index, %count\n");
    c.output_file.write("  br i1 %done, label %copy.end, label %copy.body\n\n");
    c.output_file.write("copy.body:\n");
    c.output_file.write("  %source = getelementptr i8, i8* %src, " + size_ty + " %index\n");
    c.output_file.write("  %byte = load volatile i8, i8* %source\n");
    c.output_file.write("  %target = getelementptr i8, i8* %dest, " + size_ty + " %index\n");
    c.output_file.write("  store volatile i8 %byte, i8* %target\n");
    c.output_file.write("  %next = add " + size_ty + " %index, 1\n");
    c.output_file.write("  br label %copy.cond\n\n");
    c.output_file.write("copy.end:\n");
    c.output_file.write("  ret i8* %dest\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define i8* @memmove(i8* %dest, i8* %src, " + size_ty + " %count) noinline optnone {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %same = icmp eq i8* %dest, %src\n");
    c.output_file.write("  %empty = icmp eq " + size_ty + " %count, 0\n");
    c.output_file.write("  %trivial = or i1 %same, %empty\n");
    c.output_file.write("  br i1 %trivial, label %move.end, label %move.direction\n\n");
    c.output_file.write("move.direction:\n");
    c.output_file.write("  %dest.addr = ptrtoint i8* %dest to " + size_ty + "\n");
    c.output_file.write("  %src.addr = ptrtoint i8* %src to " + size_ty + "\n");
    c.output_file.write("  %before = icmp ult " + size_ty + " %dest.addr, %src.addr\n");
    c.output_file.write("  %distance = sub " + size_ty + " %dest.addr, %src.addr\n");
    c.output_file.write("  %separate = icmp uge " + size_ty + " %distance, %count\n");
    c.output_file.write("  %forward = or i1 %before, %separate\n");
    c.output_file.write("  br i1 %forward, label %forward.cond, label %backward.cond\n\n");
    c.output_file.write("forward.cond:\n");
    c.output_file.write("  %forward.index = phi " + size_ty + " [ 0, %move.direction ], [ %forward.next, %forward.body ]\n");
    c.output_file.write("  %forward.done = icmp uge " + size_ty + " %forward.index, %count\n");
    c.output_file.write("  br i1 %forward.done, label %move.end, label %forward.body\n\n");
    c.output_file.write("forward.body:\n");
    c.output_file.write("  %forward.src = getelementptr i8, i8* %src, " + size_ty + " %forward.index\n");
    c.output_file.write("  %forward.byte = load volatile i8, i8* %forward.src\n");
    c.output_file.write("  %forward.dest = getelementptr i8, i8* %dest, " + size_ty + " %forward.index\n");
    c.output_file.write("  store volatile i8 %forward.byte, i8* %forward.dest\n");
    c.output_file.write("  %forward.next = add " + size_ty + " %forward.index, 1\n");
    c.output_file.write("  br label %forward.cond\n\n");
    c.output_file.write("backward.cond:\n");
    c.output_file.write("  %remaining = phi " + size_ty + " [ %count, %move.direction ], [ %backward.index, %backward.body ]\n");
    c.output_file.write("  %backward.done = icmp eq " + size_ty + " %remaining, 0\n");
    c.output_file.write("  br i1 %backward.done, label %move.end, label %backward.body\n\n");
    c.output_file.write("backward.body:\n");
    c.output_file.write("  %backward.index = sub " + size_ty + " %remaining, 1\n");
    c.output_file.write("  %backward.src = getelementptr i8, i8* %src, " + size_ty + " %backward.index\n");
    c.output_file.write("  %backward.byte = load volatile i8, i8* %backward.src\n");
    c.output_file.write("  %backward.dest = getelementptr i8, i8* %dest, " + size_ty + " %backward.index\n");
    c.output_file.write("  store volatile i8 %backward.byte, i8* %backward.dest\n");
    c.output_file.write("  br label %backward.cond\n\n");
    c.output_file.write("move.end:\n");
    c.output_file.write("  ret i8* %dest\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define i8* @memset(i8* %dest, i32 %value, " + size_ty + " %count) noinline optnone {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %byte = trunc i32 %value to i8\n");
    c.output_file.write("  br label %set.cond\n\n");
    c.output_file.write("set.cond:\n");
    c.output_file.write("  %index = phi " + size_ty + " [ 0, %entry ], [ %next, %set.body ]\n");
    c.output_file.write("  %done = icmp uge " + size_ty + " %index, %count\n");
    c.output_file.write("  br i1 %done, label %set.end, label %set.body\n\n");
    c.output_file.write("set.body:\n");
    c.output_file.write("  %target = getelementptr i8, i8* %dest, " + size_ty + " %index\n");
    c.output_file.write("  store volatile i8 %byte, i8* %target\n");
    c.output_file.write("  %next = add " + size_ty + " %index, 1\n");
    c.output_file.write("  br label %set.cond\n\n");
    c.output_file.write("set.end:\n");
    c.output_file.write("  ret i8* %dest\n");
    c.output_file.write("}\n\n");
}

func emit_windows_x86_division_builtins(c: Compiler) -> Void {
// llvm lowers 64-bit division to these msvc helper symbols on x86

    /*
    the wide case uses restoring binary division:

        quotient := 0
        remainder := 0
        for bit from 63 down to 0:
            remainder := (remainder << 1) | ((dividend >> bit) & 1)
            if remainder >= divisor:
                remainder := remainder - divisor
                quotient := quotient | (1 << bit)
    */
    c.output_file.write("define internal void @__wl_udivrem64(i64 %dividend, i64 %divisor, i64* %quotient.out, i64* %remainder.out) noinline {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %zero = icmp eq i64 %divisor, 0\n");
    c.output_file.write("  br i1 %zero, label %divide.zero, label %check.range\n\n");
    c.output_file.write("divide.zero:\n");
    c.output_file.write("  call void @llvm.trap()\n");
    c.output_file.write("  unreachable\n\n");
    c.output_file.write("check.range:\n");
    c.output_file.write("  %less = icmp ult i64 %dividend, %divisor\n");
    c.output_file.write("  br i1 %less, label %less.than.divisor, label %check.narrow\n\n");
    c.output_file.write("less.than.divisor:\n");
    c.output_file.write("  store i64 0, i64* %quotient.out\n");
    c.output_file.write("  store i64 %dividend, i64* %remainder.out\n");
    c.output_file.write("  ret void\n\n");
    c.output_file.write("check.narrow:\n");
    c.output_file.write("  %dividend.high = lshr i64 %dividend, 32\n");
    c.output_file.write("  %divisor.high = lshr i64 %divisor, 32\n");
    c.output_file.write("  %high.bits = or i64 %dividend.high, %divisor.high\n");
    c.output_file.write("  %narrow = icmp eq i64 %high.bits, 0\n");
    c.output_file.write("  br i1 %narrow, label %divide.narrow, label %loop\n\n");
    c.output_file.write("divide.narrow:\n");
    c.output_file.write("  %dividend.low = trunc i64 %dividend to i32\n");
    c.output_file.write("  %divisor.low = trunc i64 %divisor to i32\n");
    c.output_file.write("  %quotient.low = udiv i32 %dividend.low, %divisor.low\n");
    c.output_file.write("  %remainder.low = urem i32 %dividend.low, %divisor.low\n");
    c.output_file.write("  %quotient.wide = zext i32 %quotient.low to i64\n");
    c.output_file.write("  %remainder.wide = zext i32 %remainder.low to i64\n");
    c.output_file.write("  store i64 %quotient.wide, i64* %quotient.out\n");
    c.output_file.write("  store i64 %remainder.wide, i64* %remainder.out\n");
    c.output_file.write("  ret void\n\n");
    c.output_file.write("loop:\n");
    c.output_file.write("  %index = phi i32 [ 64, %check.narrow ], [ %next.index, %body ]\n");
    c.output_file.write("  %quotient = phi i64 [ 0, %check.narrow ], [ %next.quotient, %body ]\n");
    c.output_file.write("  %remainder = phi i64 [ 0, %check.narrow ], [ %next.remainder, %body ]\n");
    c.output_file.write("  %done = icmp eq i32 %index, 0\n");
    c.output_file.write("  br i1 %done, label %finish, label %body\n\n");
    c.output_file.write("body:\n");
    c.output_file.write("  %next.index = sub i32 %index, 1\n");
    c.output_file.write("  %shift = zext i32 %next.index to i64\n");
    c.output_file.write("  %shifted.dividend = lshr i64 %dividend, %shift\n");
    c.output_file.write("  %bit = and i64 %shifted.dividend, 1\n");
    c.output_file.write("  %shifted.remainder = shl i64 %remainder, 1\n");
    c.output_file.write("  %candidate = or i64 %shifted.remainder, %bit\n");
    c.output_file.write("  %fits = icmp uge i64 %candidate, %divisor\n");
    c.output_file.write("  %reduced = sub i64 %candidate, %divisor\n");
    c.output_file.write("  %next.remainder = select i1 %fits, i64 %reduced, i64 %candidate\n");
    c.output_file.write("  %quotient.bit = shl i64 1, %shift\n");
    c.output_file.write("  %with.bit = or i64 %quotient, %quotient.bit\n");
    c.output_file.write("  %next.quotient = select i1 %fits, i64 %with.bit, i64 %quotient\n");
    c.output_file.write("  br label %loop\n\n");
    c.output_file.write("finish:\n");
    c.output_file.write("  store i64 %quotient, i64* %quotient.out\n");
    c.output_file.write("  store i64 %remainder, i64* %remainder.out\n");
    c.output_file.write("  ret void\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define x86_stdcallcc i64 @\"\\01__aulldiv\"(i64 %dividend, i64 %divisor) noinline {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %quotient = alloca i64\n");
    c.output_file.write("  %remainder = alloca i64\n");
    c.output_file.write("  call void @__wl_udivrem64(i64 %dividend, i64 %divisor, i64* %quotient, i64* %remainder)\n");
    c.output_file.write("  %result = load i64, i64* %quotient\n");
    c.output_file.write("  ret i64 %result\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define x86_stdcallcc i64 @\"\\01__aullrem\"(i64 %dividend, i64 %divisor) noinline {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %quotient = alloca i64\n");
    c.output_file.write("  %remainder = alloca i64\n");
    c.output_file.write("  call void @__wl_udivrem64(i64 %dividend, i64 %divisor, i64* %quotient, i64* %remainder)\n");
    c.output_file.write("  %result = load i64, i64* %remainder\n");
    c.output_file.write("  ret i64 %result\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define x86_stdcallcc i64 @\"\\01__alldiv\"(i64 %dividend, i64 %divisor) noinline {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %dividend.negative = icmp slt i64 %dividend, 0\n");
    c.output_file.write("  %divisor.negative = icmp slt i64 %divisor, 0\n");
    c.output_file.write("  %negative.dividend = sub i64 0, %dividend\n");
    c.output_file.write("  %negative.divisor = sub i64 0, %divisor\n");
    c.output_file.write("  %magnitude.dividend = select i1 %dividend.negative, i64 %negative.dividend, i64 %dividend\n");
    c.output_file.write("  %magnitude.divisor = select i1 %divisor.negative, i64 %negative.divisor, i64 %divisor\n");
    c.output_file.write("  %quotient = alloca i64\n");
    c.output_file.write("  %remainder = alloca i64\n");
    c.output_file.write("  call void @__wl_udivrem64(i64 %magnitude.dividend, i64 %magnitude.divisor, i64* %quotient, i64* %remainder)\n");
    c.output_file.write("  %magnitude = load i64, i64* %quotient\n");
    c.output_file.write("  %negative = xor i1 %dividend.negative, %divisor.negative\n");
    c.output_file.write("  %negative.result = sub i64 0, %magnitude\n");
    c.output_file.write("  %result = select i1 %negative, i64 %negative.result, i64 %magnitude\n");
    c.output_file.write("  ret i64 %result\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define x86_stdcallcc i64 @\"\\01__allrem\"(i64 %dividend, i64 %divisor) noinline {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %dividend.negative = icmp slt i64 %dividend, 0\n");
    c.output_file.write("  %divisor.negative = icmp slt i64 %divisor, 0\n");
    c.output_file.write("  %negative.dividend = sub i64 0, %dividend\n");
    c.output_file.write("  %negative.divisor = sub i64 0, %divisor\n");
    c.output_file.write("  %magnitude.dividend = select i1 %dividend.negative, i64 %negative.dividend, i64 %dividend\n");
    c.output_file.write("  %magnitude.divisor = select i1 %divisor.negative, i64 %negative.divisor, i64 %divisor\n");
    c.output_file.write("  %quotient = alloca i64\n");
    c.output_file.write("  %remainder = alloca i64\n");
    c.output_file.write("  call void @__wl_udivrem64(i64 %magnitude.dividend, i64 %magnitude.divisor, i64* %quotient, i64* %remainder)\n");
    c.output_file.write("  %magnitude = load i64, i64* %remainder\n");
    c.output_file.write("  %negative.result = sub i64 0, %magnitude\n");
    c.output_file.write("  %result = select i1 %dividend.negative, i64 %negative.result, i64 %magnitude\n");
    c.output_file.write("  ret i64 %result\n");
    c.output_file.write("}\n\n");
}

func emit_windows_x86_stack_probe(c: Compiler) -> Void {
    // x86 __chkstk probes the guard pages and returns on the allocated stack
    c.output_file.write("module asm \".text\"\n");
    c.output_file.write("module asm \".p2align 4, 0x90\"\n");
    c.output_file.write("module asm \".globl __chkstk\"\n");
    c.output_file.write("module asm \"__chkstk:\"\n");
    c.output_file.write("module asm \"pushl %ecx\"\n");
    c.output_file.write("module asm \"leal 8(%esp), %ecx\"\n");
    c.output_file.write("module asm \"cmpl $0x1000, %eax\"\n");
    c.output_file.write("module asm \"jb 2f\"\n");
    c.output_file.write("module asm \"1:\"\n");
    c.output_file.write("module asm \"subl $0x1000, %ecx\"\n");
    c.output_file.write("module asm \"testb $0, (%ecx)\"\n");
    c.output_file.write("module asm \"subl $0x1000, %eax\"\n");
    c.output_file.write("module asm \"cmpl $0x1000, %eax\"\n");
    c.output_file.write("module asm \"ja 1b\"\n");
    c.output_file.write("module asm \"2:\"\n");
    c.output_file.write("module asm \"subl %eax, %ecx\"\n");
    c.output_file.write("module asm \"testb $0, (%ecx)\"\n");
    c.output_file.write("module asm \"movl %esp, %eax\"\n");
    c.output_file.write("module asm \"movl %ecx, %esp\"\n");
    c.output_file.write("module asm \"movl (%eax), %ecx\"\n");
    c.output_file.write("module asm \"movl 4(%eax), %eax\"\n");
    c.output_file.write("module asm \"pushl %eax\"\n");
    c.output_file.write("module asm \"retl\"\n\n");
}

func emit_windows_x64_stack_probe(c: Compiler) -> Void {
    // x64 callers adjust rsp after the probe returns
    c.output_file.write("module asm \".text\"\n");
    c.output_file.write("module asm \".p2align 4, 0x90\"\n");
    c.output_file.write("module asm \".globl __chkstk\"\n");
    c.output_file.write("module asm \".globl ___chkstk_ms\"\n");
    c.output_file.write("module asm \"__chkstk:\"\n");
    c.output_file.write("module asm \"___chkstk_ms:\"\n");
    c.output_file.write("module asm \"pushq %rcx\"\n");
    c.output_file.write("module asm \"pushq %rax\"\n");
    c.output_file.write("module asm \"cmpq $0x1000, %rax\"\n");
    c.output_file.write("module asm \"leaq 24(%rsp), %rcx\"\n");
    c.output_file.write("module asm \"jb 2f\"\n");
    c.output_file.write("module asm \"1:\"\n");
    c.output_file.write("module asm \"subq $0x1000, %rcx\"\n");
    c.output_file.write("module asm \"testb $0, (%rcx)\"\n");
    c.output_file.write("module asm \"subq $0x1000, %rax\"\n");
    c.output_file.write("module asm \"cmpq $0x1000, %rax\"\n");
    c.output_file.write("module asm \"ja 1b\"\n");
    c.output_file.write("module asm \"2:\"\n");
    c.output_file.write("module asm \"subq %rax, %rcx\"\n");
    c.output_file.write("module asm \"testb $0, (%rcx)\"\n");
    c.output_file.write("module asm \"popq %rax\"\n");
    c.output_file.write("module asm \"popq %rcx\"\n");
    c.output_file.write("module asm \"retq\"\n\n");
}

func emit_windows_stack_probe(c: Compiler) -> Void {
    // keep target assembly private to the Windows backend until structured asm is available
    if (get_target_arch() == sys.Arch.X86) { emit_windows_x86_stack_probe(c); }
    else if (get_target_arch() == sys.Arch.X86_64) { emit_windows_x64_stack_probe(c); }
}

func emit_windows_abi(c: Compiler) -> Void {
    if (get_target_os() != sys.Os.Windows) { return; }
    c.output_file.write("@_fltused = global i32 39029\n\n");
    c.output_file.write("define void @__main() {\nentry:\n  ret void\n}\n\n");
    emit_freestanding_memops(c);
    if (get_target_arch() == sys.Arch.X86) { emit_windows_x86_division_builtins(c); }
    emit_windows_stack_probe(c);
}

func emit_windows_entrypoint(c: Compiler) -> Void {
    if (get_target_os() != sys.Os.Windows) { return; }
    if (c.is_shared) {
        let callconv: String = "";
        if (get_target_arch() == sys.Arch.X86) { callconv = "x86_stdcallcc "; }
        c.output_file.write("define " + callconv + "i32 @DllMainCRTStartup(i8* %instance, i32 %reason, i8* %reserved) {\n");
        c.output_file.write("entry:\n");
        c.output_file.write("  ret i32 1\n");
        c.output_file.write("}\n\n");
        return;
    }

    let main_info: FuncInfo = c.func_table.lookup("main");
    let exit_key: String = c.compiler_link.lookup("process_exit");
    let exit_info: FuncInfo = c.func_table.lookup(exit_key);
    if (main_info is null || exit_info is null) {
        throw_internal_compiler_error(null, "Missing compiler runtime hooks required by the native entry point.");
        return;
    }

    let argc: Int = 0;
    if (main_info.arg_types is !null) { argc = main_info.arg_types.length(); }
    c.output_file.write("define void @mainCRTStartup() {\n");
    c.output_file.write("entry:\n");
    if (argc == 0) {
        c.output_file.write("  %status = call i32 @main()\n");
    } else {
        let args_key: String = c.compiler_link.lookup("startup_args");
        let free_key: String = c.compiler_link.lookup("startup_args_free");
        let args_info: FuncInfo = c.func_table.lookup(args_key);
        let free_info: FuncInfo = c.func_table.lookup(free_key);
        if (args_info is null || free_info is null) {
            throw_internal_compiler_error(null, "Missing compiler runtime hooks required by the Windows entry point.");
            return;
        }
        c.output_file.write("  %argc.addr = alloca i32\n");
        c.output_file.write("  store i32 0, i32* %argc.addr\n");
        c.output_file.write("  %argv.raw = call i8* @" + args_info.name + "(i32* %argc.addr)\n");
        c.output_file.write("  %argv.missing = icmp eq i8* %argv.raw, null\n");
        c.output_file.write("  br i1 %argv.missing, label %startup.failed, label %startup.ready\n\n");
        c.output_file.write("startup.failed:\n");
        c.output_file.write("  call void @" + exit_info.name + "(i32 127)\n");
        c.output_file.write("  unreachable\n\n");
        c.output_file.write("startup.ready:\n");
        c.output_file.write("  %argc = load i32, i32* %argc.addr\n");
        c.output_file.write("  %argv = bitcast i8* %argv.raw to %struct.$String**\n");
        c.output_file.write("  %status = call i32 @main(i32 %argc, %struct.$String** %argv)\n");
        c.output_file.write("  call void @" + free_info.name + "(i32 %argc, i8* %argv.raw)\n");
    }
    c.output_file.write("  call void @" + exit_info.name + "(i32 %status)\n");
    c.output_file.write("  unreachable\n");
    c.output_file.write("}\n\n");
}

