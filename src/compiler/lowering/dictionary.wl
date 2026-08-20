// compiler/lowering/dictionary.wl
import Dict from "dict"
import * from "../../frontend/ast.wl"
import * from "../context.wl"
import * from "../../frontend/diagnostics.wl"

func runtime_type_name(c: Compiler, type_id: Int) -> String {
    if (c.func_ret_map.lookup("" + type_id) is !null || c.method_ret_map.lookup("" + type_id) is !null) {
        // callable labels belong to source binding, not runtime type identity
        return mangle_type(c, type_id);
    }
    return get_type_name(c, type_id);
}

func type_fingerprint(c: Compiler, type_id: Int) -> UInt64 {
    /*
    fnv-1a over the canonical type name:

        hash := offset_basis
        for each byte:
            hash := hash xor byte
            hash := hash * prime
        return hash

    using the type name keeps erased tags independent of addresses and table order
    */
    let name: String = "whitelang:" + runtime_type_name(c, type_id);
    let hash: UInt64 = 14695981039346656037UL;
    let i: Int = 0;
    while (i < name.length()) {
        hash ^= UInt64(name[i]);
        hash *= 1099511628211UL;
        i += 1;
    }
    if (hash == UInt64(0)) { return UInt64(1); }
    return hash;
}

func is_dict_key_type(c: Compiler, type_id: Int) -> Bool {
    if (type_id == TYPE_NULL || type_id == TYPE_NULLPTR || type_id == TYPE_ANYPTR || type_id == TYPE_STRING) { return true; }
    if (is_primitive_type(type_id)) { return type_id != TYPE_ANY_ERROR; }
    if (is_pointer_type(c, type_id)) { return true; }

    let info: StructInfo = c.struct_id_map.lookup("" + type_id);
    if (info is !null) {
        if (info.is_enum || info.is_interface) { return true; }
        if (info.is_class) { return info.name != "dict.Dict" && info.name != "Dict" && !info.name.starts_with("dict.Dict$") && !info.name.starts_with("Dict$"); }
        return false;
    }
    if (c.func_ret_map.lookup("" + type_id) is !null || c.method_ret_map.lookup("" + type_id) is !null) { return true; }
    return false;
}

func is_dynamic_dict(info: StructInfo) -> Bool {
    return info is !null && (info.name == "dict.Dict" || info.name == "Dict");
}

func is_typed_dict(c: Compiler, info: StructInfo) -> Bool {
    if (info is null) { return false; }

    let template: GenericTemplate = c.generic_instance_templates.lookup("" + info.type_id);
    return template is !null && (template.name == "Dict" || template.name.ends_with(".Dict"));
}

func is_generic_class(c: Compiler, info: StructInfo) -> Bool {
    if (info is null) { return false; }

    let template: GenericTemplate = c.generic_instance_templates.lookup("" + info.type_id);
    if (template is null || template.node is null) { return false; }

    let base: Int = node_kind(template.node);
    return base == NODE_CLASS_DEF;
}

func is_dynamic_dict_key_method(name: String) -> Bool {
    return name == "put" || name == "get" || name == "remove" || name == "contains_key";
}

func append_dict_key_case(c: Compiler, cases: String, seen: Dict(String, StringConstant), type_id: Int, label: String) -> String {
// keep the full name around so a 64-bit collision fails during compilation
    let fingerprint: UInt64 = type_fingerprint(c, type_id);
    let key: String = "" + fingerprint;
    let previous: StringConstant = seen.lookup(key);
    let type_name: String = runtime_type_name(c, type_id);
    if (previous is !null && previous.value != type_name) {
        throw_internal_compiler_error(null, "Dict key fingerprint collision between " + previous.value + " and " + type_name);
        return cases;
    }
    if (previous is !null) { return cases; }
    seen.put(key, StringConstant(id=0, value=type_name));
    return cases + "    i64 " + fingerprint + ", label " + label + "\n";
}

