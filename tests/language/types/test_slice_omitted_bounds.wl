// Test: SLICE_OMITTED_BOUNDS
// File: tests/language/types/test_slice_omitted_bounds.wl
// Focus: Omitted bounds distinguish copied slices from shared views.

func main() -> Int {
    let text: String = "WhiteLang";
    let text_copy: String = text[:];
    let text_view: String = ref text[:];
    let text_ok: Bool = text_copy == text &&
                          text_view == text &&
                          text_copy is ! text &&
                          text_view is text;

    let values: Vector(Int) = [10, 20, 30];
    let values_copy: Array(Int) = values[:];
    let values_view: Array(Int) = ref values[:];
    values_copy[0] = 99;
    values_view[1] = 88;
    let array_ok: Bool = values[0] == 10 &&
                           values_copy[0] == 99 &&
                           values[1] == 88 &&
                           values_view[1] == 88;

    if (!text_ok || !array_ok) {
        print("FAIL: Omitted slice bounds violated copy or view semantics");
        return 1;
    }

    print("PASS: Omitted slice bounds copy and view semantics");
    return 0;
}
