// src/compiler/backend/windows.wl
import "sys"
import * from "../context.wl"
import * from "../../frontend/diagnostics.wl"
import * from "../target.wl"


func emit_freestanding_memops(ref c: Compiler) -> Void {
// volatile loops stop LLVM from turning these definitions back into CRT calls
    let size_ty: String = get_size_llvm_type();

    write_ir(ref c, "define i8* @memcpy(i8* %dest, i8* %src, " + size_ty + " %count) noinline optnone {\n");
    write_ir(ref c, "entry:\n");
    write_ir(ref c, "  br label %copy.cond\n\n");
    write_ir(ref c, "copy.cond:\n");
    write_ir(ref c, "  %index = phi " + size_ty + " [ 0, %entry ], [ %next, %copy.body ]\n");
    write_ir(ref c, "  %done = icmp uge " + size_ty + " %index, %count\n");
    write_ir(ref c, "  br i1 %done, label %copy.end, label %copy.body\n\n");
    write_ir(ref c, "copy.body:\n");
    write_ir(ref c, "  %source = getelementptr i8, i8* %src, " + size_ty + " %index\n");
    write_ir(ref c, "  %byte = load volatile i8, i8* %source\n");
    write_ir(ref c, "  %target = getelementptr i8, i8* %dest, " + size_ty + " %index\n");
    write_ir(ref c, "  store volatile i8 %byte, i8* %target\n");
    write_ir(ref c, "  %next = add " + size_ty + " %index, 1\n");
    write_ir(ref c, "  br label %copy.cond\n\n");
    write_ir(ref c, "copy.end:\n");
    write_ir(ref c, "  ret i8* %dest\n");
    write_ir(ref c, "}\n\n");

    write_ir(ref c, "define i8* @memmove(i8* %dest, i8* %src, " + size_ty + " %count) noinline optnone {\n");
    write_ir(ref c, "entry:\n");
    write_ir(ref c, "  %same = icmp eq i8* %dest, %src\n");
    write_ir(ref c, "  %empty = icmp eq " + size_ty + " %count, 0\n");
    write_ir(ref c, "  %trivial = or i1 %same, %empty\n");
    write_ir(ref c, "  br i1 %trivial, label %move.end, label %move.direction\n\n");
    write_ir(ref c, "move.direction:\n");
    write_ir(ref c, "  %dest.addr = ptrtoint i8* %dest to " + size_ty + "\n");
    write_ir(ref c, "  %src.addr = ptrtoint i8* %src to " + size_ty + "\n");
    write_ir(ref c, "  %before = icmp ult " + size_ty + " %dest.addr, %src.addr\n");
    write_ir(ref c, "  %distance = sub " + size_ty + " %dest.addr, %src.addr\n");
    write_ir(ref c, "  %separate = icmp uge " + size_ty + " %distance, %count\n");
    write_ir(ref c, "  %forward = or i1 %before, %separate\n");
    write_ir(ref c, "  br i1 %forward, label %forward.cond, label %backward.cond\n\n");
    write_ir(ref c, "forward.cond:\n");
    write_ir(ref c, "  %forward.index = phi " + size_ty + " [ 0, %move.direction ], [ %forward.next, %forward.body ]\n");
    write_ir(ref c, "  %forward.done = icmp uge " + size_ty + " %forward.index, %count\n");
    write_ir(ref c, "  br i1 %forward.done, label %move.end, label %forward.body\n\n");
    write_ir(ref c, "forward.body:\n");
    write_ir(ref c, "  %forward.src = getelementptr i8, i8* %src, " + size_ty + " %forward.index\n");
    write_ir(ref c, "  %forward.byte = load volatile i8, i8* %forward.src\n");
    write_ir(ref c, "  %forward.dest = getelementptr i8, i8* %dest, " + size_ty + " %forward.index\n");
    write_ir(ref c, "  store volatile i8 %forward.byte, i8* %forward.dest\n");
    write_ir(ref c, "  %forward.next = add " + size_ty + " %forward.index, 1\n");
    write_ir(ref c, "  br label %forward.cond\n\n");
    write_ir(ref c, "backward.cond:\n");
    write_ir(ref c, "  %remaining = phi " + size_ty + " [ %count, %move.direction ], [ %backward.index, %backward.body ]\n");
    write_ir(ref c, "  %backward.done = icmp eq " + size_ty + " %remaining, 0\n");
    write_ir(ref c, "  br i1 %backward.done, label %move.end, label %backward.body\n\n");
    write_ir(ref c, "backward.body:\n");
    write_ir(ref c, "  %backward.index = sub " + size_ty + " %remaining, 1\n");
    write_ir(ref c, "  %backward.src = getelementptr i8, i8* %src, " + size_ty + " %backward.index\n");
    write_ir(ref c, "  %backward.byte = load volatile i8, i8* %backward.src\n");
    write_ir(ref c, "  %backward.dest = getelementptr i8, i8* %dest, " + size_ty + " %backward.index\n");
    write_ir(ref c, "  store volatile i8 %backward.byte, i8* %backward.dest\n");
    write_ir(ref c, "  br label %backward.cond\n\n");
    write_ir(ref c, "move.end:\n");
    write_ir(ref c, "  ret i8* %dest\n");
    write_ir(ref c, "}\n\n");

    write_ir(ref c, "define i8* @memset(i8* %dest, i32 %value, " + size_ty + " %count) noinline optnone {\n");
    write_ir(ref c, "entry:\n");
    write_ir(ref c, "  %byte = trunc i32 %value to i8\n");
    write_ir(ref c, "  br label %set.cond\n\n");
    write_ir(ref c, "set.cond:\n");
    write_ir(ref c, "  %index = phi " + size_ty + " [ 0, %entry ], [ %next, %set.body ]\n");
    write_ir(ref c, "  %done = icmp uge " + size_ty + " %index, %count\n");
    write_ir(ref c, "  br i1 %done, label %set.end, label %set.body\n\n");
    write_ir(ref c, "set.body:\n");
    write_ir(ref c, "  %target = getelementptr i8, i8* %dest, " + size_ty + " %index\n");
    write_ir(ref c, "  store volatile i8 %byte, i8* %target\n");
    write_ir(ref c, "  %next = add " + size_ty + " %index, 1\n");
    write_ir(ref c, "  br label %set.cond\n\n");
    write_ir(ref c, "set.end:\n");
    write_ir(ref c, "  ret i8* %dest\n");
    write_ir(ref c, "}\n\n");
}

