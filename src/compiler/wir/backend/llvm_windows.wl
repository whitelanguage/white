// compiler/wir/backend/llvm_windows.wl

import "strings"
import * from "../model.wl"

func llvm_windows_target(program: WirModule) -> Bool {
    return program.target == "i686-pc-windows-msvc" || program.target == "x86_64-pc-windows-msvc";
}

func llvm_windows_needs_support(program: WirModule) -> Bool {
    if (!llvm_windows_target(program)) { return false; }
    let i: Int = 0;
    while (i < program.arena.globals.length()) {
        if (program.arena.globals[i].name == "_fltused") { return true; }
        i++;
    }
    return false;
}

func llvm_windows_has_definition(program: WirModule, name: String) -> Bool {
    let i: Int = 0;
    while (i < program.arena.functions.length()) {
        let function: WirFunction = program.arena.functions[i];
        if (function.name == name && function.linkage != WirLinkage.External) { return true; }
        i++;
    }
    return false;
}

func llvm_windows_emits_memop(program: WirModule, name: String) -> Bool {
    if (!llvm_windows_needs_support(program)) { return false; }
    if (name != "memcpy" && name != "memmove" && name != "memset") { return false; }
    return !llvm_windows_has_definition(program, name);
}

func llvm_write_windows_memcpy(output: strings.Builder, size_type: String) -> Void? {
    // volatile byte accesses keep LLVM from recognizing the fallback as another memcpy
    output.write("define ptr @memcpy(ptr %dest, ptr %src, " + size_type + " %count) noinline optnone {\n")?;
    output.write("entry:\n  br label %copy.cond\n\n")?;
    output.write("copy.cond:\n")?;
    output.write("  %index = phi " + size_type + " [ 0, %entry ], [ %next, %copy.body ]\n")?;
    output.write("  %done = icmp uge " + size_type + " %index, %count\n")?;
    output.write("  br i1 %done, label %copy.end, label %copy.body\n\n")?;
    output.write("copy.body:\n")?;
    output.write("  %source = getelementptr i8, ptr %src, " + size_type + " %index\n")?;
    output.write("  %byte = load volatile i8, ptr %source\n")?;
    output.write("  %target = getelementptr i8, ptr %dest, " + size_type + " %index\n")?;
    output.write("  store volatile i8 %byte, ptr %target\n")?;
    output.write("  %next = add " + size_type + " %index, 1\n")?;
    output.write("  br label %copy.cond\n\n")?;
    output.write("copy.end:\n  ret ptr %dest\n}\n\n")?;
    return;
}

