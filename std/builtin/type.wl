// std/builtin/type.wl

type (T | Null) as Optional<T>;

@CompilerIntrinsic("is_type")
func is_type() -> Bool {
// the compiler takes (value, Type), the type operand has no runtime parameter
    return false;
}

@CompilerIntrinsic("is_instance")
func is_instance() -> Bool {
// the compiler takes (object, Class), matching subclasses uses the allocation type
    return false;
}
