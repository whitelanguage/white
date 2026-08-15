# strings

`strings` contains the growable string builder used by the standard library and
by programs which produce a substantial amount of text.

```rs
import "strings"
```

Ordinary concatenation is fine for a small, fixed expression. It is a poor fit
for a loop: every `left + right` creates a new String and copies the complete
prefix. `strings.Builder` keeps spare capacity and grows geometrically, so
building an `n`-byte result takes amortized O(n) time.

The builder produces UTF-8 `String` values. It is not a general binary buffer,
although it has a raw byte operation for encoders which assemble UTF-8 one byte
at a time. It also does not write to files or standard output; use `file` or
`io` for that.

## Building a string

The constructor takes an initial capacity in bytes. The value is a sizing hint,
not a length limit. Small capacities are rounded up to 64 bytes.

```rs
func make_label(name: String, count: Int) -> String? {
    let output: strings.Builder = strings.Builder(64);
    output.write(name)?;
    output.write(": ")?;
    output.write_int(count)?;
    return output.build()?;
}

func main() -> Int {
    let label: String = make_label("workers", 8)?;
    catch(err) {
        print("could not build label: ", err);
        return 1;
    }

    print(label); // workers: 8
    return 0;
}
```

`write` copies the bytes of a String into the builder. A null String returns
`Error.InvalidArgument`; an empty String is a successful no-op.

```rs
output.write("White")?;
output.write(" Language")?;
```

The source String does not have to remain alive after the call. The builder
owns its copy and never stores a borrowed pointer into caller-owned data.

## Characters and bytes

`write_char` encodes one `Char` directly as UTF-8:

```rs
output.write_char('白')?;
output.write_char('色')?;
```

No temporary String is allocated for either character. A forged `Char` whose
value is a UTF-16 surrogate or lies above `U+10FFFF` returns
`StringError.InvalidCodePoint`.

`write_byte` appends one raw byte:

```rs
output.write_byte(Byte(10))?; // newline
```

This operation deliberately does not validate the byte in isolation. UTF-8
encoders need to write a multi-byte scalar over several calls, and the first
byte of such a sequence is not valid on its own. The complete buffer is checked
by `build()` instead.

Use `write_char` for text when a `Char` is available. Use `write_byte` for ASCII
syntax, escape sequences, delimiters, and code which already understands UTF-8
encoding. It should not be used to smuggle arbitrary binary data into a String.

## Integers

The numeric methods append decimal text directly to the backing buffer:

```rs
output.write_int(-42)?;
output.write_long(9223372036854775807L)?;
output.write_uint(18446744073709551615UL)?;
```

Their accepted types are:

```text
write_int(value)    Int
write_long(value)   Long
write_uint(value)   UInt64
```

Formatting does not allocate an intermediate String. The full ranges are
supported, including the minimum signed `Int` and `Long` values and the maximum
`UInt64` value.

There is no floating-point writer yet. Code which needs one can append an
explicit conversion:

```rs
output.write(String(ratio))?;
```

That conversion creates a temporary String. A future formatting package can
add allocation-free float formatting without making `Builder` responsible for
format syntax and precision policy.

## Capacity

`length()` and `capacity()` are measured in bytes. `reserve(n)` ensures that at
least `n` additional bytes can be written without another allocation.

```rs
let output: strings.Builder = strings.Builder(64);
output.reserve(4096)?;

print(output.length());   // 0
print(output.capacity()); // at least 4096
```

`reserve` does not change the logical length. It returns `Error.Overflow` when
the requested length cannot be represented and `Error.OutOfMemory` when the
allocation fails.

Capacity normally doubles when the builder runs out of room. Callers usually do
not need to reserve manually. It is useful when a protocol header or source
container already gives a reliable output-size estimate.

## Clearing and reuse

`clear()` removes the current contents but retains the allocation:

```rs
output.write("discarded")?;
output.clear();

print(output.is_empty()); // true
print(output.capacity()); // unchanged
```

This is useful for a scratch builder reused inside a loop. Retaining a very
large allocation may be undesirable in a long-lived object; in that case,
finish the current value with `build()` and create a new builder when it is
needed again.

## Completing the value

`build()` validates the complete byte sequence as UTF-8 and returns it as a
String:

```rs
let result: String = output.build()?;
catch(err) {
    if (err == strings.StringError.InvalidUtf8) {
        print("builder contains invalid UTF-8");
    }
    return 1;
}
```

The backing allocation is transferred to the returned String. The builder is
left empty with zero capacity and can be used again:

```rs
let output: strings.Builder = strings.Builder(64);
output.write("first")?;
let first: String = output.build()?;

output.write("second")?;
let second: String = output.build()?;

// first is still "first"
```

The transfer is important. Returning a view of live builder storage would let a
later write change a String which had already been handed to the caller. White
does not expose that alias: after `build()`, subsequent writes use a different
allocation.

Calling `build()` on an empty, successfully allocated builder returns an empty
String. If the constructor could not allocate its initial storage, it returns
`Error.OutOfMemory`.

## Errors

Errors specific to text construction belong to `strings.StringError`:

```text
InvalidUtf8        the completed byte sequence is not valid UTF-8
InvalidCodePoint   a Char is not a Unicode scalar value
```

Allocation and argument failures remain standard errors:

```text
Error.InvalidArgument   null String passed to write
Error.OutOfMemory       backing storage allocation failed
Error.Overflow          required capacity exceeds the String length range
```

An unsuccessful `reserve` or write leaves the existing contents intact. If
`build()` reports invalid UTF-8, the bytes remain in the builder; the caller may
clear it or discard the builder.

## Limits worth remembering

A White String stores its length as `Int`, so a builder cannot produce more
than `2147483647` bytes. Capacity arithmetic is checked before allocation.

The builder is mutable and provides no synchronization. Sharing one instance
between threads requires external locking. Separate builders do not share
storage.

`build()` performs one linear UTF-8 validation pass. This keeps raw byte writes
cheap and catches incomplete multi-byte sequences at the boundary where they
become a String. Programs which only use `write` with valid Strings and
`write_char` still pay that final pass; the builder does not keep a second
incremental UTF-8 state machine.

## API at a glance

```text
Builder(initial_capacity)  create an empty builder

write(value)               append a String
write_byte(value)          append one raw Byte
write_char(value)          append one UTF-8 encoded Char
write_int(value)           append an Int in decimal
write_long(value)          append a Long in decimal
write_uint(value)          append a UInt64 in decimal

reserve(additional)        reserve room for additional bytes
length()                   current byte length
capacity()                 allocated byte capacity
is_empty()                 whether length is zero
clear()                    clear and retain storage
build()                    validate UTF-8 and transfer the result
```
