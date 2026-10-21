// tests/integration/tooling/fixtures/aliases.wl

type T as Identity<T>;
type Vector(T) as List<T>;
type (T | Null) as Maybe<T>;