func emit_windows_x86_division_builtins(ref c: Compiler) -> Void {
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

    write_ir(ref c, "define internal void @__wl_udivrem64(i64 %dividend, i64 %divisor, i64* %quotient.out, i64* %remainder.out) noinline {\n");
    write_ir(ref c, "entry:\n");
    write_ir(ref c, "  %zero = icmp eq i64 %divisor, 0\n");
    write_ir(ref c, "  br i1 %zero, label %divide.zero, label %check.range\n\n");
    write_ir(ref c, "divide.zero:\n");
    write_ir(ref c, "  call void @llvm.trap()\n");
    write_ir(ref c, "  unreachable\n\n");
    write_ir(ref c, "check.range:\n");
    write_ir(ref c, "  %less = icmp ult i64 %dividend, %divisor\n");
    write_ir(ref c, "  br i1 %less, label %less.than.divisor, label %check.narrow\n\n");
    write_ir(ref c, "less.than.divisor:\n");
    write_ir(ref c, "  store i64 0, i64* %quotient.out\n");
    write_ir(ref c, "  store i64 %dividend, i64* %remainder.out\n");
    write_ir(ref c, "  ret void\n\n");
    write_ir(ref c, "check.narrow:\n");
    write_ir(ref c, "  %dividend.high = lshr i64 %dividend, 32\n");
    write_ir(ref c, "  %divisor.high = lshr i64 %divisor, 32\n");
    write_ir(ref c, "  %high.bits = or i64 %dividend.high, %divisor.high\n");
    write_ir(ref c, "  %narrow = icmp eq i64 %high.bits, 0\n");
    write_ir(ref c, "  br i1 %narrow, label %divide.narrow, label %loop\n\n");
    write_ir(ref c, "divide.narrow:\n");
    write_ir(ref c, "  %dividend.low = trunc i64 %dividend to i32\n");
    write_ir(ref c, "  %divisor.low = trunc i64 %divisor to i32\n");
    write_ir(ref c, "  %quotient.low = udiv i32 %dividend.low, %divisor.low\n");
    write_ir(ref c, "  %remainder.low = urem i32 %dividend.low, %divisor.low\n");
    write_ir(ref c, "  %quotient.wide = zext i32 %quotient.low to i64\n");
    write_ir(ref c, "  %remainder.wide = zext i32 %remainder.low to i64\n");
    write_ir(ref c, "  store i64 %quotient.wide, i64* %quotient.out\n");
    write_ir(ref c, "  store i64 %remainder.wide, i64* %remainder.out\n");
    write_ir(ref c, "  ret void\n\n");
    write_ir(ref c, "loop:\n");
    write_ir(ref c, "  %index = phi i32 [ 64, %check.narrow ], [ %next.index, %body ]\n");
    write_ir(ref c, "  %quotient = phi i64 [ 0, %check.narrow ], [ %next.quotient, %body ]\n");
    write_ir(ref c, "  %remainder = phi i64 [ 0, %check.narrow ], [ %next.remainder, %body ]\n");
    write_ir(ref c, "  %done = icmp eq i32 %index, 0\n");
    write_ir(ref c, "  br i1 %done, label %finish, label %body\n\n");
    write_ir(ref c, "body:\n");
    write_ir(ref c, "  %next.index = sub i32 %index, 1\n");
    write_ir(ref c, "  %shift = zext i32 %next.index to i64\n");
    write_ir(ref c, "  %shifted.dividend = lshr i64 %dividend, %shift\n");
    write_ir(ref c, "  %bit = and i64 %shifted.dividend, 1\n");
    write_ir(ref c, "  %shifted.remainder = shl i64 %remainder, 1\n");
    write_ir(ref c, "  %candidate = or i64 %shifted.remainder, %bit\n");
    write_ir(ref c, "  %fits = icmp uge i64 %candidate, %divisor\n");
    write_ir(ref c, "  %reduced = sub i64 %candidate, %divisor\n");
    write_ir(ref c, "  %next.remainder = select i1 %fits, i64 %reduced, i64 %candidate\n");
    write_ir(ref c, "  %quotient.bit = shl i64 1, %shift\n");
    write_ir(ref c, "  %with.bit = or i64 %quotient, %quotient.bit\n");
    write_ir(ref c, "  %next.quotient = select i1 %fits, i64 %with.bit, i64 %quotient\n");
    write_ir(ref c, "  br label %loop\n\n");
    write_ir(ref c, "finish:\n");
    write_ir(ref c, "  store i64 %quotient, i64* %quotient.out\n");
    write_ir(ref c, "  store i64 %remainder, i64* %remainder.out\n");
    write_ir(ref c, "  ret void\n");
    write_ir(ref c, "}\n\n");

    write_ir(ref c, "define x86_stdcallcc i64 @\"\\01__aulldiv\"(i64 %dividend, i64 %divisor) noinline {\n");
    write_ir(ref c, "entry:\n");
    write_ir(ref c, "  %quotient = alloca i64\n");
    write_ir(ref c, "  %remainder = alloca i64\n");
    write_ir(ref c, "  call void @__wl_udivrem64(i64 %dividend, i64 %divisor, i64* %quotient, i64* %remainder)\n");
    write_ir(ref c, "  %result = load i64, i64* %quotient\n");
    write_ir(ref c, "  ret i64 %result\n");
    write_ir(ref c, "}\n\n");

    write_ir(ref c, "define x86_stdcallcc i64 @\"\\01__aullrem\"(i64 %dividend, i64 %divisor) noinline {\n");
    write_ir(ref c, "entry:\n");
    write_ir(ref c, "  %quotient = alloca i64\n");
    write_ir(ref c, "  %remainder = alloca i64\n");
    write_ir(ref c, "  call void @__wl_udivrem64(i64 %dividend, i64 %divisor, i64* %quotient, i64* %remainder)\n");
    write_ir(ref c, "  %result = load i64, i64* %remainder\n");
    write_ir(ref c, "  ret i64 %result\n");
    write_ir(ref c, "}\n\n");

    write_ir(ref c, "define x86_stdcallcc i64 @\"\\01__alldiv\"(i64 %dividend, i64 %divisor) noinline {\n");
    write_ir(ref c, "entry:\n");
    write_ir(ref c, "  %dividend.negative = icmp slt i64 %dividend, 0\n");
    write_ir(ref c, "  %divisor.negative = icmp slt i64 %divisor, 0\n");
    write_ir(ref c, "  %negative.dividend = sub i64 0, %dividend\n");
    write_ir(ref c, "  %negative.divisor = sub i64 0, %divisor\n");
    write_ir(ref c, "  %magnitude.dividend = select i1 %dividend.negative, i64 %negative.dividend, i64 %dividend\n");
    write_ir(ref c, "  %magnitude.divisor = select i1 %divisor.negative, i64 %negative.divisor, i64 %divisor\n");
    write_ir(ref c, "  %quotient = alloca i64\n");
    write_ir(ref c, "  %remainder = alloca i64\n");
    write_ir(ref c, "  call void @__wl_udivrem64(i64 %magnitude.dividend, i64 %magnitude.divisor, i64* %quotient, i64* %remainder)\n");
    write_ir(ref c, "  %magnitude = load i64, i64* %quotient\n");
    write_ir(ref c, "  %negative = xor i1 %dividend.negative, %divisor.negative\n");
    write_ir(ref c, "  %negative.result = sub i64 0, %magnitude\n");
    write_ir(ref c, "  %result = select i1 %negative, i64 %negative.result, i64 %magnitude\n");
    write_ir(ref c, "  ret i64 %result\n");
    write_ir(ref c, "}\n\n");

    write_ir(ref c, "define x86_stdcallcc i64 @\"\\01__allrem\"(i64 %dividend, i64 %divisor) noinline {\n");
    write_ir(ref c, "entry:\n");
    write_ir(ref c, "  %dividend.negative = icmp slt i64 %dividend, 0\n");
    write_ir(ref c, "  %divisor.negative = icmp slt i64 %divisor, 0\n");
    write_ir(ref c, "  %negative.dividend = sub i64 0, %dividend\n");
    write_ir(ref c, "  %negative.divisor = sub i64 0, %divisor\n");
    write_ir(ref c, "  %magnitude.dividend = select i1 %dividend.negative, i64 %negative.dividend, i64 %dividend\n");
    write_ir(ref c, "  %magnitude.divisor = select i1 %divisor.negative, i64 %negative.divisor, i64 %divisor\n");
    write_ir(ref c, "  %quotient = alloca i64\n");
    write_ir(ref c, "  %remainder = alloca i64\n");
    write_ir(ref c, "  call void @__wl_udivrem64(i64 %magnitude.dividend, i64 %magnitude.divisor, i64* %quotient, i64* %remainder)\n");
    write_ir(ref c, "  %magnitude = load i64, i64* %remainder\n");
    write_ir(ref c, "  %negative.result = sub i64 0, %magnitude\n");
    write_ir(ref c, "  %result = select i1 %dividend.negative, i64 %negative.result, i64 %magnitude\n");
    write_ir(ref c, "  ret i64 %result\n");
    write_ir(ref c, "}\n\n");
}

