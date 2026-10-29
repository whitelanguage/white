// std/internal/runtime/process.wl
// compiler process hooks

import "sys"
import "internal/platform/windows"
import "internal/platform/posix"
import "string.wl" as runtime_string
import "memory.wl" as memory


func write_err(message: String) -> Void {
    if (message is null || message.length() == 0) {
        return;
    }
    if (sys.OS == sys.Os.Windows) {
        let handle: AnyPtr = windows.GetStdHandle(windows.STD_ERROR_HANDLE);
        if (!windows.is_invalid_handle(handle)) {
            let written: Int = 0;
            windows.WriteFile(handle, runtime_string.data(message), message.length(), ref written, nullptr);
        }
        return;
    }

    posix.write(2, runtime_string.data(message), UIntSize(message.length()));
}

func panic(message: String) -> Void {
    write_err("fatal: " + message + "\n");
    process_exit(1);
}

func panic_capacity_overflow(owner: String) -> Void {
    panic(owner + " capacity overflow");
}

func panic_out_of_memory(owner: String) -> Void {
    panic(owner + " allocation failed: out of memory");
}

@CompilerLink("startup_args_import")
func import_startup_args(argc: Int, native_argv: AnyPtr) -> AnyPtr {
// the table owns one reference per slot, copies taken by main outlive table cleanup
    if (argc < 0 || (argc > 0 && native_argv is nullptr)) { return nullptr; }
    let limit = ~UIntSize(0);
    let count = UIntSize(argc);
    if (count >= limit / size_of(AnyPtr)) { return nullptr; }
    let storage = memory.mem_alloc_zeroed((count + UIntSize(1)) * size_of(AnyPtr));
    if (storage is nullptr) {
        write_err("fatal: Could not allocate process arguments\n");
        return nullptr;
    }
    let ptr native_args: AnyPtr = native_argv;
    let ptr args: String = storage;
    let i = 0;
    while (i < argc) {
        let value = runtime_string.from_c_string(native_args[i])?;
        catch(err) {
            free_managed_args(i, storage);
            write_err("fatal: Could not decode process arguments\n");
            return nullptr;
        }
        if (!runtime_string.is_native_text(value)) {
            free_managed_args(i, storage);
            write_err("fatal: Invalid UTF-8 process argument\n");
            return nullptr;
        }
        args[i] = value;
        i++;
    }
    return storage;
}

@CompilerLink("startup_args_drop")
func free_managed_args(argc: Int, argv: AnyPtr) -> Void {
// release initialized slots before freeing their pointer table, the sentinel is not a String
    if (argv is nullptr) { return; }
    let ptr args: String = argv;
    let i = 0;
    while (i < argc) {
        args[i] = "";
        i++;
    }
    memory.mem_dealloc(argv);
}

func __free_startup_args(count: Int, storage: AnyPtr) -> Void {
    if (sys.OS != sys.Os.Windows || storage is nullptr) {
        return;
    }
    let ptr args: AnyPtr = storage;
    let i: Int = 0;
    while (i < count) {
        if (args[i] is !nullptr) {
            windows.HeapFree(windows.GetProcessHeap(), 0, args[i]);
        }
        i += 1;
    }
    windows.HeapFree(windows.GetProcessHeap(), 0, storage);
}

@CompilerLink("startup_args")
func startup_args(ptr argc: Int) -> AnyPtr {
    if (sys.OS != sys.Os.Windows || argc is nullptr) { return nullptr; }
    argc[0] = 0;
    let wide_argv: AnyPtr = windows.CommandLineToArgvW(windows.GetCommandLineW(), argc);
    if (wide_argv is nullptr || argc[0] < 0) { return nullptr; }

    let count: Int = argc[0];
    let storage: AnyPtr = windows.HeapAlloc(windows.GetProcessHeap(), windows.HEAP_ZERO_MEMORY, UIntSize(count + 1) * size_of(AnyPtr));
    if (storage is nullptr) {
        windows.LocalFree(wide_argv);
        return nullptr;
    }

    let ptr wide_args: AnyPtr = wide_argv;
    let ptr args: AnyPtr = storage;
    let i: Int = 0;
    while (i < count) {
        let length: Int = windows.WideCharToMultiByte(windows.CP_UTF8, windows.WC_ERR_INVALID_CHARS, wide_args[i], -1, nullptr, 0, nullptr, nullptr);
        if (length <= 0) {
            __free_startup_args(i, storage);
            windows.LocalFree(wide_argv);
            return nullptr;
        }

        args[i] = windows.HeapAlloc(windows.GetProcessHeap(), 0, UIntSize(length));
        if (args[i] is nullptr || windows.WideCharToMultiByte(windows.CP_UTF8, windows.WC_ERR_INVALID_CHARS, wide_args[i], -1, args[i], length, nullptr, nullptr) <= 0) {
            if (args[i] is !nullptr) {
                windows.HeapFree(windows.GetProcessHeap(), 0, args[i]);
            }
            args[i] = nullptr;
            __free_startup_args(i, storage);
            windows.LocalFree(wide_argv);
            return nullptr;
        }
        i += 1;
    }

    windows.LocalFree(wide_argv);
    return storage;
}

@CompilerLink("startup_args_free")
func free_startup_args(argc: Int, argv: AnyPtr) -> Void {
    if (sys.OS == sys.Os.Windows) {
        __free_startup_args(argc, argv);
    }
}

@CompilerLink("process_exit")
func process_exit(status: Int) -> Void {
    if (sys.OS == sys.Os.Windows) {
        windows.ExitProcess(status);
        return;
    }
    posix.exit(status);
}
