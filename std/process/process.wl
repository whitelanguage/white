// std/process/process.wl
// process control

import "sys"
import "internal/platform/windows"
import "internal/platform/posix"
import "internal/platform/errors" as platform_errors
import "internal/runtime"
import "internal/runtime/string" as runtime_string
import Error as CoreError from "errors"

error Error {
    Unknown,
    NotFound,
    PermissionDenied,
    InvalidExecutable,
    ResourceBusy,
    Interrupted,
    TimedOut,
    Cancelled,
    Unsupported,
}

func __repeat_char(ch: Char, count: Int) -> String {
    let result: String = "";
    let i: Int = 0;
    while (i < count) {
        result += ch;
        i += 1;
    }
    return result;
}

func __quote_windows_arg(arg: String) -> String {
    if (arg.length() == 0) { return "\"\""; }

    let needs_quotes: Bool = false;
    let i: Int = 0;
    while (i < arg.length()) {
        let ch: Char = arg[i];
        if (ch == ' ' || ch == '\t' || ch == '"') {
            needs_quotes = true;
            break;
        }
        i += 1;
    }
    if (!needs_quotes) { return arg; }

    let result: String = "\"";
    let slashes: Int = 0;
    i = 0;
    while (i < arg.length()) {
        let ch: Char = arg[i];
        if (ch == '\\') {
            slashes += 1;
        } else if (ch == '"') {
            result += __repeat_char('\\', slashes * 2 + 1);
            result += "\"";
            slashes = 0;
        } else {
            if (slashes > 0) {
                result += __repeat_char('\\', slashes);
                slashes = 0;
            }
            result += arg.slice(i, i + 1);
        }
        i += 1;
    }
    if (slashes > 0) {
        result += __repeat_char('\\', slashes * 2);
    }
    return result + "\"";
}

func __windows_command_line(program: String, args: Vector(String)) -> String {
    let result: String = __quote_windows_arg(program);
    let count: Int = 0; if (args is !null) { count = args.length(); }
    let i: Int = 0;
    while (i < count) {
        result += " " + __quote_windows_arg(args[i]);
        i += 1;
    }
    return result;
}

func __from_platform(kind: platform_errors.Kind) -> Error {
    if (kind == platform_errors.Kind.NotFound) { return Error.NotFound; }
    if (kind == platform_errors.Kind.PermissionDenied) { return Error.PermissionDenied; }
    if (kind == platform_errors.Kind.ResourceBusy || kind == platform_errors.Kind.WouldBlock || kind == platform_errors.Kind.InProgress) { return Error.ResourceBusy; }
    if (kind == platform_errors.Kind.Interrupted) { return Error.Interrupted; }
    if (kind == platform_errors.Kind.TimedOut) { return Error.TimedOut; }
    if (kind == platform_errors.Kind.Cancelled) { return Error.Cancelled; }
    if (kind == platform_errors.Kind.Unsupported) { return Error.Unsupported; }
    if (kind == platform_errors.Kind.InvalidArgument) { return Error.InvalidExecutable; }
    return Error.Unknown;
}

func __last_error() -> Error {
    return __from_platform(platform_errors.last());
}

func run(program: String, args: Vector(String)) -> Int? {
    if (!runtime_string.is_native_text(program) || program.length() == 0) { throw CoreError.InvalidArgument; }
    let count: Int = 0; if (args is !null) { count = args.length(); }
    let arg_index: Int = 0;
    while (arg_index < count) {
        if (!runtime_string.is_native_text(args[arg_index])) { throw CoreError.InvalidArgument; }
        arg_index += 1;
    }

    if (sys.OS == sys.Os.Windows) {
        let command_line: String = __windows_command_line(program, args);
        let wide_command: AnyPtr = windows.utf8_to_utf16(command_line);
        if (wide_command is nullptr) {
            throw CoreError.OutOfMemory;
        }

        let startup_size: Int = windows.startup_info_size();
        let info_size: UIntSize = runtime.pointer_size() * UIntSize(2) + UIntSize(8);
        let startup: AnyPtr = runtime.mem_alloc_zeroed(UIntSize(startup_size));
        let info: AnyPtr = runtime.mem_alloc_zeroed(info_size);
        if (startup is nullptr || info is nullptr) {
            runtime.mem_dealloc(startup);
            runtime.mem_dealloc(info);
            windows.free_utf16(wide_command);
            throw CoreError.OutOfMemory;
        }
        let ptr startup_header: Int = startup;
        startup_header[0] = startup_size;

        let created: Int = windows.CreateProcessW(
            nullptr,
            wide_command,
            nullptr,
            nullptr,
            0,
            0,
            nullptr,
            nullptr,
            startup,
            info
        );
        windows.free_utf16(wide_command);
        if (created == 0) {
            runtime.mem_dealloc(startup);
            runtime.mem_dealloc(info);
            throw __last_error();
        }

        let ptr handles: AnyPtr = info;
        let process_handle: AnyPtr = handles[0];
        let thread_handle: AnyPtr = handles[1];
        runtime.mem_dealloc(startup);
        runtime.mem_dealloc(info);

        let exit_code: Int = -1;
        let waited: Int = windows.WaitForSingleObject(process_handle, windows.INFINITE);
        if (waited == windows.WAIT_FAILED || windows.GetExitCodeProcess(process_handle, ref exit_code) == 0) {
            let err: Error = __last_error();
            windows.CloseHandle(thread_handle);
            windows.CloseHandle(process_handle);
            throw err;
        }

        windows.CloseHandle(thread_handle);
        windows.CloseHandle(process_handle);
        return exit_code;
    }

    let bytes: UIntSize = UIntSize(count + 2) * runtime.pointer_size();
    let raw_argv: AnyPtr = runtime.mem_alloc_zeroed(bytes);
    if (raw_argv is nullptr) { throw CoreError.OutOfMemory; }

    let ptr native_argv: AnyPtr = raw_argv;
    native_argv[0] = runtime_string.data(program);
    let i: Int = 0;
    while (i < count) {
        native_argv[i + 1] = runtime_string.data(args[i]);
        i += 1;
    }

    let pid: Int = posix.fork();
    if (pid < 0) {
        runtime.mem_dealloc(raw_argv);
        throw __last_error();
    }
    if (pid == 0) {
        posix.execvp(runtime_string.data(program), raw_argv);
        posix._exit(127);
    }

    runtime.mem_dealloc(raw_argv);
    let status: Int = 0;
    if (posix.waitpid(pid, ref status, 0) < 0) {
        throw __last_error();
    }
    if ((status & 127) == 0) {
        return (status >> 8) & 255;
    }
    return 128 + (status & 127);
}

func shell(command: String) -> Int {
    if (!runtime_string.is_native_text(command) || command.length() == 0) { return -1; }
    if (sys.OS == sys.Os.Windows) {
        let args: Vector(String) = ["/d", "/s", "/c", command];
        let status: Int = run("cmd.exe", args)?;
        catch(err) {
            return -1;
        }
        return status;
    }
    return posix.system(runtime_string.data(command));
}

func argument(argc: Int, ptr argv: String, index: Int) -> String {
    if (argv is nullptr || index < 0 || index >= argc) { return null; }
    let raw_argv: AnyPtr = AnyPtr(argv);
    let ptr native_argv: AnyPtr = raw_argv;
    return runtime_string.from_c_string(native_argv[index]);
}

func id() -> Int {
    if (sys.OS == sys.Os.Windows) {
        return windows.GetCurrentProcessId();
    }
    return posix.getpid();
}

func exit(status: Int) -> Void {
    runtime.process_exit(status);
}
