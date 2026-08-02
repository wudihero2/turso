# Turso Learn-codebase Implementation Tasks

這個 `tasks/` 目錄不是給人類直接讀源碼的清單，也不是用來設計 toy database 或簡化版 SQLite。它是給後續 agent 依序把 Turso 現有實作重建到 `learn-codebase/` 的任務規格。每個 task 都必須以 Turso 現有 source 為實作本體，並以 `learn/*` 作為理解背景；全部 task 完成後，`learn-codebase/` 的架構、資料結構、演算法、行為、feature scope、錯誤邊界、invariant 與測試都必須和指定版本的 Turso 一致。

學習效果來自「把同一份 Turso 實作依相依關係切成細小步驟」，不是來自刪減或改寫 Turso。

## Source snapshot 與範圍

- 本清單鎖定 repository commit `d7370df0170763e8a8a0db4542a1a181372b8895`（2026-07-31 checkout）。`Source basis`、symbol 分組、feature scope與原測試都以這個 revision 為準。
- 範圍包含 root `Cargo.toml` 的所有 workspace members，也包含 repository 內不是 Cargo member 的正式套件與介面，例如 Go、React Native、.NET、serverless language drivers、Turso 自有 benchmarks/perf harnesses、runnable examples 與實作用 scripts。`perf/`、`benches/`、`benchmarks/`、`examples/` 中的 source、test、runtime resource與 build definition 不得用目錄規則繞過 learning tasks；只有 lock/generated/binary 與明確文件等依 manifest 同步或排除。
- 若 production revision 改變，先用 Git diff 逐檔檢查新增/刪除/搬移的 source、tests、feature gates與 public APIs，再更新 task；不能把舊 task 直接套到新 revision後仍聲稱一比一。
- task 編號全域連續；章節順序是 source 的學習與搬移順序。章末 milestone 是該章 source/test coverage audit，但若測試仍缺後續 dependency，可以保持未勾選並在相依完整後回來驗證，不阻擋後續 production source task。

核心原則：

