# 08. Extensions, Bindings, And CLI Tasks

這一組看核心之外的邊界。你會學到如何把同一個 engine 包成 CLI、Rust API、C ABI、多語言 binding、extension 和 VFS。

- [ ] T259. **Extension API map**: read `extensions/core/README.md`, `extensions/core/src/lib.rs`; output extension registration flow.
- [ ] T260. **Extension value ABI**: read `extensions/core/src/types.rs`; output how extension values cross ABI safely.
- [ ] T261. **Scalar extension trait**: read `extensions/core/src/functions.rs`; output how a user-defined scalar function receives args and returns a value.
- [ ] T262. **Aggregate extension trait**: read `extensions/core/src/functions.rs`; output how aggregate context and finalization are modeled.
- [ ] T263. **Virtual table traits**: read `extensions/core/src/vtabs.rs`, `core/vtab.rs`; output module, table, and cursor responsibilities.
- [ ] T264. **Virtual table connection bridge**: read `core/ext/vtab_xconnect.rs`, `core/vdbe/execute.rs`; output how `VOpen`, `VFilter`, `VColumn`, and `VNext` reach extension code.
- [ ] T265. **Extension VFS trait**: read `extensions/core/src/vfs_modules.rs`; output how a custom file system plugs into core I/O.
- [ ] T266. **CSV extension**: read `extensions/csv/src/lib.rs`; output how a concrete virtual table exposes rows.
- [ ] T267. **Regexp extension**: read `extensions/regexp/src/lib.rs`; output how scalar function packaging differs from built-in core functions.
- [ ] T268. **Crypto extension**: read `extensions/crypto/src/lib.rs`, `extensions/crypto/src/crypto.rs`; output how feature code stays outside core.
- [ ] T269. **Fuzzy extension**: read `extensions/fuzzy/src/lib.rs`; output how many scalar algorithms are registered as one extension package.
- [ ] T270. **CLI entrypoint**: read `cli/main.rs`, `cli/app.rs`; output how CLI creates an application and chooses mode.
- [ ] T271. **Interactive input**: read `cli/input.rs`, `cli/helper.rs`; output how SQL input and shell commands are separated.
- [ ] T272. **CLI read state machine**: read `cli/read_state_machine.rs`; output how multiline SQL is buffered before execution.
- [ ] T273. **CLI commands**: read `cli/commands/mod.rs`, `cli/commands/args.rs`; output command dispatch and option parsing.
- [ ] T274. **CLI import path**: read `cli/commands/import.rs`; output how CSV or file import becomes database writes.
- [ ] T275. **CLI manual pages**: read `cli/manual.rs`, `cli/manuals/index.md`; output how user-facing docs are bundled.
- [ ] T276. **CLI VDBE trace**: read `cli/tests/vdbe_trace.rs`, `core/vdbe/explain.rs`; output how CLI exposes execution internals.
- [ ] T277. **CLI MCP server**: read `cli/mcp_server.rs`; output how database operations are exposed to tooling.
- [ ] T278. **CLI sync server**: read `cli/sync_server.rs`; output how sync-related endpoints reach database state.
- [ ] T279. **C binding**: read `bindings/c/src/lib.rs`, `bindings/c/include/sqlite3.h`; output how SQLite-compatible C symbols wrap Turso.
- [ ] T280. **Python binding**: read `bindings/python/src/lib.rs`, `bindings/python/src/turso.rs`; output PyO3 class boundaries and sync/async split.
- [ ] T281. **Python worker model**: read `bindings/python/turso/worker.py`, `bindings/python/turso/lib_aio.py`; output how Python async calls avoid blocking.
- [ ] T282. **JavaScript binding**: read `bindings/javascript/src/lib.rs`, `bindings/javascript/src/browser.rs`; output native versus wasm/browser concerns.
- [ ] T283. **Java binding**: read `bindings/java/rs_src/lib.rs`, `bindings/java/rs_src/turso_connection.rs`; output JNI object ownership and error conversion.
- [ ] T284. **Go binding**: read `bindings/go/bindings.go`, `bindings/go/driver_db.go`; output how Go driver API maps to core operations.
- [ ] T285. **React Native binding**: read `bindings/react-native/src/Database.ts`, `bindings/react-native/cpp/TursoDatabaseHostObject.cpp`; output TypeScript to C++ host object boundary.
- [ ] T286. **.NET binding survey**: read `bindings/dotnet/Readme.md`; output how generated/native packaging differs from Rust-native API.
- [ ] T287. **Binding value conversion**: compare `bindings/rust/src/value.rs`, `bindings/python/src/turso.rs`, `bindings/go/bindings_db.go`; output common value conversion rules.
- [ ] T288. **Binding error conversion**: compare Rust, Python, Java, and Go binding error files; output which errors are preserved or flattened.
- [ ] T289. **Binding test map**: inspect binding test directories; output how each language validates the same core semantics.
- [ ] T290. **SDK kit macro layer**: read `sdk-kit-macros/src/lib.rs`; output why code generation or macro support exists.
- [ ] T291. **C header generation**: read `sdk-kit/build.rs`, `sdk-kit/bindgen.sh`; output how Rust API is exported to C consumers.
- [ ] T292. **Sync SDK kit boundary**: read `sync/sdk-kit/src/rsapi.rs`, `sync/sdk-kit/src/capi.rs`; output how sync operations become foreign-language async operations.
- [ ] T293. **User API milestone**: implement mentally one call path in each of CLI, Rust, Python, and C binding; output where they converge in core.
- [ ] T294. **Extension milestone**: design a tiny scalar function extension on paper; output which trait methods, value conversions, and registration calls are required.
- [ ] T295. **Boundary milestone**: explain which code you would modify to add a new SQL function as built-in, as extension, and as binding API helper.

