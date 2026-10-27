// tests/fixtures/native_payloads.wl
struct NativeBox(text: String)
struct NativeArray(values: String[2])
struct NativeOptionArray(values: Optional(String)[2])

extern "C" {
    func native_box(text: AnyPtr) -> NativeBox;
    func native_entry(mode: Int, data: AnyPtr) -> Int;
}

@ExportLib
func exported_text(value: String) -> Int {
    return 42;
}

@ExportLib
func exported_optional(ref value: Optional(String)) -> Int {
    return 42;
}

@ExportLib
func exported_box(ref value: NativeBox) -> Int {
    return 42;
}

@ExportLib
func exported_array(ref value: NativeArray) -> Int {
    return 42;
}

@ExportLib
func exported_result(ref value: String?) -> Int {
    return 42;
}

@ExportLib
func exported_option_array(ref value: NativeOptionArray) -> Int {
    return 42;
}