func emit_windows_x86_stack_probe(ref c: Compiler) -> Void {
// x86 __chkstk probes the guard pages and returns on the allocated stack

    write_ir(ref c, "module asm \".text\"\n");
    write_ir(ref c, "module asm \".p2align 4, 0x90\"\n");
    write_ir(ref c, "module asm \".globl __chkstk\"\n");
    write_ir(ref c, "module asm \"__chkstk:\"\n");
    write_ir(ref c, "module asm \"pushl %ecx\"\n");
    write_ir(ref c, "module asm \"leal 8(%esp), %ecx\"\n");
    write_ir(ref c, "module asm \"cmpl $0x1000, %eax\"\n");
    write_ir(ref c, "module asm \"jb 2f\"\n");
    write_ir(ref c, "module asm \"1:\"\n");
    write_ir(ref c, "module asm \"subl $0x1000, %ecx\"\n");
    write_ir(ref c, "module asm \"testb $0, (%ecx)\"\n");
    write_ir(ref c, "module asm \"subl $0x1000, %eax\"\n");
    write_ir(ref c, "module asm \"cmpl $0x1000, %eax\"\n");
    write_ir(ref c, "module asm \"ja 1b\"\n");
    write_ir(ref c, "module asm \"2:\"\n");
    write_ir(ref c, "module asm \"subl %eax, %ecx\"\n");
    write_ir(ref c, "module asm \"testb $0, (%ecx)\"\n");
    write_ir(ref c, "module asm \"movl %esp, %eax\"\n");
    write_ir(ref c, "module asm \"movl %ecx, %esp\"\n");
    write_ir(ref c, "module asm \"movl (%eax), %ecx\"\n");
    write_ir(ref c, "module asm \"movl 4(%eax), %eax\"\n");
    write_ir(ref c, "module asm \"pushl %eax\"\n");
    write_ir(ref c, "module asm \"retl\"\n\n");
}

