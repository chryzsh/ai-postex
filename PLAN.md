# AI-Postex Improvement Plan

## Context

After reviewing the ai-postex codebase (Cobalt Strike postex-kit with embedded ONNX ML models), several bugs, performance issues, and opportunities for new capabilities were identified. This plan covers bug fixes, performance improvements, and new use case implementations — all scoped to what can be done with the available partial source code (Arsenal Kit headers are not included).

---

## Phase 1: Bug Fixes (DONE)

### 1.1 Fix `SemanticSearchDirectoryContents` early abort on invalid files
- **File:** `semanticSearch/intelligence/intelligence_utils.cpp`
- **Bug:** When `IsValidFile()` returns FALSE, the function calls `FindClose(hFind)` and `return FALSE`, killing the entire directory walk. Should `continue` instead.
- **Also:** The `FindClose(hFind)` inside the loop body on the recursive subdirectory failure path is also wrong — the handle gets closed but the outer `while` loop continues using it. Both the subdirectory and invalid-file cases should just `continue`.
- **Status:** Fixed.

### 1.2 Fix model size calculation (pointer arithmetic)
- **File:** `semanticSearch/intelligence/intelligence_main.cpp`
- **Bug:** `SIZE_T model_size = model_onnx_smol_start - &model_onnx_smol_end;` has operands swapped. Should be `&model_onnx_smol_end - model_onnx_smol_start`.
- **Status:** Fixed.

### 1.3 Fix missing HeapFree for decompressed model buffer
- **File:** `semanticSearch/intelligence/intelligence_main.cpp`
- **Bug:** `DecompressData` allocates via `HeapAlloc` but the `decompressed_model` buffer is never freed after model loading completes.
- **Status:** Fixed.

---

## Phase 2: Performance Improvements (DONE)

### 2.1 Reuse LearningModelSession across inferences (credentialFinder)
- **File:** `credentialFinder/postex/postex/postexmain.cpp`
- **Issue:** `GetPasswordProbability` creates a new `LearningModelDevice` + `LearningModelSession` for every single word. These are expensive WinRT COM objects.
- **Fix:** Create session and device once in `PostexMain`, pass to `GetPasswordProbability` as parameters.
- **Status:** Fixed.

### 2.2 Cache `GenerateChars2Idx()` result
- **File:** `credentialFinder/postex/postex/ai_util.cpp`
- **Issue:** `EncodeWord` calls `GenerateChars2Idx()` every invocation, rebuilding the map from scratch each time.
- **Fix:** Made it a `static` local so it's computed once.
- **Status:** Fixed.

### 2.3 Use sliding window for semantic search on large documents
- **File:** `semanticSearch/intelligence/intelligence_utils.cpp`
- **Issue:** `SemanticSearchDirectoryContents` calls `SemanticComparison` (whole-document embedding) instead of `SemanticComparisonSliding` which already exists and handles localized matches better.
- **Fix:** Switched to `SemanticComparisonSliding`.
- **Status:** Fixed.

### 2.4 Cache reference embedding in semantic search
- **File:** `semanticSearch/intelligence/intelligence_utils.cpp`
- **Issue:** `SemanticComparison` re-embeds the reference string on every call. During a directory walk, the same reference is embedded once per file.
- **Fix:** Embed the reference once in `SemanticSearchDirectoryContents` and pass the pre-computed embedding vector through.
- **Status:** Fixed.

---

## Phase 3: Code Quality (NOT STARTED)

### 3.1 Deduplicate shared Rust code
- **Affected files:**
  - `credentialFinder/postex/rust-addons/src/lib.rs`
  - `semanticSearch/rust_addons/src/lib.rs`
- **Issue:** `extract_text`, `free_extracted_text`, and test code are copy-pasted between both modules.
- **Fix:** Extract shared Rust FFI code into a common crate (e.g., `shared/rust-common/`) and have both modules depend on it.

### 3.2 Deduplicate `IsValidFile` and `SplitBufferByWhitespace`
- **Affected files:**
  - `credentialFinder/postex/postex/postexmain.cpp`
  - `semanticSearch/intelligence/intelligence_utils.cpp`
- **Fix:** Move to a shared C++ header (e.g., `shared/common_utils.h`).

---

## Phase 4: New Capabilities (NOT STARTED)

### 4.1 API key / secret token classifier
- Retrain the BiLSTM with a dataset that includes API keys, JWTs, AWS keys, connection strings
- Extend to multi-class: password vs API key vs token vs benign
- Uses same credentialFinder DLL architecture, just a different model + updated encoding

### 4.2 Multi-query semantic search (document prioritization)
- Embed multiple reference queries at startup
- Score each document against all queries
- Report the best-matching query per document with its similarity
- Enables "search for network diagrams AND credentials AND VPN configs" in one pass

### 4.3 Registry / environment variable scanning
- Extend credentialFinder to enumerate registry hives (HKCU/HKLM) and environment variables
- Run the same BiLSTM classifier on registry value data
- New code path alongside the filesystem walker

### 4.4 DirectML GPU acceleration option
- Add runtime detection: try `LearningModelDeviceKind::DirectX`, fall back to CPU
- Significant speedup for semanticSearch on targets with GPUs

---

## Implementation Order

1. **Phase 1** (Bug fixes) — DONE
2. **Phase 2** (Performance) — DONE
3. **Phase 3** (Code quality) — refactoring, do after bugs/perf are solid
4. **Phase 4** (New capabilities) — larger scope, each is its own feature branch

## Verification

- **Bug fixes:** Code review against the correct patterns already in credentialFinder
- **Performance:** Compare against `process_stats/aggregate_performance.txt` baselines
- **Build:** Cannot fully build without Arsenal Kit; verify syntax/logic correctness via review
- **Rust changes:** `cargo check` in rust-addons directories (if toolchain available)
- **New capabilities:** Would require Windows 11 test environment with Cobalt Strike
