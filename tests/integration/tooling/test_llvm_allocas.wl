// Test: LLVM_ALLOCA_HOISTING
// File: tests/integration/tooling/test_llvm_allocas.wl
// Focus: Keeping fixed local and temporary storage out of runtime loop blocks.

import hoist_llvm_allocas_text from "../../../src/compiler/backend/llvm.wl"

func main() -> Int {
    let input: String = "define internal i32 @work(i32 %arg0) {\nentry:\n  %local = alloca i32\n  store i32 %arg0, i32* %local\n  br label %loop\n\nloop:\n  %drop = alloca { i8*, i32 }\n  store { i8*, i32 } zeroinitializer, { i8*, i32 }* %drop\n  br label %loop\n}\n\ndeclare void @external()\n";
    let expected: String = "define internal i32 @work(i32 %arg0) {\nentry:\n  %local = alloca i32\n  %drop = alloca { i8*, i32 }\n  store i32 %arg0, i32* %local\n  br label %loop\n\nloop:\n  store { i8*, i32 } zeroinitializer, { i8*, i32 }* %drop\n  br label %loop\n}\n\ndeclare void @external()\n";
    let actual: String = hoist_llvm_allocas_text(input)?;
    catch(err) {
        print("FAIL: LLVM alloca finalization returned an error");
        return 1;
    }
    if (actual != expected) {
        print("FAIL: LLVM allocas were not moved to the entry block");
        return 1;
    }
    let second_pass: String = hoist_llvm_allocas_text(actual)?;
    catch(err) {
        print("FAIL: finalized LLVM IR could not be processed again");
        return 1;
    }
    if (second_pass != expected) {
        print("FAIL: LLVM alloca finalization is not stable");
        return 1;
    }
    print("PASS: LLVM alloca hoisting");
    return 0;
}
