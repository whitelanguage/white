// std/file.wl
// file access

import "sys"
import "internal/platform/windows"
import "internal/platform/posix"
import "internal/platform/errors" as platform_errors
import "internal/runtime/string" as runtime_string
import "internal/runtime/memory" as runtime_memory

error Error {
    None,
    Unknown,
    InvalidPath,
    InvalidMode,
    InvalidState,
    OutOfMemory,
    NotFound,
    PermissionDenied,
    AlreadyExists,
    ResourceBusy,
    Interrupted,
    WouldBlock,
    TimedOut,
    Cancelled,
    ReadOnlyFilesystem,
    BrokenPipe,
    StorageFull,
    QuotaExceeded,
    FileTooLarge,
    TooManyOpenFiles,
    NotSeekable,
    NotADirectory,
    IsADirectory,
    DirectoryNotEmpty,
    NameTooLong,
    CrossDevice,
}

const SEEK_SET: Int = 0;
const SEEK_CUR: Int = 1;
const SEEK_END: Int = 2;

func __from_platform(kind: platform_errors.Kind) -> Error {
    if (kind == platform_errors.Kind.None) { return Error.None; }
    if (kind == platform_errors.Kind.NotFound) { return Error.NotFound; }
    if (kind == platform_errors.Kind.PermissionDenied) { return Error.PermissionDenied; }
    if (kind == platform_errors.Kind.AlreadyExists) { return Error.AlreadyExists; }
    if (kind == platform_errors.Kind.OutOfMemory) { return Error.OutOfMemory; }
    if (kind == platform_errors.Kind.ResourceBusy) { return Error.ResourceBusy; }
    if (kind == platform_errors.Kind.Interrupted) { return Error.Interrupted; }
    if (kind == platform_errors.Kind.WouldBlock) { return Error.WouldBlock; }
    if (kind == platform_errors.Kind.TimedOut) { return Error.TimedOut; }
    if (kind == platform_errors.Kind.Cancelled) { return Error.Cancelled; }
    if (kind == platform_errors.Kind.ReadOnlyFilesystem) { return Error.ReadOnlyFilesystem; }
    if (kind == platform_errors.Kind.BrokenPipe) { return Error.BrokenPipe; }
    if (kind == platform_errors.Kind.StorageFull) { return Error.StorageFull; }
    if (kind == platform_errors.Kind.QuotaExceeded) { return Error.QuotaExceeded; }
    if (kind == platform_errors.Kind.FileTooLarge) { return Error.FileTooLarge; }
    if (kind == platform_errors.Kind.TooManyOpenFiles) { return Error.TooManyOpenFiles; }
    if (kind == platform_errors.Kind.NotSeekable) { return Error.NotSeekable; }
    if (kind == platform_errors.Kind.NotADirectory) { return Error.NotADirectory; }
    if (kind == platform_errors.Kind.IsADirectory) { return Error.IsADirectory; }
    if (kind == platform_errors.Kind.DirectoryNotEmpty) { return Error.DirectoryNotEmpty; }
    if (kind == platform_errors.Kind.NameTooLong) { return Error.NameTooLong; }
    if (kind == platform_errors.Kind.CrossDevice) { return Error.CrossDevice; }
    return Error.Unknown;
}

func __last_error() -> Error {
    return __from_platform(platform_errors.last());
}

class File {
    let handle: AnyPtr = nullptr;
    let path: String = "";
    let __last_error: Error = Error.None;
    let write_buffer: String = null;
    let write_buffer_len: Int = 0;

    init(file_path: String, mode: String) {
        self.path = file_path;
        if (!runtime_string.is_native_text(file_path) || !runtime_string.is_native_text(mode)) {
            self.__last_error = Error.InvalidPath;
            return;
        }
        if (sys.OS == sys.Os.Windows) {
            let access: Int = windows.GENERIC_READ;
            let disposition: Int = windows.OPEN_EXISTING;
            let append_mode: Bool = false;

            if (mode.starts_with("w")) {
                access = windows.GENERIC_WRITE;
                disposition = windows.CREATE_ALWAYS;
            } else if (mode.starts_with("a")) {
                access = windows.GENERIC_WRITE;
                disposition = windows.OPEN_ALWAYS;
                append_mode = true;
            } else if (!mode.starts_with("r")) {
                self.__last_error = Error.InvalidMode;
                return;
            }

            if (mode.ends_with("+")) { access = windows.GENERIC_READ | windows.GENERIC_WRITE; }

            let wide_path: AnyPtr = windows.utf8_to_utf16(file_path);
            if (wide_path is nullptr) {
                self.__last_error = __last_error();
                return;
            }
            let raw_handle: AnyPtr = windows.CreateFileW(
                wide_path,
                access,
                windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
                nullptr,
                disposition,
                windows.FILE_ATTRIBUTE_NORMAL,
                nullptr
            );
            windows.free_utf16(wide_path);
            if (!windows.is_invalid_handle(raw_handle)) {
                self.handle = raw_handle;
                if (append_mode) { windows.SetFilePointerEx(self.handle, 0L, nullptr, windows.FILE_END); }
            } else {
                self.__last_error = __last_error();
            }
            return;
        }

        let raw_handle: AnyPtr = posix.fopen(runtime_string.data(file_path), runtime_string.data(mode));
        if (raw_handle is !nullptr) {
            self.handle = raw_handle;
        } else {
            self.__last_error = __last_error();
        }
    }