func llvm_write_windows_memmove(output: strings.Builder, size_type: String) -> Void? {
    output.write("define ptr @memmove(ptr %dest, ptr %src, " + size_type + " %count) noinline optnone {\n")?;
    output.write("entry:\n")?;
    output.write("  %same = icmp eq ptr %dest, %src\n")?;
    output.write("  %empty = icmp eq " + size_type + " %count, 0\n")?;
    output.write("  %trivial = or i1 %same, %empty\n")?;
    output.write("  br i1 %trivial, label %move.end, label %move.direction\n\n")?;
    output.write("move.direction:\n")?;
    output.write("  %dest.addr = ptrtoint ptr %dest to " + size_type + "\n")?;
    output.write("  %src.addr = ptrtoint ptr %src to " + size_type + "\n")?;
    output.write("  %before = icmp ult " + size_type + " %dest.addr, %src.addr\n")?;
    output.write("  %distance = sub " + size_type + " %dest.addr, %src.addr\n")?;
    output.write("  %separate = icmp uge " + size_type + " %distance, %count\n")?;
    output.write("  %forward = or i1 %before, %separate\n")?;
    output.write("  br i1 %forward, label %forward.cond, label %backward.cond\n\n")?;
    output.write("forward.cond:\n")?;
    output.write("  %forward.index = phi " + size_type + " [ 0, %move.direction ], [ %forward.next, %forward.body ]\n")?;
    output.write("  %forward.done = icmp uge " + size_type + " %forward.index, %count\n")?;
    output.write("  br i1 %forward.done, label %move.end, label %forward.body\n\n")?;
    output.write("forward.body:\n")?;
    output.write("  %forward.src = getelementptr i8, ptr %src, " + size_type + " %forward.index\n")?;
    output.write("  %forward.byte = load volatile i8, ptr %forward.src\n")?;
    output.write("  %forward.dest = getelementptr i8, ptr %dest, " + size_type + " %forward.index\n")?;
    output.write("  store volatile i8 %forward.byte, ptr %forward.dest\n")?;
    output.write("  %forward.next = add " + size_type + " %forward.index, 1\n")?;
    output.write("  br label %forward.cond\n\n")?;
    output.write("backward.cond:\n")?;
    output.write("  %remaining = phi " + size_type + " [ %count, %move.direction ], [ %backward.index, %backward.body ]\n")?;
    output.write("  %backward.done = icmp eq " + size_type + " %remaining, 0\n")?;
    output.write("  br i1 %backward.done, label %move.end, label %backward.body\n\n")?;
    output.write("backward.body:\n")?;
    output.write("  %backward.index = sub " + size_type + " %remaining, 1\n")?;
    output.write("  %backward.src = getelementptr i8, ptr %src, " + size_type + " %backward.index\n")?;
    output.write("  %backward.byte = load volatile i8, ptr %backward.src\n")?;
    output.write("  %backward.dest = getelementptr i8, ptr %dest, " + size_type + " %backward.index\n")?;
    output.write("  store volatile i8 %backward.byte, ptr %backward.dest\n")?;
    output.write("  br label %backward.cond\n\n")?;
    output.write("move.end:\n  ret ptr %dest\n}\n\n")?;
    return;
}

func llvm_write_windows_memset(output: strings.Builder, size_type: String) -> Void? {
    output.write("define ptr @memset(ptr %dest, i32 %value, " + size_type + " %count) noinline optnone {\n")?;
    output.write("entry:\n  %byte = trunc i32 %value to i8\n  br label %set.cond\n\n")?;
    output.write("set.cond:\n")?;
    output.write("  %index = phi " + size_type + " [ 0, %entry ], [ %next, %set.body ]\n")?;
    output.write("  %done = icmp uge " + size_type + " %index, %count\n")?;
    output.write("  br i1 %done, label %set.end, label %set.body\n\n")?;
    output.write("set.body:\n")?;
    output.write("  %target = getelementptr i8, ptr %dest, " + size_type + " %index\n")?;
    output.write("  store volatile i8 %byte, ptr %target\n")?;
    output.write("  %next = add " + size_type + " %index, 1\n")?;
    output.write("  br label %set.cond\n\n")?;
    output.write("set.end:\n  ret ptr %dest\n}\n\n")?;
    return;
}

func llvm_write_windows_memops(output: strings.Builder, program: WirModule) -> Void? {
    let size_type: String = "i" + program.pointer_bits;
    if (llvm_windows_emits_memop(program, "memcpy")) { llvm_write_windows_memcpy(output, size_type)?; }
    if (llvm_windows_emits_memop(program, "memmove")) { llvm_write_windows_memmove(output, size_type)?; }
    if (llvm_windows_emits_memop(program, "memset")) { llvm_write_windows_memset(output, size_type)?; }
    return;
}

