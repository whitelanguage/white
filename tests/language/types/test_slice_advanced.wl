// Test: SLICE_ADVANCED_SEMANTICS
// File: tests/language/types/test_slice_advanced.wl
// Focus: Shallow-copy slices, shared views, backing lifetime, and implicit conversion.


func sum_slice(arr: Array(Int)) -> Int {
    let s: Int = 0;
    let i: Int = 0;
    while (i < arr.length()) {
        s += arr[i];
        i++;
    }
    return s;
}

func main() -> Int {
    let a: Int[5] = [10, 20, 30, 40, 50];
    let slice_a: Array(Int) = a[1:4];
    let a_ok: Bool = (slice_a.length() == 3 && slice_a[0] == 20 && slice_a[2] == 40);

    let v: Vector(Int) = [100, 200, 300, 400];
    v.append(500);
    let slice_v: Array(Int) = v[2:5];
    let v_ok: Bool = (slice_v.length() == 3 && slice_v[0] == 300 && slice_v[2] == 500);

    let str: String = "WhiteLang";
    let slice_str: String = str[0:5];
    let full_str: String = str[:];
    let str_view: String = ref str[:];
    let s_ok: Bool = (slice_str == "White" && full_str == str && str_view == str);

    let sum1: Int = sum_slice(a);
    let sum2: Int = sum_slice(v);
    let sum3: Int = sum_slice(slice_a);
    let p_ok: Bool = (sum1 == 150 && sum2 == 1500 && sum3 == 90);

    let copied: Array(Int) = v[:];
    copied[0] = 999;
    let copy_ok: Bool = (v[0] == 100 && copied[0] == 999);

    let shared: Array(Int) = ref v[1:4];
    shared[0] = 222;
    v[2] = 333;
    v.append(600);
    v.append(700);
    let shared_ok: Bool = (v[1] == 222 && shared[1] == 333 && shared[2] == 400);

    let nested_copy: Array(Int) = shared[1:3];
    let nested_view: Array(Int) = ref shared[1:3];
    nested_copy[0] = 444;
    nested_view[0] = 555;
    let nested_ok: Bool = (nested_copy[0] == 444 && shared[1] == 555 && v[2] == 555);

    if (a_ok && v_ok && s_ok && p_ok && copy_ok && shared_ok && nested_ok) {
        print("PASS: Slice copy and view semantics");
    } else {
        print("FAIL: Slice copy or view result");
        return 1;
    }

    return 0;
}