    func last_error() -> Error {
        return self.__last_error;
    }

    func __flush_write_buffer() -> Bool {
        if (self.write_buffer_len == 0) { return true; }
        if (self.handle is nullptr) {
            self.__last_error = Error.InvalidState;
            return false;
        }
        if (sys.OS != sys.Os.Windows) {
            self.write_buffer_len = 0;
            return true;
        }

        let bytes_written: Int = 0;
        if (windows.WriteFile(self.handle, runtime_string.data(self.write_buffer), self.write_buffer_len, ref bytes_written, nullptr) == 0) {
            self.__last_error = __last_error();
            return false;
        }
        if (bytes_written != self.write_buffer_len) {
            self.__last_error = Error.StorageFull;
            return false;
        }

        self.write_buffer_len = 0;
        return true;
    }

    func read_all() -> String? {
        if (self.handle is nullptr) {
            if (self.__last_error == Error.None) { throw Error.InvalidState; }
            throw self.__last_error;
        }

        if (sys.OS == sys.Os.Windows) {
            let size: Long = 0L;
            if (windows.GetFileSizeEx(self.handle, ref size) == 0 || size < 0L || size > 2147483647L) {
                if (size > 2147483647L) { throw Error.FileTooLarge; }
                self.__last_error = __last_error();
                throw self.__last_error;
            }

            let buffer: String = runtime_string.alloc(size);
            if (buffer is null) {
                self.__last_error = Error.OutOfMemory;
                throw self.__last_error;
            }
            let bytes_read: Int = 0;
            if (size > 0L && windows.ReadFile(self.handle, runtime_string.data(buffer), Int(size), ref bytes_read, nullptr) == 0) {
                self.__last_error = __last_error();
                throw self.__last_error;
            }
            runtime_string.set_length(buffer, bytes_read);
            self.__last_error = Error.None;
            return buffer;
        }

        if (posix.fseek(self.handle, IntSize(0), SEEK_END) != 0) {
            self.__last_error = __last_error();
            throw self.__last_error;
        }
        let size: IntSize = posix.ftell(self.handle);
        if (size < IntSize(0) || size > IntSize(2147483647)) {
            if (size > IntSize(2147483647)) { throw Error.FileTooLarge; }
            self.__last_error = __last_error();
            throw self.__last_error;
        }
        posix.rewind(self.handle);

        let buffer: String = runtime_string.alloc(Long(size));
        if (buffer is null) {
            self.__last_error = Error.OutOfMemory;
            throw self.__last_error;
        }
        let read_count: UIntSize = posix.fread(runtime_string.data(buffer), UIntSize(1), UIntSize(size), self.handle);
        runtime_string.set_length(buffer, Int(read_count));
        if (read_count != UIntSize(size)) {
            self.__last_error = __last_error();
            throw self.__last_error;
        }
        self.__last_error = Error.None;
        return buffer;
    }

    func write_all(content: String) -> Int? {
        if (self.handle is nullptr) {
            if (self.__last_error == Error.None) { throw Error.InvalidState; }
            throw self.__last_error;
        }
        if (!self.__flush_write_buffer()) { throw self.__last_error; }
        let length: Long = content.length();
        if (sys.OS == sys.Os.Windows) {
            let bytes_written: Int = 0;
            if (length > 0L && windows.WriteFile(self.handle, runtime_string.data(content), Int(length), ref bytes_written, nullptr) == 0) {
                self.__last_error = __last_error();
                throw self.__last_error;
            }
            if (Long(bytes_written) != length) {
                self.__last_error = Error.StorageFull;
                throw self.__last_error;
            }
            self.__last_error = Error.None;
            return bytes_written;
        }
        let written: UIntSize = posix.fwrite(runtime_string.data(content), UIntSize(1), UIntSize(length), self.handle);
        if (written != UIntSize(length)) {
            self.__last_error = __last_error();
            throw self.__last_error;
        }
        self.__last_error = Error.None;
        return Int(written);
    }

