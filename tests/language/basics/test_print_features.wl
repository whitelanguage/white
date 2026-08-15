// Test: PRINT_FEATURES
// File: tests/language/basics/test_print_features.wl
// Focus: Variadic arguments, type-to-string conversion (Vector/Struct), and Unicode console support.


struct Point (
    x: Int,
    y: Int
)

struct User (
    id: Int,
    name: String,
    pos: Point
)

func main() -> Int {
    print("--- Basic Types ---");
    print("Int:", 1024);
    print("Long:", 9223372036854775807);
    print("Float:", 3.14159);
    print("Bool:", true, "and", false);
    print("Byte:", "A");
    print("");

    print("--- Unicode / Language Test ---");
    print("你好，WhiteLanguage！");
    print("こんにちは，WhiteLanguage！");
    print("မင်္ဂလာပါ，WhiteLanguage！");
    print("Привет，WhiteLanguage！");
    print("混合测试: 数字", 123123, " 字符: ❤️ 语言: 中文");
    print("");

    print("--- Vector Test ---");
    let nums: Vector(Int) = [1, 2, 3, 4, 5];
    let words: Vector(String) = ["Apple", "Banana", "Cherry"];
    print("Numbers:", nums);
    print("Fruits:", words);
    print("");

    print("--- Struct Test ---");
    let p: Point = Point(x=10, y=20);
    let u: User = User(
        id=1, 
        name="WhiteLang", 
        pos=p
    );
    print("Point struct:", p);
    print("User (Nested):", u);
    print("");

    print("--- Multi-Arg Test ---");
    print("Arg1", "Arg2", 100, true, p);
    print("");

    print("--- Null & Pointer Test ---");
    let n: String = null;
    print("Null string:", n);
    
    print("PASS: Variadic print and complex type stringification");

    return 0;
}
