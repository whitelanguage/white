// src/compiler/native_abi.wl

func is_win64_target(target: String) -> Bool {
    return target.starts_with("x86_64-") && (target.ends_with("windows-msvc") || target.ends_with("windows-gnu"));
}

func win64_register_bytes(size: UInt64) -> Int {
// POD aggregates of these sizes occupy one integer register, including FP fields
    if (size == 1UL || size == 2UL || size == 4UL || size == 8UL) {
        return Int(size);
    }
    return 0;
}