func emit_windows_x64_stack_probe(ref c: Compiler) -> Void {
// x64 callers adjust rsp after the probe returns

    write_ir(ref c, "module asm \".text\"\n");
    write_ir(ref c, "module asm \".p2align 4, 0x90\"\n");
    write_ir(ref c, "module asm \".globl __chkstk\"\n");
    write_ir(ref c, "module asm \".globl ___chkstk_ms\"\n");
    write_ir(ref c, "module asm \"__chkstk:\"\n");
    write_ir(ref c, "module asm \"___chkstk_ms:\"\n");
    write_ir(ref c, "module asm \"pushq %rcx\"\n");
    write_ir(ref c, "module asm \"pushq %rax\"\n");
    write_ir(ref c, "module asm \"cmpq $0x1000, %rax\"\n");
    write_ir(ref c, "module asm \"leaq 24(%rsp), %rcx\"\n");
    write_ir(ref c, "module asm \"jb 2f\"\n");
    write_ir(ref c, "module asm \"1:\"\n");
    write_ir(ref c, "module asm \"subq $0x1000, %rcx\"\n");
    write_ir(ref c, "module asm \"testb $0, (%rcx)\"\n");
    write_ir(ref c, "module asm \"subq $0x1000, %rax\"\n");
    write_ir(ref c, "module asm \"cmpq $0x1000, %rax\"\n");
    write_ir(ref c, "module asm \"ja 1b\"\n");
    write_ir(ref c, "module asm \"2:\"\n");
    write_ir(ref c, "module asm \"subq %rax, %rcx\"\n");
    write_ir(ref c, "module asm \"testb $0, (%rcx)\"\n");
    write_ir(ref c, "module asm \"popq %rax\"\n");
    write_ir(ref c, "module asm \"popq %rcx\"\n");
    write_ir(ref c, "module asm \"retq\"\n\n");
}

