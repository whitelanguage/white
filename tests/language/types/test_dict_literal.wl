// Test: DICT_LITERAL_ALL_TYPES
// File: tests/language/types/test_dict_literal.wl
// Focus: Generic boxing of primitives, composites, and closures via Map literal syntax sugar.
import "dict"


struct Variant(hp: Int) {
    this.hp = 100; 
}

class Weapon {
    let damage: Int = 0;
    init(d: Int) -> Void {
        self.damage = d;
    }
    func attack() -> Int {
        return self.damage;
    }
}

func global_heal() -> Int {
    return 999;
}

func main() -> Int {
    let h: Variant = Variant(hp=888);
    let w: Weapon = Weapon(d=500);
    let m_ptr: Method() -> Int = w.attack;
    let f_ptr: Function() -> Int = global_heal;

    let map: Dict = {
        "type_int": 42,
        "type_float": 3.1415,
        "type_bool": true,
        "type_string": "WhiteLang_String",
        "type_struct": h,
        "type_class": w,
        "type_method": m_ptr,
        "type_function": f_ptr,
    };

    let r_int: Int = map["type_int"];
    let r_float: Float = map["type_float"];
    let r_bool: Bool = map["type_bool"];
    let r_str: String = map["type_string"];
    
    let prim_ok: Bool = (r_int == 42 && r_float == 3.1415 && r_bool == true && r_str == "WhiteLang_String");

    let r_struct: Variant = map["type_struct"];
    let r_class: Weapon = map["type_class"];
    let comp_ok: Bool = (r_struct.hp == 888 && r_class.damage == 500);

    let r_method: Method() -> Int = map["type_method"];
    let r_func: Function() -> Int = map["type_function"];
    let clos_ok: Bool = (r_method() == 500 && r_func() == 999);

    if (prim_ok && comp_ok && clos_ok) {
        print("PASS: Dictionary literal values");
    } else {
        print("FAIL: Dictionary literal value");
        return 1;
    }

    return 0;
}
