# 01. Entry API Tasks

這一組從使用者呼叫開始，追到 core engine。重點是「外層 API 很薄，真正的資料庫語義在 core」。

- [ ] T021. **Rust binding builder**: read `bindings/rust/src/lib.rs`, `bindings/rust/src/connection.rs`; output how a user reaches `Connection`.
- [ ] T022. **Rust async query API**: read `bindings/rust/src/connection.rs`; output how `query`, `execute`, `execute_batch`, and `prepare` differ.
- [ ] T023. **Rows and Row API**: read `bindings/rust/src/rows.rs`, `bindings/rust/src/value.rs`; output how row iteration hides `Statement::step`.
- [ ] T024. **Parameter conversion**: read `bindings/rust/src/params.rs`; output how Rust values become SQL parameters.
- [ ] T025. **Rust transaction wrapper**: read `bindings/rust/src/transaction.rs`; output how a high-level transaction maps to SQL or core state.
- [ ] T026. **SDK kit Rust API**: read `sdk-kit/src/rsapi.rs`; output where SDK kit wraps core `Database`, `Connection`, and `Statement`.
- [ ] T027. **SDK kit C ABI types**: read `sdk-kit/src/bindings.rs`, `sdk-kit/src/capi.rs`; output how FFI-safe handles represent database objects.
- [ ] T028. **Core OpenOptions**: read `core/lib.rs`; output each option that changes storage, WAL, sync, encryption, or temp behavior.
- [ ] T029. **Database open path**: read `core/lib.rs`; output the phases of opening a database and validating the header.
- [ ] T030. **Database registry**: read `core/lib.rs`; output why database identity and registry state matter for shared files.
- [ ] T031. **Connection construction**: read `core/connection.rs`; output which shared objects a `Connection` holds after opening.
- [ ] T032. **Prepare public API**: read `core/connection.rs`; output the chain from `prepare` to internal preparation.
- [ ] T033. **Prepare origin**: read `core/statement.rs`, `core/connection.rs`; output why statements need an origin and when origin affects behavior.
- [ ] T034. **Prepare with schema reparse**: read `core/connection.rs`; output how schema race or stale schema forces retry.
- [ ] T035. **Nested statement guard**: read `core/connection.rs`; output why nested prepare/execute needs explicit bookkeeping.
- [ ] T036. **Parse dispatch from core**: read `core/dialect/mod.rs`, `core/dialect/sqlite.rs`; output why parser access goes through a dialect trait.
- [ ] T037. **Compile handoff**: read `core/connection.rs`, `core/translate/mod.rs`; output what information crosses from prepare into translate.
- [ ] T038. **PreparedProgram split**: read `core/vdbe/mod.rs`; output why `PreparedProgram` and runtime `Program` are separate.
- [ ] T039. **Statement structure**: read `core/statement.rs`; output fields that track bindings, status, columns, interrupted state, and execution state.
- [ ] T040. **Statement metadata**: read `core/statement.rs`, `tests/integration/statement_metadata.rs`; output how column name and type metadata is inferred.
- [ ] T041. **Binding parameters in core**: read `core/parameters.rs`, `core/statement.rs`; output how numbered and named SQL parameters are stored.
- [ ] T042. **Statement step wrapper**: read `core/statement.rs`; output the guard checks before VDBE execution starts.
- [ ] T043. **StepResult boundary**: read `core/vdbe/mod.rs`, `core/statement.rs`; output how `Row`, `Done`, `IO`, and error results flow to callers.
- [ ] T044. **Reset and reuse**: read `core/statement.rs`, `tests/integration/statement_reset.rs`; output when a statement can be rerun and which state must be cleared.
- [ ] T045. **Entry API milestone**: trace `prepare("SELECT ?")`, bind one value, step once; output a source-coordinate trace from binding API to `Program::step`.