func llvm_write_windows_x86_udivrem(output: strings.Builder) -> Void? {
    /*
    use restoring division for the full-width case:

        quotient = 0
        remainder = 0
        for bit = 63 .. 0:
            remainder = (remainder << 1) | ((dividend >> bit) & 1)
            if remainder >= divisor:
                remainder -= divisor
                quotient |= 1 << bit

    the loop avoids introducing the same 64-bit helper call it implements.
    */
    output.write("define internal void @__wl_udivrem64(i64 %dividend, i64 %divisor, ptr %quotient.out, ptr %remainder.out) noinline {\n")?;
    output.write("entry:\n")?;
    output.write("  %zero = icmp eq i64 %divisor, 0\n")?;
    output.write("  br i1 %zero, label %divide.zero, label %check.range\n\n")?;
    output.write("divide.zero:\n  call void @llvm.trap()\n  unreachable\n\n")?;
    output.write("check.range:\n")?;
    output.write("  %less = icmp ult i64 %dividend, %divisor\n")?;
    output.write("  br i1 %less, label %less.than.divisor, label %check.narrow\n\n")?;
    output.write("less.than.divisor:\n")?;
    output.write("  store i64 0, ptr %quotient.out\n")?;
    output.write("  store i64 %dividend, ptr %remainder.out\n")?;
    output.write("  ret void\n\n")?;
    output.write("check.narrow:\n")?;
    output.write("  %dividend.high = lshr i64 %dividend, 32\n")?;
    output.write("  %divisor.high = lshr i64 %divisor, 32\n")?;
    output.write("  %high.bits = or i64 %dividend.high, %divisor.high\n")?;
    output.write("  %narrow = icmp eq i64 %high.bits, 0\n")?;
    output.write("  br i1 %narrow, label %divide.narrow, label %loop\n\n")?;
    output.write("divide.narrow:\n")?;
    output.write("  %dividend.low = trunc i64 %dividend to i32\n")?;
    output.write("  %divisor.low = trunc i64 %divisor to i32\n")?;
    output.write("  %quotient.low = udiv i32 %dividend.low, %divisor.low\n")?;
    output.write("  %remainder.low = urem i32 %dividend.low, %divisor.low\n")?;
    output.write("  %quotient.wide = zext i32 %quotient.low to i64\n")?;
    output.write("  %remainder.wide = zext i32 %remainder.low to i64\n")?;
    output.write("  store i64 %quotient.wide, ptr %quotient.out\n")?;
    output.write("  store i64 %remainder.wide, ptr %remainder.out\n")?;
    output.write("  ret void\n\n")?;
    output.write("loop:\n")?;
    output.write("  %index = phi i32 [ 64, %check.narrow ], [ %next.index, %body ]\n")?;
    output.write("  %quotient = phi i64 [ 0, %check.narrow ], [ %next.quotient, %body ]\n")?;
    output.write("  %remainder = phi i64 [ 0, %check.narrow ], [ %next.remainder, %body ]\n")?;
    output.write("  %done = icmp eq i32 %index, 0\n")?;
    output.write("  br i1 %done, label %finish, label %body\n\n")?;
    output.write("body:\n")?;
    output.write("  %next.index = sub i32 %index, 1\n")?;
    output.write("  %shift = zext i32 %next.index to i64\n")?;
    output.write("  %shifted.dividend = lshr i64 %dividend, %shift\n")?;
    output.write("  %bit = and i64 %shifted.dividend, 1\n")?;
    output.write("  %shifted.remainder = shl i64 %remainder, 1\n")?;
    output.write("  %candidate = or i64 %shifted.remainder, %bit\n")?;
    output.write("  %fits = icmp uge i64 %candidate, %divisor\n")?;
    output.write("  %reduced = sub i64 %candidate, %divisor\n")?;
    output.write("  %next.remainder = select i1 %fits, i64 %reduced, i64 %candidate\n")?;
    output.write("  %quotient.bit = shl i64 1, %shift\n")?;
    output.write("  %with.bit = or i64 %quotient, %quotient.bit\n")?;
    output.write("  %next.quotient = select i1 %fits, i64 %with.bit, i64 %quotient\n")?;
    output.write("  br label %loop\n\n")?;
    output.write("finish:\n")?;
    output.write("  store i64 %quotient, ptr %quotient.out\n")?;
    output.write("  store i64 %remainder, ptr %remainder.out\n")?;
    output.write("  ret void\n}\n\n")?;
    return;
}

