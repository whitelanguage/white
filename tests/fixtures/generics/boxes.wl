struct Box<T>(value: T)

func wrap<T>(value: T) -> Box(T) {
    return Box(value);
}

func unwrap<T>(value: Box(T)) -> T {
    return value.value;
}
