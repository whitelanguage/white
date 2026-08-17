# protocol

`protocol` contains the small set of interfaces which the language and generic
standard-library code agree on. They are ordinary White interfaces, but several
of them also have compiler-defined implementations for primitive types.

```rs
import Equal, Comparable, Ordering, Hash, Display from "protocol"
```

Protocols are checked statically. The compiler does not search for a specially
named method at runtime, and a class does not acquire a protocol merely because
it happens to contain methods with matching names. A class opts in with `with`:

```rs
class UserId with Hash, Display {
    let value: Int;

    init(value: Int) {
        self.value = value;
    }

    func equals(other: UserId) -> Bool {
        return self.value == other.value;
    }

    func hash() -> Int {
        return self.value;
    }

    func display() -> String {
        return "user:" + self.value;
    }
}
```

`Hash` inherits `Equal`, so the class above must provide both methods. Missing or
incorrect methods are reported when the class is compiled, before a generic
instance or dictionary operation reaches LLVM lowering.

## Self and static protocols

`Self` means the concrete class implementing an interface:

```rs
interface Equal {
    func equals(other: Self) -> Bool;
}

interface Clone {
    func clone() -> Self;
}
```

It can occur inside pointer, container, fallible and callable types in an
interface method signature. Outside an interface declaration it is an error.

An interface which mentions `Self` is a static protocol. It can constrain a
generic parameter, but it cannot be stored as a type-erased interface value:

```rs
func same<T: Equal>(left: T, right: T) -> Bool {
    return left.equals(right);
}

let result = same(UserId(7), UserId(7)); // valid
let erased: Equal = UserId(7);           // rejected
```

The restriction is intentional. Once the concrete type has been erased, there
is no sound type for the `other: Self` parameter. Interfaces which do not use
`Self`, such as `Display` and `Iterator(T)`, remain normal interface values and
use dynamic dispatch.

## Interface inheritance

Interfaces can build on other interfaces:

```rs
interface Comparable with Equal {
    func compare(other: Self) -> Ordering;
}

interface Hash with Equal {
    func hash() -> Int;
}
```

Multiple parents are separated by commas. Their requirements are inherited,
and classes implementing the child also satisfy each parent constraint. The
compiler rejects inheritance cycles and conflicting inherited method names.
The same ancestor reached through both sides of a diamond is included once.

## Equality and ordering

`Equal` supplies value equality:

```rs
interface Equal {
    func equals(other: Self) -> Bool;
}
```

For a class implementing `Equal`, `==` calls `equals`; `!=` negates the result.
The two operands must have the same concrete type. `equals` should be reflexive,
symmetric and transitive. Code which breaks those rules may compile, but sets,
dictionaries and generic algorithms cannot behave consistently for it.

`Comparable` adds a total ordering:

```rs
enum Ordering {
    Less,
    Equal,
    Greater
}

interface Comparable with Equal {
    func compare(other: Self) -> Ordering;
}
```

The relational operators call `compare`:

```text
left <  right    compare returns Ordering.Less
left <= right    compare does not return Ordering.Greater
left >  right    compare returns Ordering.Greater
left >= right    compare does not return Ordering.Less
```

`compare` and `equals` must describe the same equality relation. In particular,
`compare(other) == Ordering.Equal` must agree with `equals(other)`.

Integers, `Char` and `String` have compiler-defined `Equal` and `Comparable`
implementations. `Bool`, floating-point values, enums, pointers and callable
values support `Equal` but not ordering.

## Hash

`Hash` is the key contract used by `Dict(K, V)`:

```rs
interface Hash with Equal {
    func hash() -> Int;
}
```

The required law is simple and non-negotiable:

```text
a.equals(b) == true  implies  a.hash() == b.hash()
```

Unequal values may share a hash; the dictionary resolves collisions with
`equals`. A hash should be inexpensive and should use every field which
participates in equality. Changing either equality or the hash while an object
is present as a key makes that entry unreachable, so mutable class keys should
not modify key fields until they have been removed.

The returned integer is input to White's dictionary mixing step. It is not a
persistent identifier and should not be written to a file or protocol expecting
the same value across compiler or library versions.

