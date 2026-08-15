let marker: Int = 11;
let __private_marker: Int = 99;

struct Item(value: Int) {
    this.value = 0;
}

struct __PrivateItem(value: Int) {
    this.value = 0;
}

func label() -> String {
    return "left";
}