func llvm_write_windows_x86_unsigned_division(output: strings.Builder) -> Void? {
    output.write("define x86_stdcallcc i64 @\"\\01__aulldiv\"(i64 %dividend, i64 %divisor) noinline {\n")?;
    output.write("entry:\n  %quotient = alloca i64\n  %remainder = alloca i64\n")?;
    output.write("  call void @__wl_udivrem64(i64 %dividend, i64 %divisor, ptr %quotient, ptr %remainder)\n")?;
    output.write("  %result = load i64, ptr %quotient\n  ret i64 %result\n}\n\n")?;
    output.write("define x86_stdcallcc i64 @\"\\01__aullrem\"(i64 %dividend, i64 %divisor) noinline {\n")?;
    output.write("entry:\n  %quotient = alloca i64\n  %remainder = alloca i64\n")?;
    output.write("  call void @__wl_udivrem64(i64 %dividend, i64 %divisor, ptr %quotient, ptr %remainder)\n")?;
    output.write("  %result = load i64, ptr %remainder\n  ret i64 %result\n}\n\n")?;
    return;
}

func llvm_write_windows_x86_signed_division(output: strings.Builder) -> Void? {
    output.write("define x86_stdcallcc i64 @\"\\01__alldiv\"(i64 %dividend, i64 %divisor) noinline {\n")?;
    output.write("entry:\n")?;
    output.write("  %dividend.negative = icmp slt i64 %dividend, 0\n")?;
    output.write("  %divisor.negative = icmp slt i64 %divisor, 0\n")?;
    output.write("  %negative.dividend = sub i64 0, %dividend\n")?;
    output.write("  %negative.divisor = sub i64 0, %divisor\n")?;
    output.write("  %magnitude.dividend = select i1 %dividend.negative, i64 %negative.dividend, i64 %dividend\n")?;
    output.write("  %magnitude.divisor = select i1 %divisor.negative, i64 %negative.divisor, i64 %divisor\n")?;
    output.write("  %quotient = alloca i64\n  %remainder = alloca i64\n")?;
    output.write("  call void @__wl_udivrem64(i64 %magnitude.dividend, i64 %magnitude.divisor, ptr %quotient, ptr %remainder)\n")?;
    output.write("  %magnitude = load i64, ptr %quotient\n")?;
    output.write("  %negative = xor i1 %dividend.negative, %divisor.negative\n")?;
    output.write("  %negative.result = sub i64 0, %magnitude\n")?;
    output.write("  %result = select i1 %negative, i64 %negative.result, i64 %magnitude\n")?;
    output.write("  ret i64 %result\n}\n\n")?;
    output.write("define x86_stdcallcc i64 @\"\\01__allrem\"(i64 %dividend, i64 %divisor) noinline {\n")?;
    output.write("entry:\n")?;
    output.write("  %dividend.negative = icmp slt i64 %dividend, 0\n")?;
    output.write("  %divisor.negative = icmp slt i64 %divisor, 0\n")?;
    output.write("  %negative.dividend = sub i64 0, %dividend\n")?;
    output.write("  %negative.divisor = sub i64 0, %divisor\n")?;
    output.write("  %magnitude.dividend = select i1 %dividend.negative, i64 %negative.dividend, i64 %dividend\n")?;
    output.write("  %magnitude.divisor = select i1 %divisor.negative, i64 %negative.divisor, i64 %divisor\n")?;
    output.write("  %quotient = alloca i64\n  %remainder = alloca i64\n")?;
    output.write("  call void @__wl_udivrem64(i64 %magnitude.dividend, i64 %magnitude.divisor, ptr %quotient, ptr %remainder)\n")?;
    output.write("  %magnitude = load i64, ptr %remainder\n")?;
    output.write("  %negative.result = sub i64 0, %magnitude\n")?;
    output.write("  %result = select i1 %dividend.negative, i64 %negative.result, i64 %magnitude\n")?;
    output.write("  ret i64 %result\n}\n\n")?;
    return;
}