    func write(content: String) -> Void {
        if (self.handle is nullptr) { return; }
        let length: Long = content.length();
        if (sys.OS == sys.Os.Windows) {
            if (length <= 0L) { return; }
            if (self.write_buffer is null) {
                self.write_buffer = runtime_string.alloc(65536L);
                if (self.write_buffer is null) {
                    self.__last_error = Error.OutOfMemory;
                    return;
                }
                runtime_string.set_length(self.write_buffer, 0);
            }

            let ptr source: Byte = runtime_string.data(content);
            let ptr target: Byte = runtime_string.data(self.write_buffer);
            let source_idx: Int = 0;
            let content_len: Int = Int(length);
            while (source_idx < content_len) {
                if (self.write_buffer_len == 65536 && !self.__flush_write_buffer()) { return; }
                let available: Int = 65536 - self.write_buffer_len;
                let count: Int = content_len - source_idx;
                if (count > available) { count = available; }

                let target_start: AnyPtr = ref target[self.write_buffer_len];
                let source_start: AnyPtr = ref source[source_idx];
                runtime_memory.mem_copy(target_start, source_start, UIntSize(count));
                self.write_buffer_len += count;
                source_idx += count;
            }
            return;
        }
        if (posix.fwrite(runtime_string.data(content), UIntSize(1), UIntSize(length), self.handle) != UIntSize(length)) {
            self.__last_error = __last_error();
        }
    }

    func is_open() -> Bool {
        return self.handle is !nullptr;
    }

    func close_checked() -> Void? {
        let pending_error: Error = self.__last_error;
        if (self.handle is !nullptr) {
            if (!self.__flush_write_buffer() && pending_error == Error.None) {
                pending_error = self.__last_error;
            }
            let closed: Bool = false;
            if (sys.OS == sys.Os.Windows) { closed = windows.CloseHandle(self.handle) != 0; }
            else { closed = posix.fclose(self.handle) == 0; }
            self.handle = nullptr;
            if (!closed && pending_error == Error.None) {
                self.__last_error = __last_error();
                pending_error = self.__last_error;
            }
        }
        self.write_buffer = null;
        self.write_buffer_len = 0;
        if (pending_error != Error.None) {
            self.__last_error = pending_error;
            throw pending_error;
        }
        self.__last_error = Error.None;
        return;
    }

    func close() -> Void {
        self.close_checked()?;
        catch(err) {
            return;
        }
    }

    deinit() {
        self.close();
    }
}

func open(path: String) -> File? {
    let result: File = File(path, "rb");
    if (!result.is_open()) { throw result.last_error(); }
    return result;
}

func create(path: String) -> File? {
    let result: File = File(path, "wb");
    if (!result.is_open()) { throw result.last_error(); }
    return result;
}

func append(path: String) -> File? {
    let result: File = File(path, "ab");
    if (!result.is_open()) { throw result.last_error(); }
    return result;
}

func exists(path: String) -> Bool {
    if (!runtime_string.is_native_text(path)) { return false; }
    if (sys.OS == sys.Os.Windows) {
        let wide_path: AnyPtr = windows.utf8_to_utf16(path);
        if (wide_path is nullptr) { return false; }
        let attributes: Int = windows.GetFileAttributesW(wide_path);
        windows.free_utf16(wide_path);
        return attributes != windows.INVALID_FILE_ATTRIBUTES;
    }

    let mode: String = "rb";
    let handle: AnyPtr = posix.fopen(runtime_string.data(path), runtime_string.data(mode));
    if (handle is nullptr) { return false; }
    posix.fclose(handle);
    return true;
}

func remove(path: String) -> Void? {
    if (!runtime_string.is_native_text(path)) { throw Error.InvalidPath; }
    if (sys.OS == sys.Os.Windows) {
        let wide_path: AnyPtr = windows.utf8_to_utf16(path);
        if (wide_path is nullptr) { throw __last_error(); }
        let removed: Bool = windows.DeleteFileW(wide_path) != 0;
        windows.free_utf16(wide_path);
        if (!removed) { throw __last_error(); }
        return;
    }
    if (posix.remove(runtime_string.data(path)) != 0) { throw __last_error(); }
    return;
}
