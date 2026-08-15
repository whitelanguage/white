# JSON

`json` is White's in-memory JSON package. It reads and writes UTF-8 and represents a document as a tree of `json.Value` objects.

```rs
import "json"
```

The parser follows the JSON grammar from RFC 8259. It deliberately rejects a
few extensions accepted by some JavaScript-oriented parsers: comments,
trailing commas, byte-order marks, `NaN`, and infinity are not JSON here.

At the moment the package works on complete strings. There is no streaming
decoder and no automatic struct mapping. Callers reading untrusted input should
apply a byte limit before passing the string to `json.decode`.

## Reading JSON

For most programs, decoding starts like this:

```rs
import "json"

func main() -> Int {
    let source: String =
        "{\"name\":\"White Language\",\"version\":3,\"native\":true}";

    let root: json.Value = json.decode(source)?;
    catch(err) {
        print("invalid JSON: ", err);
        return 1;
    }

    let name: String = String(root.get("name")?)?;
    catch(err) {
        print("field 'name' is missing or is not a string");
        return 1;
    }

    let version: Long = Long(root.get("version")?)?;
    catch(err) {
        print("field 'version' must be an integer");
        return 1;
    }

    print(name, " v", version);
    return 0;
}
```

`decode` parses exactly one value. Leading and trailing JSON whitespace is
allowed; any other data after the root value returns
`JsonError.TrailingData`.

A function which does not want to handle the error can propagate it:

```rs
func parse_message(source: String) -> json.Value? {
    return json.decode(source)?;
}
```

## Values and kinds

`json.Value` covers the six kinds of value defined by JSON:

```text
JSON null       json.Kind.Null
JSON boolean    json.Kind.Boolean
JSON number     json.Kind.Number
JSON string     json.Kind.Text
JSON array      json.Kind.Array
JSON object     json.Kind.Object
```

Use `kind()` when the input may have more than one shape:

```rs
if (value.kind() == json.Kind.Array) {
    let count: Int = value.length()?;
    catch(err) { return 1; }
    print("array with ", count, " elements");
}
```

There are two forms of null to keep apart. `json.null_value()` constructs an
actual JSON value. A null `json.Value` reference means that no value object
exists at all.

```rs
let json_null: json.Value = json.null_value();
let no_value: json.Value = null;

json_null.is_null(); // true
json.encode(json_null)?; // "null"
json.encode(no_value)?;  // JsonError.InvalidValue
```

This matters when using `find`. A missing member returns a null reference. A
present member whose contents are JSON `null` returns a non-null `Value` with
kind `Kind.Null`.

## Scalars

The usual way to extract a scalar is an explicit conversion:

```rs
let flag: Bool = Bool(value)?;
let count: Long = Long(value)?;
let ratio: Float = Float(value)?;
let text: String = String(value)?;
```

The method forms are equivalent:

```rs
value.as_bool()
value.as_long()
value.as_float()
value.as_string()
```

These operations are strict. The package does not guess that JSON string
`"42"` was meant to be a number, or that number `0` was meant to be false. A
kind mismatch returns `JsonError.TypeMismatch`.

Integer conversion has one additional rule: the number must have been written
as an integer. `42` can be read as `Long`; `42.0` and `42e0` return
`JsonError.NumberNotInteger`. The complete signed 64-bit range is checked, and
an out-of-range integer returns `JsonError.NumberOutOfRange`.

`Float(value)?` returns an approximation. That is normally what an application
wants for decimal arithmetic, but it is not suitable for identifiers, large
integer counters, or decimal data which must survive a round trip unchanged.
The exact-number section below covers those cases.

## Objects

Use `get` when a member is required:

```rs
let name: json.Value = root.get("name")?;
catch(err) {
    if (err == json.JsonError.MissingKey) {
        print("missing required field 'name'");
    }
    return 1;
}
```

Use `find` when it is optional:

```rs
let description: json.Value = root.find("description");
if (description is !null) {
    let text: String = String(description)?;
    catch(err) {
        print("field 'description' must be a string");
        return 1;
    }
    print(text);
}
```

`contains(key)` is useful when presence matters independently of the stored
value. Unlike `get`, it does not return an error for a missing key.

Objects keep their first-insertion order. Replacing a member does not move its
key. Removing and inserting the same key again places it at the end. The
encoder uses this order, so output is stable across runs.

Duplicate keys in input use a last-value-wins policy:

```json
{"mode":"debug","mode":"release"}
```

The decoded object has one `mode` member containing `"release"`. Its position
is the position of the first occurrence.

Iteration is index based:

```rs
let count: Int = root.length()?;
catch(err) { return 1; }

let i: Int = 0;
while (i < count) {
    let key: String = root.key_at(i)?;
    catch(err) { return 1; }

    let member: json.Value = root.get(key)?;
    catch(err) { return 1; }

    let encoded: String = json.encode(member)?;
    catch(err) { return 1; }
    print(key, " = ", encoded);
    i += 1;
}
```

The object methods on `Value` are:

```text
get(key)          required lookup; MissingKey if absent
find(key)         optional lookup; null if absent
contains(key)     membership test
set(key, value)   insert or replace
remove(key)       remove and report whether the key existed
length()          number of members
key_at(index)     key in insertion order
```

`get`, `set`, `remove`, `length`, and `key_at` return
`JsonError.TypeMismatch` when the receiver is not an object. `find` and
`contains` are probing operations; on a non-object they return `null` and
`false`.

`as_object()` exposes the underlying `json.Object`. It is mainly useful when
paired key/value traversal is wanted:

```rs
let object: json.Object = root.as_object()?;
catch(err) { return 1; }

let key: String = object.key_at(0)?;
catch(err) { return 1; }
let value: json.Value = object.value_at(0)?;
catch(err) { return 1; }
```

Most code should stay with the methods on `Value`.

## Arrays

Arrays currently support length, indexed access, and append:

```rs
let count: Int = values.length()?;
catch(err) { return 1; }

let i: Int = 0;
while (i < count) {
    let item: json.Value = values.at(i)?;
    catch(err) { return 1; }
    i += 1;
}
```

`at` checks both negative and upper bounds and returns
`JsonError.IndexOutOfBounds`. Calling an array operation on another kind returns
`JsonError.TypeMismatch`.

There is no indexed insert, replacement, or removal yet. This is an API gap,
not an invitation to reach into the private vector field.

## Building a document

Constructors mirror the JSON data model:

```rs
let nothing: json.Value = json.null_value();
let enabled: json.Value = json.boolean(true);
let count: json.Value = json.integer(42L)?;
let ratio: json.Value = json.number(0.75)?;
let exact: json.Value = json.number_from_text("1.2300e+4")?;
let name: json.Value = json.string("White Language")?;
let items: json.Value = json.array();
let root: json.Value = json.object();
```

String construction validates UTF-8 and copies the supplied bytes. Object keys
are also copied when first inserted. Mutating the source string later cannot
invalidate a JSON string or the object's hash table.

Here is a complete object with a nested array:

```rs
let project: json.Value = json.object();

project.set("name", json.string("White Language")?)?;
catch(err) { return 1; }
project.set("version", json.integer(3L)?)?;
catch(err) { return 1; }
project.set("bootstrapped", json.boolean(true))?;
catch(err) { return 1; }

let targets: json.Value = json.array();
targets.append(json.string("windows")?)?;
catch(err) { return 1; }
targets.append(json.string("linux")?)?;
catch(err) { return 1; }
targets.append(json.string("macos")?)?;
catch(err) { return 1; }

project.set("targets", targets)?;
catch(err) { return 1; }
```

Containers store `Value` references, not deep copies. This is intentional: a
large subtree can be passed around without copying it. It also means that a
mutable array or object shared by two parents is genuinely shared.

```rs
let shared: json.Value = json.array();
let left: json.Value = json.object();
let right: json.Value = json.object();

left.set("items", shared)?;
catch(err) { return 1; }
right.set("items", shared)?;
catch(err) { return 1; }

shared.append(json.boolean(true))?;
catch(err) { return 1; }

// left.items and right.items both contain [true]
```

Do not create reference cycles. Cycles are not JSON, and the ARC runtime cannot
reclaim a cycle built from `Value` containers. The encoder's depth limit stops
unbounded recursion, but it does not turn a cyclic graph into a valid document.

## Exact numbers

JSON deliberately leaves number precision to implementations. Converting every
number straight to `Float` would lose large integers and would rewrite values
such as `1.2300e+4`. The package therefore keeps both the original decimal text
and a floating-point approximation.

```rs
let value: json.Value =
    json.number_from_text("18446744073709551615")?;
catch(err) { return 1; }

let source: String = value.as_number_text()?;
catch(err) { return 1; }
print(source); // 18446744073709551615

let encoded: String = json.encode(value)?;
catch(err) { return 1; }
print(encoded); // 18446744073709551615
```

`number_from_text` validates the complete token before storing it. `01`, `1.`,
and `1e` are rejected. The spelling is otherwise kept as supplied:

```rs
let value: json.Value = json.number_from_text("1.2300e+4")?;
catch(err) { return 1; }

print(json.encode(value)?); // 1.2300e+4
catch(err) { return 1; }
```

Use `as_number_text()` for exact transport, `Long(value)?` for a checked signed
64-bit integer, and `Float(value)?` when rounding to the machine floating-point
type is acceptable.

## Writing JSON

`json.encode` produces compact output:

```rs
let output: String = json.encode(project)?;
catch(err) {
    print("could not encode JSON: ", err);
    return 1;
}
```

The encoder preserves object order and number spelling. It escapes quotes,
backslashes, and control characters. Valid non-ASCII UTF-8 is written directly
rather than expanded into `\u` escapes.

For indented output, use an `Encoder`:

```rs
let encoder: json.Encoder = json.Encoder();
encoder.set_indent(2);

let output: String = encoder.encode(project)?;
catch(err) { return 1; }
```