func append_variant_ref_case(c: Compiler, cases: String, seen: Dict(String, StringConstant), type_id: Int) -> String {
    let fingerprint: UInt64 = type_fingerprint(c, type_id);
    let key: String = "" + fingerprint;
    let previous: StringConstant = seen.lookup(key);
    let type_name: String = runtime_type_name(c, type_id);
    if (previous is !null && previous.value != type_name) {
        throw_internal_compiler_error(null, "Variant fingerprint collision between " + previous.value + " and " + type_name);
        return cases;
    }
    if (previous is !null) { return cases; }
    seen.put(key, StringConstant(id=0, value=type_name));
    return cases + "    i64 " + fingerprint + ", label %release\n";
}

func emit_dict_key_helpers(c: Compiler) -> Void {
    c.output_file.write("define internal i32 @__wl_dict_hash_bits(i64 %tag, i64 %low, i64 %high) {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %mixed.0 = xor i64 %tag, %low\n");
    c.output_file.write("  %mixed.1 = xor i64 %mixed.0, %high\n");
    c.output_file.write("  %shifted.0 = lshr i64 %mixed.1, 30\n");
    c.output_file.write("  %mixed.2 = xor i64 %mixed.1, %shifted.0\n");
    c.output_file.write("  %mixed.3 = mul i64 %mixed.2, -4658895280553007687\n");
    c.output_file.write("  %shifted.1 = lshr i64 %mixed.3, 27\n");
    c.output_file.write("  %mixed.4 = xor i64 %mixed.3, %shifted.1\n");
    c.output_file.write("  %mixed.5 = mul i64 %mixed.4, -7723592293110705685\n");
    c.output_file.write("  %shifted.2 = lshr i64 %mixed.5, 31\n");
    c.output_file.write("  %mixed.6 = xor i64 %mixed.5, %shifted.2\n");
    c.output_file.write("  %raw = trunc i64 %mixed.6 to i32\n");
    c.output_file.write("  %positive = and i32 %raw, 2147483647\n");
    c.output_file.write("  %small = icmp ult i32 %positive, 2\n");
    c.output_file.write("  %adjusted = add i32 %positive, 2\n");
    c.output_file.write("  %result = select i1 %small, i32 %adjusted, i32 %positive\n");
    c.output_file.write("  ret i32 %result\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define internal i1 @__wl_dict_string_equal(%struct.$String* %left, %struct.$String* %right) {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %same = icmp eq %struct.$String* %left, %right\n");
    c.output_file.write("  br i1 %same, label %equal, label %check.null\n");
    c.output_file.write("check.null:\n");
    c.output_file.write("  %left.null = icmp eq %struct.$String* %left, null\n");
    c.output_file.write("  %right.null = icmp eq %struct.$String* %right, null\n");
    c.output_file.write("  %has.null = or i1 %left.null, %right.null\n");
    c.output_file.write("  br i1 %has.null, label %different, label %check.length\n");
    c.output_file.write("check.length:\n");
    c.output_file.write("  %left.len.addr = getelementptr inbounds %struct.$String, %struct.$String* %left, i32 0, i32 1\n");
    c.output_file.write("  %right.len.addr = getelementptr inbounds %struct.$String, %struct.$String* %right, i32 0, i32 1\n");
    c.output_file.write("  %left.len = load i32, i32* %left.len.addr\n");
    c.output_file.write("  %right.len = load i32, i32* %right.len.addr\n");
    c.output_file.write("  %same.len = icmp eq i32 %left.len, %right.len\n");
    c.output_file.write("  br i1 %same.len, label %prepare, label %different\n");
    c.output_file.write("prepare:\n");
    c.output_file.write("  %left.buf.addr = getelementptr inbounds %struct.$String, %struct.$String* %left, i32 0, i32 0\n");
    c.output_file.write("  %right.buf.addr = getelementptr inbounds %struct.$String, %struct.$String* %right, i32 0, i32 0\n");
    c.output_file.write("  %left.buf = load i8*, i8** %left.buf.addr\n");
    c.output_file.write("  %right.buf = load i8*, i8** %right.buf.addr\n");
    c.output_file.write("  br label %compare\n");
    c.output_file.write("compare:\n");
    c.output_file.write("  %index = phi i32 [ 0, %prepare ], [ %next, %matched ]\n");
    c.output_file.write("  %done = icmp uge i32 %index, %left.len\n");
    c.output_file.write("  br i1 %done, label %equal, label %read\n");
    c.output_file.write("read:\n");
    c.output_file.write("  %left.byte.addr = getelementptr inbounds i8, i8* %left.buf, i32 %index\n");
    c.output_file.write("  %right.byte.addr = getelementptr inbounds i8, i8* %right.buf, i32 %index\n");
    c.output_file.write("  %left.byte = load i8, i8* %left.byte.addr\n");
    c.output_file.write("  %right.byte = load i8, i8* %right.byte.addr\n");
    c.output_file.write("  %byte.equal = icmp eq i8 %left.byte, %right.byte\n");
    c.output_file.write("  br i1 %byte.equal, label %matched, label %different\n");
    c.output_file.write("matched:\n");
    c.output_file.write("  %next = add i32 %index, 1\n");
    c.output_file.write("  br label %compare\n");
    c.output_file.write("equal:\n");
    c.output_file.write("  ret i1 true\n");
    c.output_file.write("different:\n");
    c.output_file.write("  ret i1 false\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define internal i32 @__wl_dict_key_hash(%struct.$Variant* %key) {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %is.null = icmp eq %struct.$Variant* %key, null\n");
    c.output_file.write("  br i1 %is.null, label %invalid, label %read\n");
    c.output_file.write("read:\n");
    c.output_file.write("  %tag.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %key, i32 0, i32 0\n");
    c.output_file.write("  %low.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %key, i32 0, i32 1\n");
    c.output_file.write("  %high.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %key, i32 0, i32 2\n");
    c.output_file.write("  %tag = load i64, i64* %tag.addr\n");
    c.output_file.write("  %low = load i64, i64* %low.addr\n");
    c.output_file.write("  %high = load i64, i64* %high.addr\n");
    c.output_file.write("  switch i64 %tag, label %invalid [\n");
    c.output_file.write("    i64 0, label %bits\n");
    let key_cases: String = "";
    let class_hash_blocks: String = "";

    let seen_keys: Dict(String, StringConstant) = Dict();
    seen_keys.put("0", StringConstant(id=0, value="null"));

    let hash_interface: StructInfo = c.struct_table.lookup("hashing.Hash");
    let type_id: Int = 1;
    while (type_id < c.type_counter) {
        if (type_id != TYPE_NULL && type_id != TYPE_NULLPTR && type_id != TYPE_GENERIC_CLASS && type_id != TYPE_GENERIC_FUNCTION && type_id != TYPE_GENERIC_METHOD && is_dict_key_type(c, type_id)) {
            let label: String = "%bits";
            if (type_id == TYPE_STRING) { label = "%string"; }
            if (type_id == TYPE_FLOAT || type_id == TYPE_FLOAT32) { label = "%float"; }
    
            let class_info: StructInfo = c.struct_id_map.lookup("" + type_id);
            if (class_info is !null && class_info.is_class && hash_interface is !null && implements_interface(c, type_id, hash_interface.type_id)) {
                label = "%class.hash." + type_id;
                c.hash_types.put("" + type_id, StringConstant(id=type_id, value=""));
                class_hash_blocks += "class.hash." + type_id + ":\n";
                class_hash_blocks += "  %class.ptr." + type_id + " = inttoptr i64 %low to " + class_info.llvm_name + "*\n";
                class_hash_blocks += "  %class.result." + type_id + " = call i32 @__wl_hash_value_" + type_id + "(" + class_info.llvm_name + "* %class.ptr." + type_id + ")\n";
                class_hash_blocks += "  ret i32 %class.result." + type_id + "\n";
            }

            key_cases = append_dict_key_case(c, key_cases, seen_keys, type_id, label);
        }
        type_id++;
    }
    c.output_file.write(key_cases);
    c.output_file.write("  ]\n");
    c.output_file.write("bits:\n");
    c.output_file.write("  %bits.hash = call i32 @__wl_dict_hash_bits(i64 %tag, i64 %low, i64 %high)\n");
    c.output_file.write("  ret i32 %bits.hash\n");
    c.output_file.write("float:\n");
    c.output_file.write("  %float.value = bitcast i64 %low to double\n");
    c.output_file.write("  %float.nan = fcmp uno double %float.value, %float.value\n");
    c.output_file.write("  br i1 %float.nan, label %invalid, label %float.valid\n");
    c.output_file.write("float.valid:\n");
    c.output_file.write("  %float.zero = fcmp oeq double %float.value, 0.0\n");
    c.output_file.write("  %float.bits = select i1 %float.zero, i64 0, i64 %low\n");
    c.output_file.write("  %float.hash = call i32 @__wl_dict_hash_bits(i64 %tag, i64 %float.bits, i64 0)\n");
    c.output_file.write("  ret i32 %float.hash\n");
    c.output_file.write("string:\n");
    c.output_file.write("  %string.ptr = inttoptr i64 %low to %struct.$String*\n");
    c.output_file.write("  %string.null = icmp eq %struct.$String* %string.ptr, null\n");
    c.output_file.write("  br i1 %string.null, label %invalid, label %string.read\n");
    c.output_file.write("string.read:\n");
    c.output_file.write("  %string.buf.addr = getelementptr inbounds %struct.$String, %struct.$String* %string.ptr, i32 0, i32 0\n");
    c.output_file.write("  %string.len.addr = getelementptr inbounds %struct.$String, %struct.$String* %string.ptr, i32 0, i32 1\n");
    c.output_file.write("  %string.buf = load i8*, i8** %string.buf.addr\n");
    c.output_file.write("  %string.len = load i32, i32* %string.len.addr\n");
    c.output_file.write("  %string.bad.len = icmp slt i32 %string.len, 0\n");
    c.output_file.write("  br i1 %string.bad.len, label %invalid, label %string.loop\n");
    c.output_file.write("string.loop:\n");
    c.output_file.write("  %string.index = phi i32 [ 0, %string.read ], [ %string.next, %string.body ]\n");
    c.output_file.write("  %string.state = phi i64 [ 14695981039346656037, %string.read ], [ %string.next.state, %string.body ]\n");
    c.output_file.write("  %string.done = icmp uge i32 %string.index, %string.len\n");
    c.output_file.write("  br i1 %string.done, label %string.end, label %string.body\n");
    c.output_file.write("string.body:\n");
    c.output_file.write("  %string.byte.addr = getelementptr inbounds i8, i8* %string.buf, i32 %string.index\n");
    c.output_file.write("  %string.byte = load i8, i8* %string.byte.addr\n");
    c.output_file.write("  %string.byte.wide = zext i8 %string.byte to i64\n");
    c.output_file.write("  %string.xor = xor i64 %string.state, %string.byte.wide\n");
    c.output_file.write("  %string.next.state = mul i64 %string.xor, 1099511628211\n");
    c.output_file.write("  %string.next = add i32 %string.index, 1\n");
    c.output_file.write("  br label %string.loop\n");
    c.output_file.write("string.end:\n");
    c.output_file.write("  %string.len.wide = zext i32 %string.len to i64\n");
    c.output_file.write("  %string.hash = call i32 @__wl_dict_hash_bits(i64 %tag, i64 %string.state, i64 %string.len.wide)\n");
    c.output_file.write("  ret i32 %string.hash\n");
    c.output_file.write(class_hash_blocks);
    c.output_file.write("invalid:\n");
    c.output_file.write("  ret i32 0\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define internal i1 @__wl_dict_keys_equal(%struct.$Variant* %left, %struct.$Variant* %right) {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %same = icmp eq %struct.$Variant* %left, %right\n");
    c.output_file.write("  br i1 %same, label %equal, label %check.null\n");
    c.output_file.write("check.null:\n");
    c.output_file.write("  %left.null = icmp eq %struct.$Variant* %left, null\n");
    c.output_file.write("  %right.null = icmp eq %struct.$Variant* %right, null\n");
    c.output_file.write("  %has.null = or i1 %left.null, %right.null\n");
    c.output_file.write("  br i1 %has.null, label %different, label %read\n");
    c.output_file.write("read:\n");
    c.output_file.write("  %left.tag.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %left, i32 0, i32 0\n");
    c.output_file.write("  %right.tag.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %right, i32 0, i32 0\n");
    c.output_file.write("  %left.tag = load i64, i64* %left.tag.addr\n");
    c.output_file.write("  %right.tag = load i64, i64* %right.tag.addr\n");
    c.output_file.write("  %same.tag = icmp eq i64 %left.tag, %right.tag\n");
    c.output_file.write("  br i1 %same.tag, label %dispatch, label %different\n");

    let class_equal_cases: String = "";
    let class_equal_blocks: String = "";

    type_id = 1;
    while (type_id < c.type_counter) {
        let class_info: StructInfo = c.struct_id_map.lookup("" + type_id);
        if (class_info is !null && class_info.is_class && hash_interface is !null && implements_interface(c, type_id, hash_interface.type_id)) {
            class_equal_cases += "    i64 " + type_fingerprint(c, type_id) + ", label %class.equal." + type_id + "\n";
            class_equal_blocks += "class.equal." + type_id + ":\n";
            class_equal_blocks += "  %class.left.addr." + type_id + " = getelementptr inbounds %struct.$Variant, %struct.$Variant* %left, i32 0, i32 1\n";
            class_equal_blocks += "  %class.right.addr." + type_id + " = getelementptr inbounds %struct.$Variant, %struct.$Variant* %right, i32 0, i32 1\n";
            class_equal_blocks += "  %class.left.raw." + type_id + " = load i64, i64* %class.left.addr." + type_id + "\n";
            class_equal_blocks += "  %class.right.raw." + type_id + " = load i64, i64* %class.right.addr." + type_id + "\n";
            class_equal_blocks += "  %class.left." + type_id + " = inttoptr i64 %class.left.raw." + type_id + " to " + class_info.llvm_name + "*\n";
            class_equal_blocks += "  %class.right." + type_id + " = inttoptr i64 %class.right.raw." + type_id + " to " + class_info.llvm_name + "*\n";
            class_equal_blocks += "  %class.equal.result." + type_id + " = call i1 @__wl_values_equal_" + type_id + "(" + class_info.llvm_name + "* %class.left." + type_id + ", " + class_info.llvm_name + "* %class.right." + type_id + ")\n";
            class_equal_blocks += "  ret i1 %class.equal.result." + type_id + "\n";
        }
        type_id += 1;
    }

    c.output_file.write("dispatch:\n");
    c.output_file.write("  switch i64 %left.tag, label %bits [\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_STRING) + ", label %string\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_FLOAT) + ", label %float\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_FLOAT32) + ", label %float\n");
    c.output_file.write(class_equal_cases);
    c.output_file.write("  ]\n");
    c.output_file.write("bits:\n");
    c.output_file.write("  %left.low.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %left, i32 0, i32 1\n");
    c.output_file.write("  %right.low.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %right, i32 0, i32 1\n");
    c.output_file.write("  %left.high.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %left, i32 0, i32 2\n");
    c.output_file.write("  %right.high.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %right, i32 0, i32 2\n");
    c.output_file.write("  %left.low = load i64, i64* %left.low.addr\n");
    c.output_file.write("  %right.low = load i64, i64* %right.low.addr\n");
    c.output_file.write("  %left.high = load i64, i64* %left.high.addr\n");
    c.output_file.write("  %right.high = load i64, i64* %right.high.addr\n");
    c.output_file.write("  %same.low = icmp eq i64 %left.low, %right.low\n");
    c.output_file.write("  %same.high = icmp eq i64 %left.high, %right.high\n");
    c.output_file.write("  %same.bits = and i1 %same.low, %same.high\n");
    c.output_file.write("  ret i1 %same.bits\n");
    c.output_file.write("float:\n");
    c.output_file.write("  %float.left.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %left, i32 0, i32 1\n");
    c.output_file.write("  %float.right.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %right, i32 0, i32 1\n");
    c.output_file.write("  %float.left.bits = load i64, i64* %float.left.addr\n");
    c.output_file.write("  %float.right.bits = load i64, i64* %float.right.addr\n");
    c.output_file.write("  %float.left = bitcast i64 %float.left.bits to double\n");
    c.output_file.write("  %float.right = bitcast i64 %float.right.bits to double\n");
    c.output_file.write("  %float.equal = fcmp oeq double %float.left, %float.right\n");
    c.output_file.write("  ret i1 %float.equal\n");
    c.output_file.write("string:\n");
    c.output_file.write("  %string.left.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %left, i32 0, i32 1\n");
    c.output_file.write("  %string.right.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %right, i32 0, i32 1\n");
    c.output_file.write("  %string.left.raw = load i64, i64* %string.left.addr\n");
    c.output_file.write("  %string.right.raw = load i64, i64* %string.right.addr\n");
    c.output_file.write("  %string.left = inttoptr i64 %string.left.raw to %struct.$String*\n");
    c.output_file.write("  %string.right = inttoptr i64 %string.right.raw to %struct.$String*\n");
    c.output_file.write("  %string.equal = call i1 @__wl_dict_string_equal(%struct.$String* %string.left, %struct.$String* %string.right)\n");
    c.output_file.write("  ret i1 %string.equal\n");
    c.output_file.write(class_equal_blocks);
    c.output_file.write("equal:\n");
    c.output_file.write("  ret i1 true\n");
    c.output_file.write("different:\n");
    c.output_file.write("  ret i1 false\n");
    c.output_file.write("}\n\n");
}

