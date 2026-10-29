// src/compiler/backend/posix.wl
import "sys"
import * from "../context.wl"
import get_target_os from "../target.wl"
import * from "../../frontend/diagnostics.wl"


func emit_posix_entrypoint(ref c: Compiler) -> Void {
// libc supplies C strings, the source main only receives managed String slots
    if (c.is_shared || get_target_os() == sys.Os.Windows) { return; }
    let found_main = c.func_table.lookup("main");
    if (found_main is null || found_main.arg_types.length() == 0) { return; }
    let main: FuncInfo = found_main;
    if (main.name == "main") { return; }
    let import_key = c.compiler_link.lookup("startup_args_import");
    let drop_key = c.compiler_link.lookup("startup_args_drop");
    if (import_key is null || drop_key is null) {
        throw_internal_compiler_error(no_position(), "Missing managed argument hooks.");
        return;
    }
    let found_import = c.func_table.lookup(import_key);
    let found_drop = c.func_table.lookup(drop_key);
    if (found_import is null || found_drop is null) {
        throw_internal_compiler_error(no_position(), "Missing managed argument functions.");
        return;
    }
    let import_info: FuncInfo = found_import;
    let drop_info: FuncInfo = found_drop;

    write_ir(ref c, "define i32 @main(i32 %argc, i8** %argv.native) {\nentry:\n");
    write_ir(ref c, "  %argv.raw = bitcast i8** %argv.native to i8*\n");
    write_ir(ref c, "  %argv.managed = call i8* @" + import_info.name + "(i32 %argc, i8* %argv.raw)\n");
    write_ir(ref c, "  %argv.missing = icmp eq i8* %argv.managed, null\n");
    write_ir(ref c, "  br i1 %argv.missing, label %startup.failed, label %startup.ready\n\nstartup.failed:\n");
    write_ir(ref c, "  ret i32 127\n\nstartup.ready:\n");
    write_ir(ref c, "  %argv = bitcast i8* %argv.managed to %struct.$String**\n");
    write_ir(ref c, "  %status = call i32 @" + main.name + "(i32 %argc, %struct.$String** %argv)\n");
    write_ir(ref c, "  call void @" + drop_info.name + "(i32 %argc, i8* %argv.managed)\n");
    write_ir(ref c, "  ret i32 %status\n}\n\n");
}
