// src/compiler/lowering/static_storage.wl
import "strings"
import "sys"
import * from "../context.wl"
import get_target_triple, get_target_pointer_bits, get_target_os from "../target.wl"
import * from "../wir/model.wl"
import * from "../wir/builder.wl"
import * from "../wir/layout.wl"
import * from "../wir/storage.wl"
import new_wir_type_map, wir_lower_source_type from "../wir/lowering/types.wl"
import wir_lower_static_value from "../wir/lowering/static_data.wl"
import llvm_write_storage, llvm_write_data_type, llvm_write_data_value from "../wir/backend/llvm.wl"
import verify_wir from "../wir/verify.wl"
import VarDeclareNode from "../../frontend/ast.wl"
import throw_type_error from "../../frontend/diagnostics.wl"


func emit_static_union(ref c: Compiler, node: VarDeclareNode, target: Int) -> Void? {
// use the same constant packing as WIR, the legacy backend still needs typed addresses
    let program = new_wir_module(get_target_triple(), get_target_pointer_bits());
    let types = new_wir_type_map();
    let value = wir_lower_static_value(ref types, ref c, ref program, node.value, target, node.pos);
    if (value == NO_WIR_VALUE) { return; }

    let annotations = consume_annotations(ref c, node.annotations, node.name_tok.value);
    let name = c.current_package_prefix + node.name_tok.value;
    let symbol = name;
    if ((annotations.ann_flags & FLAG_ANN_EXPORT) != 0) { symbol = node.name_tok.value; }
    let prefix = "$union." + c.str_count + ".";
    c.str_count++;
    let i = 0;
    while (i < program.arena.globals.length()) {
        program.arena.globals[i].name = prefix + program.arena.globals[i].name;
        i++;
    }
    let type_id = wir_lower_source_type(ref types, ref c, ref program, target);
    let global = wir_add_global(ref program, prefix + "storage", type_id, value, WirLinkage.Private, node.is_const);
    let errors = verify_wir(program);
    if (errors.length() != 0) {
        throw_type_error(node.pos, "Invalid global initializer: " + errors[0] + ".");
        return;
    }
    let output = strings.Builder(256);
    i = 0;
    while (i < program.arena.globals.length() - 1) {
        let data = program.arena.globals[i];
        output.write("@" + data.name + " = private constant ")?;
        llvm_write_data_type(output, program, data.type_id, true)?;
        output.write(" ")?;
        llvm_write_data_value(output, program, data.initializer, true)?;
        if (data.alignment != 0) { output.write(", align " + data.alignment)?; }
        output.write("\n")?;
        i++;
    }

    let layouts = wir_type_layouts(program);
    let layout = layouts[wir_id_index(UInt32(type_id))];
    let parts: WirStorageParts = WirStorageParts(elements=[], offsets=[]);
    wir_storage_parts(program, layouts, value, 0UL, parts);
    let backing = "@" + prefix + "storage";
    output.write(backing + " = private ")?;
    if (node.is_const) { output.write("constant ")?; }
    else { output.write("global ")?; }
    let packed = strings.Builder(128);
    llvm_write_storage(packed, program, layouts, parts, layout.size, true, true)?;
    let packed_type: String = packed.build()?;
    output.write(packed_type + " ")?;
    llvm_write_storage(output, program, layouts, parts, layout.size, false, true)?;
    output.write(", align " + layout.alignment + "\n")?;

    let source_type = get_llvm_type_str(ref c, target);
    let linkage = "";
    if (c.is_shared && get_target_os() == sys.Os.Windows) {
        if ((annotations.ann_flags & FLAG_ANN_EXPORT) != 0) { linkage = "dllexport "; }
        else { linkage = "hidden "; }
    }
    output.write("@" + symbol + " = " + linkage + "alias " + source_type + ", " + source_type + "* bitcast (" + packed_type + "* " + backing + " to " + source_type + "*)\n")?;
    write_ir(ref c, output.build()?);
    c.global_symbol_table.put(name, SymbolInfo(reg="@" + symbol, type=target, origin_type=target, is_const=node.is_const, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
    return;
}