func class_method_index(info: StructInfo, name: String) -> Int {
    let index: Int = 0;
    while (info is !null && info.vtable is !null && index < info.vtable.length()) {
        let entry: FuncInfo = info.vtable[index];
        if (entry.base_name == name) {
            return index;
        }
        index++;
    }
    return -1;
}

func emit_class_hash_helpers(c: Compiler, info: StructInfo, type_id: Int, llvm_type: String, hash_name: String, equal_name: String) -> Void {
    let hash_index: Int = class_method_index(info, "hash");
    let equal_index: Int = class_method_index(info, "equals");
    if (hash_index < 0 || equal_index < 0) {
        throw_internal_compiler_error(null, "Hash implementation is incomplete for " + get_type_name(c, type_id));
        return;
    }

    let table_type: String = class_vtable_type(c, info);
    c.output_file.write("define internal i32 " + hash_name + "(" + llvm_type + " %key) {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %is.null = icmp eq " + llvm_type + " %key, null\n");
    c.output_file.write("  br i1 %is.null, label %invalid, label %call\n");
    c.output_file.write("call:\n");
    c.output_file.write("  %vptr.addr = getelementptr inbounds " + info.llvm_name + ", " + llvm_type + " %key, i32 0, i32 0\n");
    c.output_file.write("  %vptr.raw = load i8*, i8** %vptr.addr\n");
    c.output_file.write("  %vtable = bitcast i8* %vptr.raw to " + table_type + "*\n");
    c.output_file.write("  %slot = getelementptr inbounds " + table_type + ", " + table_type + "* %vtable, i32 0, i32 " + hash_index + "\n");
    c.output_file.write("  %method.raw = load i8*, i8** %slot\n");
    c.output_file.write("  %method = bitcast i8* %method.raw to i32 (" + llvm_type + ")*\n");
    c.output_file.write("  %value = call i32 %method(" + llvm_type + " %key)\n");
    c.output_file.write("  %wide = sext i32 %value to i64\n");
    c.output_file.write("  %result = call i32 @__wl_dict_hash_bits(i64 " + type_fingerprint(c, type_id) + ", i64 %wide, i64 0)\n");
    c.output_file.write("  ret i32 %result\n");
    c.output_file.write("invalid:\n");
    c.output_file.write("  ret i32 0\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define internal i1 " + equal_name + "(" + llvm_type + " %left, " + llvm_type + " %right) {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %same = icmp eq " + llvm_type + " %left, %right\n");
    c.output_file.write("  br i1 %same, label %equal, label %check.null\n");
    c.output_file.write("check.null:\n");
    c.output_file.write("  %left.null = icmp eq " + llvm_type + " %left, null\n");
    c.output_file.write("  %right.null = icmp eq " + llvm_type + " %right, null\n");
    c.output_file.write("  %has.null = or i1 %left.null, %right.null\n");
    c.output_file.write("  br i1 %has.null, label %different, label %call\n");
    c.output_file.write("call:\n");
    c.output_file.write("  %vptr.addr = getelementptr inbounds " + info.llvm_name + ", " + llvm_type + " %left, i32 0, i32 0\n");
    c.output_file.write("  %vptr.raw = load i8*, i8** %vptr.addr\n");
    c.output_file.write("  %vtable = bitcast i8* %vptr.raw to " + table_type + "*\n");
    c.output_file.write("  %slot = getelementptr inbounds " + table_type + ", " + table_type + "* %vtable, i32 0, i32 " + equal_index + "\n");
    c.output_file.write("  %method.raw = load i8*, i8** %slot\n");
    c.output_file.write("  %method = bitcast i8* %method.raw to i1 (" + llvm_type + ", " + llvm_type + ")*\n");
    c.output_file.write("  %result = call i1 %method(" + llvm_type + " %left, " + llvm_type + " %right)\n");
    c.output_file.write("  ret i1 %result\n");
    c.output_file.write("equal:\n");
    c.output_file.write("  ret i1 true\n");
    c.output_file.write("different:\n");
    c.output_file.write("  ret i1 false\n");
    c.output_file.write("}\n\n");
}