Integers, `Bool`, `Char`, `String`, enums, pointers, functions and methods have
built-in `Hash`. Floating-point types deliberately do not: `NaN` cannot provide
the equality behaviour required by a typed dictionary. A heterogeneous `Dict`
still accepts ordinary finite floating-point keys and reports an invalid key for
`NaN`.

Class keys have two modes in the heterogeneous dictionary. A class which
implements `Hash` uses its `hash` and `equals` methods, so distinct objects may
represent the same key. Other classes retain identity-key behaviour.

## Display and Debug

`Display` is the user-facing representation of a value:

```rs
interface Display {
    func display() -> String;
}
```

`print` uses this method for a class implementing `Display`, including when the
value has been erased to the `Display` interface. Without it, classes retain
their structural fallback representation.

```rs
class Point with Display {
    let x: Int;
    let y: Int;

    init(x: Int, y: Int) {
        self.x = x;
        self.y = y;
    }

    func display() -> String {
        return "(" + self.x + ", " + self.y + ")";
    }
}

print(Point(3, 4)); // (3, 4)
```

`display` should return text suitable for users. It should not append a newline;
`print` owns `sep` and `end`. The returned String follows normal ownership rules
and may be newly allocated.

`Debug` is separate:

```rs
interface Debug {
    func debug() -> String;
}
```

It is intended for diagnostics and developer-facing state. `print` does not call
it implicitly. Keeping the two contracts separate prevents a logging-oriented
representation from unexpectedly becoming part of a command-line or file
format.

Primitive values and enums have compiler-defined `Display`. `Debug` is currently
opt-in for user classes.

## Clone

`Clone` requests an explicit duplicate of a value:

```rs
interface Clone {
    func clone() -> Self;
}
```

The protocol does not prescribe shallow or deep copying for fields; the type's
implementation must document that decision. Assignment remains ordinary White
assignment and never calls `clone` implicitly. There is no blanket compiler
implementation for managed objects, because silently choosing one copying policy
would be more surprising than requiring the type author to write it.

```rs
func duplicate<T: Clone>(value: T) -> T {
    return value.clone();
}
```

## Iteration

Iteration is split between the cursor and the value which creates it:

```rs
error IterationError {
    End
}

interface Iterator<T> {
    func next() -> T?;
}

interface Iterable<T> {
    func iterator() -> Iterator(T);
}
```

`next` returns the next item or throws `IterationError.End` when the sequence is
exhausted. Other failures are allowed and must not be mistaken for normal end of
input. An iterator is stateful; sharing the same iterator object shares its
position.

`Iterator(T)` and `Iterable(T)` are object-safe and can be passed as interface
values:

```rs
let source: Iterable(Int) = make_range(10);
let cursor: Iterator(Int) = source.iterator();
```

White's current `for` statement is the three-part control-flow form. It does not
silently rewrite an `Iterable` into a loop. A future iteration statement can use
these same contracts without changing existing iterator implementations.

## Built-in conformance

Compiler-defined implementations are deliberately limited to operations whose
meaning is already fixed by the language:

```text
Equal        integers, Float, Float32, Bool, Char, String, enums,
             pointers, functions and methods
Comparable   integers, Char and String
Hash         integers, Bool, Char, String, enums, pointers,
             functions and methods
Display      integers, Float, Float32, Bool, Char, String and enums
```

Built-ins can be used in generic constraints and called with the same method
syntax as user implementations:

```rs
let ordered = 10.compare(20);
let same = "wl".equals("wl");
let text = 42.display();
```

No runtime wrapper or protocol object is created for these calls. They lower to
the existing primitive comparison, hashing and conversion operations.

## What is not a protocol

Python's data model includes hooks for attribute lookup, truth conversion,
descriptors, context managers, arithmetic operators and asynchronous execution.
Those hooks are useful in a dynamic object model, but copying their names into
White would not implement their semantics.

White currently keeps the following as separate language features:

- explicit class conversions use `type T` members;
- constructors and destructors use `init` and `deinit`;
- indexing, arithmetic and calls are not open protocol dispatch points;
- fallible cleanup is handled by ownership lowering rather than a context-manager
  naming convention;
- raw pointer and extern behaviour stays explicit.

New protocols should be added when both generic code and a well-defined language
or library operation can use them. An interface which only copies the name of a
magic method is not part of this package.