- 先做資料庫的內部骨架，不先做 API。API、binding、CLI 放到後面。
- 每個任務的大小，以 agent 完成實作與短說明後，人類可以在一小時左右理解該段程式碼為準。agent 的實作時間不限制為一小時。
- 多檔案或 directory-based task 在鎖定 revision 展開後最多六個檔案。每個 source task 的實際擁有範圍相加最多 300 行且最多 4 個 `SourceUnits::Unit`，不得用「檔案總行數除以 owner 數」估算。大型檔案必須以 `Source slices: path:Lx-Ly` 記錄完整、不重疊且無缺口的鎖定範圍，並只在完整 Rust item/method、match arm 或 state-machine stage、完整 SQLtest/TCL case、scope-aware 非 Rust function/test、build/resource group、snapshot opcode row 或其他明確資料邊界切分。行數只是防止粗切的上限；task 描述仍必須說明實際 symbol、test scenario、opcode、state-machine 或資料 section 邊界，不能寫成「第 N 批」。
- 每個 source task 都必須寫 `Source units: N`；`N` 必須等於 `tasks/source_units.rb` 對該 slice 實際產生的 `SourceUnits::Unit` 數，不能拿 labels 數量代替。
- task 是 Turso 原始碼的理解與重建單位，不要求每個 task 自己形成一個縮小後的獨立功能；可執行能力由多個 task 依照原始相依關係逐步累積。
- 任務完成後，人類要能讀 `learn-codebase/*` 的程式碼，感受到 database 是一層一層長出來的。
- 不得自行創造新的資料庫設計、演算法、替代實作或相容層。程式碼必須直接取自 `Source basis` 指定的 Turso source。
- 不得縮小支援範圍、改名、改寫、簡化、省略或用 stub 取代 Turso 的實作。
- 必須保留 Turso 的 struct、enum、trait、function、module 邊界、狀態機分段、錯誤邊界、invariant 與行為。
- `learn-codebase/` 必須保留 Turso 原本的 crate、目錄與 module 相對結構，使 production source 不需要改名或改寫。教學解釋寫在獨立 task note，不以重寫 production source 的方式製作「教學版」。
- source task 可以先忠實搬入指定切片，即使後續 dependency 尚未搬入，導致當下無法 compile 或執行測試。不得為了讓中間狀態提早可執行而刪除功能、改寫邏輯、增加 stub 或建立簡化替代品。
- 尚未輪到的 source slice 暫時不存在，是 task 排程中的中間狀態，不代表允許永久省略；learning inventory 內的每一段 Turso production source、原測試與必要 build definition 都必須被後續 task 明確涵蓋，並在最終 milestone 前完整搬入。
- `Source basis` 指向 directory 時，只展開該目錄中屬於 learning inventory 的 production source、原測試與必要 build definition，不把其他 Git blob 偷渡成學習 task。
- learning inventory 先依檔案角色納入 production/test/benchmark/example 語言 source、空的 package marker、可執行 script、Turso 自有 SQL/SQLtest/TCL corpus、golden output、文字 fixture/snapshot/patch、runtime resource，以及 Cargo/npm/Python/Go/Gradle/.NET/CMake 等 build definition；再從這些檔案的實際路徑引用做 reference closure。副檔名白名單不是唯一依據。精確分類由 `tasks/learning_inventory.rb` 定義。
- 不屬於 learning inventory 的每個 blob 都必須出現在 `tasks/sync-only-manifest.tsv`。先套用 agent config、文件與其他既有 exclude policy；其餘 in-scope locked Git symlink 才是 `copy` entry，由同步器建立並保留 target bytes，不得生成一般文字 source task 或 `Source slices`。開始 T001 前執行 `ruby tasks/sync-codebase.rb learn-codebase`，從鎖定 commit 一次建立所有 `copy` entry；此命令保持 blob bytes、symlink target與 executable mode，並拒絕 symlink target root或任何 symlink parent directory。`exclude` entry 必須保留具體 exclude reason。README、CHANGELOG、一般文件、license、editor/swap file 等不建立學習 task；generated/lock/binary、匯入的 `sqlite/conformance/upstream/` corpus與第三方 SQLite headers則依 manifest 原樣同步，不能靠「需要時」選擇性略過。`tasks/verify-sync-closure.rb` 只讀檢查全部 learning source 與 manifest copy 的 locked bytes、Git file type及 executable mode，也要求 target root與每個 reconstructed path的所有父目錄都是實體 directory，不負責補同步。
- 鎖定 revision 的 production source 是唯一權威；`learn/*` 只提供理解背景。執行 task 前若 `bash learn/lint-learn-docs.sh` 失敗或 learn 內容與 source 衝突，必須先校正 learn 文件，不能依舊說明改寫 production code。

維護 task 清單後依序執行 `ruby tasks/generate-sync-manifest.rb`、`ruby tasks/rebuild-task-slices.rb` 與 `ruby tasks/lint-task-sources.rb`。重建器會把 runtime resource、golden、fixture與 config 放在 paired source 後或 first reference／同 package source 前，並由實際 milestone task 重建 README 的整段里程碑摘要。檢查直接讀鎖定 commit 的 blobs、root workspace members 與遞迴 local path dependencies，不使用目前 checkout 的 Cargo metadata。它會驗證全域連號、完整 repository-root 路徑、每 task 最多六個檔案、實際擁有範圍相加最多 300 行與 4 個結構單元、描述中的 `Source units` 精確等於實際單元數、切片符合完整語法/test/resource boundary、resource 位於 paired source／first reference 的同一 milestone 內、每個 README milestone ID 確實存在且類型正確、workspace 與 Turso-owned benchmark/example source 沒有被 inventory 規則繞過、每個 learning source 的唯一 owner、一般 source task不得解析成零個檔案、每個 in-scope locked symlink 都只能由 manifest `copy` 擁有，以及 sync manifest 完整且 disposition 沒有漂移。只有明確標記 `Task kind: milestone` 或 `Task kind: verification` 的 task 可以沒有新 source。這一版已把所有 verification 紀錄併入 source owner，不另排空 task；若未來真的新增 verification-only task，動作必須以「驗證」開頭、引用較早 owner，並產出 source→target mapping 與 deferred-test 狀態。鎖定 revision 的精確 learning、workspace、package/tool與 sync-only 數量以重建器及 lint 當次輸出為準，不能手動維護一組會漂移的數字。