func emit_windows_stack_probe(ref c: Compiler) -> Void {
// keep target assembly private to the Windows backend until structured asm is available
    if (get_target_arch() == sys.Arch.X86) {
        emit_windows_x86_stack_probe(ref c);
    }
    else if (get_target_arch() == sys.Arch.X86_64) {
        emit_windows_x64_stack_probe(ref c);
    }
}

func emit_windows_abi(ref c: Compiler) -> Void {
    if (get_target_os() != sys.Os.Windows) {
        return;
    }

    write_ir(ref c, "@_fltused = global i32 39029\n\n");
    write_ir(ref c, "define void @__main() {\nentry:\n  ret void\n}\n\n");

    emit_freestanding_memops(ref c);
    if (get_target_arch() == sys.Arch.X86) {
        emit_windows_x86_division_builtins(ref c);
    }
    emit_windows_stack_probe(ref c);
}

func emit_windows_entrypoint(ref c: Compiler) -> Void {
    if (get_target_os() != sys.Os.Windows) {
        return;
    }
    if (c.is_shared) {
        let callconv: String = "";
        if (get_target_arch() == sys.Arch.X86) { callconv = "x86_stdcallcc "; }

        write_ir(ref c, "define " + callconv + "i32 @DllMainCRTStartup(i8* %instance, i32 %reason, i8* %reserved) {\n");
        write_ir(ref c, "entry:\n");
        write_ir(ref c, "  ret i32 1\n");
        write_ir(ref c, "}\n\n");

        return;
    }

    let main_info: Optional(FuncInfo) = c.func_table.lookup("main");
    let exit_key: Optional(String) = c.compiler_link.lookup("process_exit");
    if (exit_key is null) {
        throw_internal_compiler_error(no_position(), "Missing process exit hook.");
        return;
    }
    let exit_info: Optional(FuncInfo) = c.func_table.lookup(exit_key);
    if (!(main_info is !null) || !(exit_info is !null)) {
        throw_internal_compiler_error(no_position(), "Missing compiler runtime hooks required by the native entry point.");
        return;
    }

    let argc: Int = main_info.arg_types.length();

    write_ir(ref c, "define void @mainCRTStartup() {\n");
    write_ir(ref c, "entry:\n");

    if (argc == 0) {
        write_ir(ref c, "  %status = call i32 @main()\n");
    } else {
        let args_key: Optional(String) = c.compiler_link.lookup("startup_args");
        let free_key: Optional(String) = c.compiler_link.lookup("startup_args_free");
        if (args_key is null || free_key is null) {
            throw_internal_compiler_error(no_position(), "Missing Windows startup hooks.");
            return;
        }
        let args_info: Optional(FuncInfo) = c.func_table.lookup(args_key);
        let free_info: Optional(FuncInfo) = c.func_table.lookup(free_key);
        if (!(args_info is !null) || !(free_info is !null)) {
            throw_internal_compiler_error(no_position(), "Missing compiler runtime hooks required by the Windows entry point.");
            return;
        }

        write_ir(ref c, "  %argc.addr = alloca i32\n");
        write_ir(ref c, "  store i32 0, i32* %argc.addr\n");
        write_ir(ref c, "  %argv.raw = call i8* @" + args_info.name + "(i32* %argc.addr)\n");
        write_ir(ref c, "  %argv.missing = icmp eq i8* %argv.raw, null\n");
        write_ir(ref c, "  br i1 %argv.missing, label %startup.failed, label %startup.ready\n\n");
        write_ir(ref c, "startup.failed:\n");
        write_ir(ref c, "  call void @" + exit_info.name + "(i32 127)\n");
        write_ir(ref c, "  unreachable\n\n");
        write_ir(ref c, "startup.ready:\n");
        write_ir(ref c, "  %argc = load i32, i32* %argc.addr\n");
        write_ir(ref c, "  %argv = bitcast i8* %argv.raw to %struct.$String**\n");
        write_ir(ref c, "  %status = call i32 @main(i32 %argc, %struct.$String** %argv)\n");
        write_ir(ref c, "  call void @" + free_info.name + "(i32 %argc, i8* %argv.raw)\n");
    }

    write_ir(ref c, "  call void @" + exit_info.name + "(i32 %status)\n");
    write_ir(ref c, "  unreachable\n");
    write_ir(ref c, "}\n\n");
}
