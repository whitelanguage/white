// Test: STRUCT_BASE_FUNCTIONALITY
// File: tests/language/types/test_struct_basic.wl
// Focus: Struct declaration, field access, and multi-level default value initialization.


struct Config(id: Int, ratio: Float) {
    this.id = 999;
    this.ratio = 0.5;
}

struct Entity(hp: Int, tag: String, conf: Config) {
    this.hp = 100;
}

func main() -> Int {
    // test default values
    let h1: Entity;
    
    // test manual override
    let h2: Entity = Entity(hp=500, tag="Hero", conf=Config(ratio=0.8));

    if (h1.hp == 100 && h2.hp == 500 && h2.conf.ratio == 0.8) {
        print("PASS: Struct initialization and field mapping");
    } else {
        print("FAIL: Struct field value mismatch");
    }
    return 0;
}