任務中的 `Target` 是未來實作位置，通常還不存在。`Source basis` 是該 task 必須忠實搬移的 Turso production source、對應測試，以及協助理解的 `learn/*` 文件；它不是只供參考的延伸閱讀。

## 給後續 agent 的硬規則

每個 task 都必須先打開並讀完 `Source basis`，再把指定的 Turso 程式碼忠實搬到 `learn-codebase/`。對應 Turso 測試可以在相依程式碼完整後，由指定的 test task 或 milestone 原封不動搬入並執行。parser、B-tree、pager、VM、planner、WAL、I/O、transaction、extension 與其他模組都不得另行設計。這個專案的學習方式是「靠 agent 依序重建同一份 Turso codebase」。

必要流程：

1. 讀 task 指定的全部 Turso production source、對應 Turso 測試與 `learn/*`。
2. 確認要搬移的完整 symbol、相依項、feature gate、狀態轉換、錯誤路徑與 invariant。
3. 將指定程式碼忠實搬到 `learn-codebase/*`，不改變名稱、結構、邏輯或支援範圍。
4. 在 task note 記錄 Turso source 與 `learn-codebase/*` 的逐項對應；若當下尚不能驗證，列出原 test source、缺少的 dependency 與預定驗證 milestone。
5. production source task 不要求當下 compile 或通過測試。指定切片已忠實搬入、沒有改名改寫，且 deferred verification 已明確記錄後即可勾選。
6. 到指定 test task 或 milestone 時，原封不動搬入 Turso 原本的測試，保留測試情境、輸入、assertion 與預期結果；不得自行創造替代測試或 isolated test。
7. test task 或 milestone 若因 dependency 尚未完整而無法執行，保持未勾選並繼續後續 source task，待相依完整後再回來執行。
8. 原測試失敗時，補齊缺少的 Turso source 與相依實作，不得用 stub、ignore、刪除 assertion、修改 expected result 或降低測試範圍來通過。
9. 最終 milestone 完成前，所有排程內的 production source、原測試、benchmarks/examples與 build metadata 都必須完整搬入，所有適用的原測試都必須實際通過；開始 T001 前已由 `ruby tasks/sync-codebase.rb learn-codebase` 建立的 sync-only copy 不在 final milestone 手工補搬。final 執行 `ruby tasks/verify-sync-closure.rb learn-codebase`，逐項只讀核對全部 learning source與 manifest copy的 locked bytes、Git file type、symlink target及 executable mode，確認 target root與所有 parent directory都不是 symlink，並確認所有 `exclude` 理由仍保留。

## 實作順序

1. `00-parser.md` (T001–T286): SQLite lexer/token/AST/parser/formatter與原 parser tests。
2. `01-values-schema-records.md` (T287–T509): runtime values、schema catalog、SQLite records與 catalog replay。
3. `02-page-pager.md` (T510–T951): allocator/error、IOResult/completions、platform I/O、header/page/cache/pager。
4. `03-btree-cursor.md` (T952–T1115): production B-tree cursor、seek/scan/write/delete/overflow/balance。
5. `04-bytecode-vm.md` (T1116–T1737): complete instruction enum、program/register/cursors、interpreter與所有 opcode families。
6. `05-compiler-basic-sql.md` (T1738–T2344): dialect/prepare、production Plan/planner skeleton、main loop與完整 core CRUD compiler。
7. `06-expressions-functions.md` (T2345–T3351): affinity/value semantics、functions、expressions、aggregate/sorter/subquery/CTE/window。
8. `07-indexes-planner.md` (T3352–T3662): index DDL/DML/statistics與完整 production optimizer passes。
9. `08-transactions-wal-io.md` (T3663–T3892): transaction/savepoint/statement journal、WAL/shared coordination/checkpoint/re-entry。
10. `09-sql-features.md` (T3893–T4399): remaining SQL features、vtab/JSON/vector/index methods/custom types/CDC。
11. `10-interfaces-extensions-testing.md` (T4400–T11505): remaining core support/collections、all bindings/drivers、SDKs、CLI、extensions 與 test/differential tools。
12. `11-advanced-systems.md` (T11506–T13303): MVCC、incremental views、sync、PostgreSQL、deterministic/concurrent simulation。

