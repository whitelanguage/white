// compiler/lowering/literals.wl
import * from "../context.wl"

func register_string_constant(c: Compiler, val: String) -> Int {
    let exist: StringConstant = c.string_pool.lookup(val);
    if (exist is !null) {
        return exist.id;
    }
    let s_id: Int = c.str_count;
    c.str_count += 1;
    let sc: StringConstant = StringConstant(id=s_id, value=val);
    c.string_list.append(sc);
    c.string_pool.put(val, sc);
    return s_id;
}

func get_string_ptr(s_id: Int, s_val: String) -> String {
    let len: Int = s_val.length() + 1;
    return "getelementptr inbounds ([" + len + " x i8], [" + len + " x i8]* @.str.bytes." + s_id + ", i32 0, i32 0)";
}

func get_string_object_ptr(s_id: Int) -> String {
    return "getelementptr inbounds ({ i32, i32, %struct.$String }, { i32, i32, %struct.$String }* @.str." + s_id + ", i32 0, i32 2)";
}