func llvm_write_windows_x86_division(output: strings.Builder) -> Void? {
    llvm_write_windows_x86_udivrem(output)?;
    llvm_write_windows_x86_unsigned_division(output)?;
    llvm_write_windows_x86_signed_division(output)?;
    return;
}

func llvm_write_windows_x86_probe(output: strings.Builder) -> Void? {
    output.write("module asm \".text\"\n")?;
    output.write("module asm \".p2align 4, 0x90\"\n")?;
    output.write("module asm \".globl __chkstk\"\n")?;
    output.write("module asm \"__chkstk:\"\n")?;
    output.write("module asm \"pushl %ecx\"\n")?;
    output.write("module asm \"leal 8(%esp), %ecx\"\n")?;
    output.write("module asm \"cmpl $0x1000, %eax\"\n")?;
    output.write("module asm \"jb 2f\"\n")?;
    output.write("module asm \"1:\"\n")?;
    output.write("module asm \"subl $0x1000, %ecx\"\n")?;
    output.write("module asm \"testb $0, (%ecx)\"\n")?;
    output.write("module asm \"subl $0x1000, %eax\"\n")?;
    output.write("module asm \"cmpl $0x1000, %eax\"\n")?;
    output.write("module asm \"ja 1b\"\n")?;
    output.write("module asm \"2:\"\n")?;
    output.write("module asm \"subl %eax, %ecx\"\n")?;
    output.write("module asm \"testb $0, (%ecx)\"\n")?;
    output.write("module asm \"movl %esp, %eax\"\n")?;
    output.write("module asm \"movl %ecx, %esp\"\n")?;
    output.write("module asm \"movl (%eax), %ecx\"\n")?;
    output.write("module asm \"movl 4(%eax), %eax\"\n")?;
    output.write("module asm \"pushl %eax\"\n")?;
    output.write("module asm \"retl\"\n\n")?;
    return;
}

func llvm_write_windows_x64_probe(output: strings.Builder) -> Void? {
    output.write("module asm \".text\"\n")?;
    output.write("module asm \".p2align 4, 0x90\"\n")?;
    output.write("module asm \".globl __chkstk\"\n")?;
    output.write("module asm \".globl ___chkstk_ms\"\n")?;
    output.write("module asm \"__chkstk:\"\n")?;
    output.write("module asm \"___chkstk_ms:\"\n")?;
    output.write("module asm \"pushq %rcx\"\n")?;
    output.write("module asm \"pushq %rax\"\n")?;
    output.write("module asm \"cmpq $0x1000, %rax\"\n")?;
    output.write("module asm \"leaq 24(%rsp), %rcx\"\n")?;
    output.write("module asm \"jb 2f\"\n")?;
    output.write("module asm \"1:\"\n")?;
    output.write("module asm \"subq $0x1000, %rcx\"\n")?;
    output.write("module asm \"testb $0, (%rcx)\"\n")?;
    output.write("module asm \"subq $0x1000, %rax\"\n")?;
    output.write("module asm \"cmpq $0x1000, %rax\"\n")?;
    output.write("module asm \"ja 1b\"\n")?;
    output.write("module asm \"2:\"\n")?;
    output.write("module asm \"subq %rax, %rcx\"\n")?;
    output.write("module asm \"testb $0, (%rcx)\"\n")?;
    output.write("module asm \"popq %rax\"\n")?;
    output.write("module asm \"popq %rcx\"\n")?;
    output.write("module asm \"retq\"\n\n")?;
    return;
}

func llvm_write_windows_support(output: strings.Builder, program: WirModule) -> Void? {
    if (!llvm_windows_needs_support(program)) { return; }
    llvm_write_windows_memops(output, program)?;
    if (program.target == "i686-pc-windows-msvc") {
        llvm_write_windows_x86_division(output)?;
        llvm_write_windows_x86_probe(output)?;
    } else {
        llvm_write_windows_x64_probe(output)?;
    }
    return;
}