## Task 完成標準

production source task 完成時，後續 agent 應該提交：

- `learn-codebase/*` 中該 task 指定的完整 Turso 實作切片。
- 一段短註解或 markdown，列出 production source、完整 symbol 範圍與搬入位置的精確對應。
- 與 Turso 相同的 feature scope、公開介面、名稱、錯誤行為、狀態轉換與 invariant。
- 若尚未測試，列出對應的 Turso test source、目前缺少的 dependency 與之後負責驗證的 task/milestone。無法 compile 或尚未測試不阻止 source task 完成。

本版不另設 verification-only task。source task 的 task note 就是 verification 紀錄：必須包含 owner source 到 target 的精確 mapping，以及 deferred-test ledger 的狀態；缺少任一項就不能勾選 source task。不得用另一個 task 再次宣稱搬入同一份 source。

test task 或 milestone 完成時，後續 agent 應該提交：

- Turso 原始碼中對應的 unit test、integration test、SQL test 或其他既有測試；不得自創測試案例取代它們。
- 測試與 production source 的精確對應，以及先前 deferred verification 的關閉紀錄。
- 所有該 milestone 適用的原測試均通過，且沒有以 ignore、刪除 assertion、修改 expected result、stub 或簡化行為規避失敗。

test task 或 milestone 可以在編號順序走到時保持未完成，等後續 dependency 搬入後再回來勾選；T13303 完成時不得留下任何 deferred verification。

## 里程碑

- T286: SQL lexer/token/AST/parser/formatter與 parser 原測試完整重建。
- T509: values/schema/catalog/record encoding-decoding與原測試完整重建。
- T951: allocator、error、IOResult/completion、platform I/O、header/page/cache/pager與原測試完整重建。
- T1115: B-tree/cursor/seek/scan/write/delete/overflow/balance與原測試完整重建。
- T1737: bytecode data model、program/cursors/sorter/hash及完整 opcode interpreter與原測試完整重建。
- T2344: dialect/prepare/Plan/planner skeleton/main loop與 CREATE/CRUD compiler及原測試完整重建。
- T3351: value semantics、functions/expressions、aggregate/order/subquery/compound/CTE/window與原測試完整重建。
- T3662: index DDL/DML/statistics與 optimizer constraints/access/cost/order/join/multi-index/rewrite及原測試完整重建。
- T3892: transaction/savepoint/statement journal、WAL/shared coordination/checkpoint、resumable I/O與 TLA+ model完整重建。
- T4399: constraints/FK/views/triggers/ALTER/ATTACH/PRAGMA/VACUUM/integrity/vtab/JSON/vector/index methods/custom types/CDC與原測試完整重建。
- T11505: remaining core support/skiplist/vtabs/blob、public APIs、所有 bindings/SDKs/serverless drivers、CLI/extensions/testing/differential tooling、Turso-owned benchmarks/perf harnesses/runnable examples與各自原 build/tests完整重建。
- T11949: MVCC transactions/cursors/durable logical log/recovery/checkpoint/yield injection與原測試完整重建。
- T12146: incremental/DBSP operators/compiler/materialized views/persistence與原測試完整重建。
- T12381: CDC tape/replay/lazy storage/sync engine/sync SDK kit與原測試完整重建。
- T12868: PostgreSQL parser/translator/frontend/catalog/session/COPY/wire server/client/CLI、golden outputs與原測試完整重建。
- T13303: final closure audit；確認 deterministic/concurrent simulators 與所有前置 learning tasks 已完成、2,400-file learning inventory 均有唯一 owner、`tasks/sync-codebase.rb` 已建立 169 個 copy、只讀 closure verifier 已核對全部 learning/copy locked bytes與 Git file type並拒絕 symlink root/parent、340 個 exclusion 均保留理由，且 deferred verification 清空。此 task 不搬入或補實作新 source。