Indentation is the number of spaces per level. Values from 0 through 16 are
accepted; zero means compact output. The setter only records the option, so an
invalid value is reported by the following `encode` call as
`JsonError.InvalidIndent`.

The encoder also has a nesting limit:

```rs
let encoder: json.Encoder = json.Encoder();
encoder.set_max_depth(128);

let output: String = encoder.encode(project)?;
catch(err) {
    if (err == json.JsonError.NestingTooDeep) {
        print("document is too deeply nested");
    }
    return 1;
}
```

The default is 512. Limits from 1 through 1024 are accepted. An invalid limit
returns `JsonError.InvalidOption` when encoding begins.

## Decoder diagnostics

`json.decode` is enough when the caller only needs the error value. Use
`json.Decoder` when an error location or a smaller nesting limit is needed:

```rs
let decoder: json.Decoder = json.Decoder(source);
decoder.set_max_depth(128);

let root: json.Value = decoder.decode()?;
catch(err) {
    print(
        "JSON error at ",
        decoder.line(), ":", decoder.column(),
        " (byte ", decoder.offset(), "): ",
        err
    );
    return 1;
}
```

`offset()` is a zero-based UTF-8 byte offset. `line()` starts at one.
`column()` also starts at one, but it is a byte column rather than a Unicode
character column. That byte-oriented choice matches `String` indexing and the
decoder itself.

The stored position is useful after the decoder reports a syntax, escape, or
Unicode error. It is not meaningful before decoding or after success. Standard
allocation errors do not carry a JSON source position.

Decoder depth uses the same defaults and range as the encoder: 512 by default,
configurable from 1 through 1024. The root container counts as the first level.

## Files

File errors and JSON errors come from different error domains, but they can be
propagated through the same fallible function:

```rs
import "file"
import "json"

func load_json(path: String) -> json.Value? {
    let input: file.File = file.open(path)?;
    let source: String = input.read_all()?;
    input.close_checked()?;
    return json.decode(source)?;
}

func main(): Int {
    let config: json.Value = load_json("config.json")?;
    catch(err) {
        print("could not load config.json: ", err);
        return 1;
    }

    let name: String = String(config.get("name")?)?;
    catch(err) {
        print("config field 'name' must be a string");
        return 1;
    }

    print(name);
    return 0;
}
```

Closing the file before parsing keeps the file lifetime short. The returned
tree owns its strings and number tokens; it does not borrow storage from the
source string.

## Errors

`json.JsonError` contains the errors specific to JSON syntax and the `Value`
API:

```text
UnexpectedEnd             input ended in the middle of a value
UnexpectedToken           a byte is not valid at the current grammar position
TrailingData              data remains after the root value
InvalidUtf8               input or string data is not valid UTF-8
InvalidNumber             invalid JSON number syntax
InvalidEscape             unknown string escape
InvalidControlCharacter   unescaped control byte in a string
InvalidUnicodeEscape      invalid \u escape or UTF-16 surrogate pair
NestingTooDeep            configured nesting limit exceeded
TypeMismatch              operation used with the wrong Value kind
MissingKey                required object member not found
IndexOutOfBounds           array or object-order index outside its range
NumberNotInteger          decimal or exponent number requested as Long
NumberOutOfRange           integer does not fit in Long
InvalidIndent             indentation outside 0 through 16
InvalidOption             decoder or encoder option outside its valid range
InvalidValue              null reference or invalid Value supplied
```

Allocation failures remain standard errors:

```text
Error.OutOfMemory         allocation failed
Error.Overflow            required buffer size cannot be represented
```

Keeping these domains separate is useful. Invalid input can be reported to a
user or rejected at a protocol boundary; an allocation failure usually needs a
different response.

## Limits worth remembering

The decoder checks UTF-8, string escapes, surrogate pairs, number grammar,
trailing data, and nesting. It does not impose a maximum document length,
maximum string length, object member count, or array element count.

The depth limit protects recursive parsing and encoding. It does not prevent a
very large but shallow document from consuming substantial memory and CPU.
Network servers and command-line tools which read untrusted data should cap the
input before decoding it.

The package builds a mutable `Value` tree. It cannot decode directly into a
user class or struct, and it does not currently offer a deep-clone operation.
Those features need type reflection or a serialization interface; they should
not be approximated with unchecked casts inside this package.

## API at a glance

Package functions:

```text
decode(source)              Value?
encode(value)               String?
null_value()                Value
boolean(value)              Value
integer(value)              Value?
number(value)               Value?
number_from_text(source)    Value?
string(value)               Value?
array()                     Value
object()                    Value
```

Frequently used `Value` methods:

```text
kind()                      Kind
is_null()                   Bool
as_bool()                   Bool?
as_long()                   Long?
as_float()                  Float?
as_string()                 String?
as_number_text()            String?
length()                    Int?
at(index)                   Value?
append(value)               Void?
get(key)                    Value?
find(key)                   Value or null
contains(key)               Bool
set(key, value)             Void?
remove(key)                 Bool?
key_at(index)               String?
```