func emit_hash_helpers(c: Compiler) -> Void {
    let slot: Int = 0;
    while (slot < c.hash_types.capacity) {
        if (c.hash_types.hashes[slot] >= 2) {
            let entry: StringConstant = c.hash_types.values[slot];
            let type_id: Int = entry.id;
            let repr_type: Int = get_repr_type(c, type_id);
            let llvm_type: String = get_llvm_type_str(c, type_id);
            let hash_name: String = "@__wl_hash_value_" + type_id;
            let equal_name: String = "@__wl_values_equal_" + type_id;
            let key_info: StructInfo = c.struct_id_map.lookup("" + repr_type);
            if (repr_type == TYPE_STRING) {
                c.output_file.write("define internal i32 " + hash_name + "(%struct.$String* %key) {\n");
                c.output_file.write("entry:\n");
                c.output_file.write("  %is.null = icmp eq %struct.$String* %key, null\n");
                c.output_file.write("  br i1 %is.null, label %invalid, label %read\n");
                c.output_file.write("read:\n");
                c.output_file.write("  %buf.addr = getelementptr inbounds %struct.$String, %struct.$String* %key, i32 0, i32 0\n");
                c.output_file.write("  %len.addr = getelementptr inbounds %struct.$String, %struct.$String* %key, i32 0, i32 1\n");
                c.output_file.write("  %buf = load i8*, i8** %buf.addr\n");
                c.output_file.write("  %len = load i32, i32* %len.addr\n");
                c.output_file.write("  br label %loop\n");
                c.output_file.write("loop:\n");
                c.output_file.write("  %index = phi i32 [ 0, %read ], [ %next, %body ]\n");
                c.output_file.write("  %state = phi i64 [ 14695981039346656037, %read ], [ %next.state, %body ]\n");
                c.output_file.write("  %done = icmp uge i32 %index, %len\n");
                c.output_file.write("  br i1 %done, label %finish, label %body\n");
                c.output_file.write("body:\n");
                c.output_file.write("  %byte.addr = getelementptr inbounds i8, i8* %buf, i32 %index\n");
                c.output_file.write("  %byte = load i8, i8* %byte.addr\n");
                c.output_file.write("  %wide = zext i8 %byte to i64\n");
                c.output_file.write("  %mixed = xor i64 %state, %wide\n");
                c.output_file.write("  %next.state = mul i64 %mixed, 1099511628211\n");
                c.output_file.write("  %next = add i32 %index, 1\n");
                c.output_file.write("  br label %loop\n");
                c.output_file.write("finish:\n");
                c.output_file.write("  %len.wide = zext i32 %len to i64\n");
                c.output_file.write("  %hash = call i32 @__wl_dict_hash_bits(i64 " + type_fingerprint(c, type_id) + ", i64 %state, i64 %len.wide)\n");
                c.output_file.write("  ret i32 %hash\n");
                c.output_file.write("invalid:\n");
                c.output_file.write("  ret i32 0\n");
                c.output_file.write("}\n\n");
                c.output_file.write("define internal i1 " + equal_name + "(%struct.$String* %left, %struct.$String* %right) {\nentry:\n  %result = call i1 @__wl_dict_string_equal(%struct.$String* %left, %struct.$String* %right)\n  ret i1 %result\n}\n\n");
            } else if (key_info is !null && key_info.is_class) {
                emit_class_hash_helpers(c, key_info, type_id, llvm_type, hash_name, equal_name);
            } else {
                c.output_file.write("define internal i32 " + hash_name + "(" + llvm_type + " %key) {\nentry:\n");
                let bits: String = "%bits";
                if (is_pointer_type(c, repr_type) || repr_type == TYPE_ANYPTR || 
                    c.func_ret_map.lookup("" + repr_type) is !null || 
                    c.method_ret_map.lookup("" + repr_type) is !null) {

                    c.output_file.write("  " + bits + " = ptrtoint " + llvm_type + " %key to i64\n");
                }
                else if (repr_type == TYPE_INT128 || repr_type == TYPE_UINT128) {
                    c.output_file.write("  %low = trunc i128 %key to i64\n  %shift = lshr i128 %key, 64\n  %high = trunc i128 %shift to i64\n  %result = call i32 @__wl_dict_hash_bits(i64 " + type_fingerprint(c, type_id) + ", i64 %low, i64 %high)\n  ret i32 %result\n}\n\n");
                    bits = "";
                }
                else if (repr_type == TYPE_FLOAT) {
                    c.output_file.write("  %is.nan = fcmp uno double %key, %key\n  br i1 %is.nan, label %invalid, label %float.valid\nfloat.valid:\n  %is.zero = fcmp oeq double %key, 0.0\n  %raw = bitcast double %key to i64\n  " + bits + " = select i1 %is.zero, i64 0, i64 %raw\n");
                }
                else if (repr_type == TYPE_FLOAT32) {
                    c.output_file.write("  %is.nan = fcmp uno float %key, %key\n  br i1 %is.nan, label %invalid, label %float.valid\nfloat.valid:\n  %is.zero = fcmp oeq float %key, 0.0\n  %raw = bitcast float %key to i32\n  %wide = zext i32 %raw to i64\n  " + bits + " = select i1 %is.zero, i64 0, i64 %wide\n");
                }
                else if (key_info is !null && key_info.is_enum) {
                    c.output_file.write("  " + bits + " = zext i32 %key to i64\n");
                }
                else {
                    let width: Int = get_type_bitwidth(repr_type);
                    if (width < 64) {
                        c.output_file.write("  " + bits + " = zext " + llvm_type + " %key to i64\n");
                    } else {
                        c.output_file.write("  " + bits + " = add i64 %key, 0\n");
                    }
                }

                if (bits.length() > 0) {
                    c.output_file.write("  %result = call i32 @__wl_dict_hash_bits(i64 " + type_fingerprint(c, type_id) + ", i64 " + bits + ", i64 0)\n  ret i32 %result\n");
                }
                if (repr_type == TYPE_FLOAT || repr_type == TYPE_FLOAT32) {
                    c.output_file.write("invalid:\n  ret i32 0\n");
                }
                if (bits.length() > 0) {
                    c.output_file.write("}\n\n");
                }
                c.output_file.write("define internal i1 " + equal_name + "(" + llvm_type + " %left, " + llvm_type + " %right) {\nentry:\n");
                if (repr_type == TYPE_FLOAT || repr_type == TYPE_FLOAT32) {
                    c.output_file.write("  %result = fcmp oeq " + llvm_type + " %left, %right\n");
                } else {
                    c.output_file.write("  %result = icmp eq " + llvm_type + " %left, %right\n");
                }
                c.output_file.write("  ret i1 %result\n}\n\n");
            }
        }
        slot += 1;
    }
}


func class_vtable_type(c: Compiler, info: StructInfo) -> String {
    if (c.generic_instance_templates.lookup("" + info.type_id) is !null) {
        return generic_llvm_name("%vtable_type.__generic.", info.type_id);
    }
    return "%vtable_type." + info.name;
}

