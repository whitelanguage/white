// Support: MODULE_PRELUDE_SOURCE
// File: tests/fixtures/modules/prelude_source.wl
// Focus: Keeping prelude symbols visible when an imported module has its own imports.

import "file"
import "process"
import Dict from "dict"

func check_module_prelude() -> Bool {
    let values: Dict = Dict(1);
    values.put("ready", true);
    print("PASS: imported module prelude");
    return values.contains_key("ready") && Error.InvalidArgument != Error.Overflow;
}
