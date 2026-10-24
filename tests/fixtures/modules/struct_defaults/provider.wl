// tests/fixtures/modules/struct_defaults/provider.wl
const __SIZE: Int = 11;

func __size() -> Int {
    return __SIZE;
}

struct Settings(size: Int = __size(), values: Vector(Int) = [])
struct GenericSettings<T>(values: Vector(T) = [])
struct Fixed(size: Int = __SIZE)
