// tests/language/types/test_enum_value_layout.wl

enum State { Ready, Failed }
struct Detail(state: State, message: String = "")
struct Result(detail: Optional(Detail) = null)

func main() -> Int {
    if (size_of(State) != size_of(Int) || align_of(State) != align_of(Int)) { return 1; }
    if (size_of(Detail) != align_of(String) + size_of(String) || align_of(Detail) != align_of(String)) { return 2; }

    let result = Result();
    if (result.detail is !null) { return 3; }
    result.detail = Detail(State.Failed, "failed");
    if (result.detail is null) { return 4; }
    let detail: Detail = result.detail;
    if (detail.state != State.Failed || detail.message != "failed") { return 5; }
    let copy = result;
    result.detail = null;
    if (copy.detail is null) { return 6; }
    let copied: Detail = copy.detail;
    if (copied.state != State.Failed || copied.message != "failed") { return 7; }

    print("PASS: enum layout and Optional record ownership");
    return 0;
}
