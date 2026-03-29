# AI-Postex Development Guide

## Project Overview

AI-Postex is a Cobalt Strike postex-kit project that embeds ONNX ML models into reflectively-loaded DLLs for on-target AI/ML post-exploitation. It provides two capabilities:

1. **credentialFinder** - BiLSTM (DeepPass-style) password classifier
2. **semanticSearch** - Distilled bge-base-en-v1.5 embedding model for natural-language semantic file search

The key architectural insight is using Windows ML APIs (WinRT `Windows.AI.MachineLearning`) from native C++ in reflectively loaded DLLs — enabling in-memory ONNX inference with zero disk artifacts.

## Architecture

```
ai-postex.cna              # Aggressor script - registers Beacon commands
credentialFinder/
  postex/postex/
    postexmain.cpp          # Entry point, model loading, directory walk, inference loop
    ai_model.h              # BiLSTM ONNX model as byte array
    ai_util.h / ai_util.cpp # Character encoding, tokenization, preprocessing
    rust.h                  # FFI declarations for Rust functions
  postex/rust-addons/
    src/lib.rs              # Text extraction (pdf_extract, textract) via FFI
  util/
    redux_deeppass/pytorch/ # PyTorch training pipeline for BiLSTM model
    data_generation/        # Dataset generation for training

semanticSearch/
  intelligence/
    intelligence_main.cpp   # Entry point, model decompression, loading, search dispatch
    intelligence_utils.cpp  # Tokenization (WordPiece + byte-level), embedding, cosine similarity,
                            # sliding window comparison, LZMS decompression, directory walk
    intelligence_debug.h    # Debug print macros
    rust.h                  # FFI declarations
  rust_addons/
    src/lib.rs              # Text extraction + vocab.txt embedding via include_bytes!
    vocab.txt               # WordPiece vocabulary for the embedding model
  scripts/
    bin2coff.py             # Convert binary to linkable COFF object
    model_to_onnx.py        # Model export/distillation pipeline

helpers/
  bin2smol/                 # Model compression utility

dist/                       # Pre-built DLLs (x86 + x64)
process_stats/              # Performance benchmarks
```

## Key Technologies

- **Windows ML / WinRT** (`Windows.AI.MachineLearning`) - ONNX model inference via OS-provided APIs
- **ONNX Runtime** (via Windows ML) - Model execution, opset 8 (credentialFinder) and opset 12 (semanticSearch)
- **C++/WinRT** - COM/WinRT projections for native C++
- **Rust FFI** - Document text extraction (pdf_extract, textract crates) linked as static libraries
- **Cobalt Strike postex-kit** - Reflective DLL loading, named pipe IPC, Beacon integration
- **LZMS compression** (Windows Compression API) - Model compression for the ~30MB embedding model
- **COFF object embedding** - Large model binary linked as COFF object at compile time

## Build Requirements

- Visual Studio with C++/WinRT support
- Rust toolchain (see `rust-toolchain.toml` in each rust-addons folder)
- Cobalt Strike Arsenal Kit (postex-kit headers: `beacon.h`, `dllmain.h`, `pipes.h`, `utils.h`, `macros.h`, `mock.h`, `debug.h`, `pch.h`)
- Windows 11 SDK (for Windows ML APIs and Compression API)

**Note:** Full source cannot be compiled without the Cobalt Strike Arsenal Kit due to licensing. The `dist/` folder contains pre-built DLLs.

## Development Patterns

### Model Integration Flow
1. Train model in Python (PyTorch)
2. Export to ONNX (`torch.onnx.export`)
3. For large models: compress with LZMS, convert to COFF with `bin2coff.py`
4. Embed in DLL (byte array for small models, COFF linkage for large ones)
5. At runtime: decompress if needed, load via `LearningModel::LoadFromStream`

### Text Extraction Flow
1. C++ identifies valid file extensions via `IsValidFile`
2. Calls Rust FFI `extract_text()` which handles PDF vs other formats
3. Returns heap-allocated CString, caller must free via `free_extracted_text()`

### Inference Flow (credentialFinder)
1. Extract text from file
2. Split into whitespace-delimited words
3. Encode each word to integer sequence (character-to-index mapping)
4. Create WinRT tensor, bind to model, evaluate
5. Compare output probability to threshold

### Inference Flow (semanticSearch)
1. Extract text from file
2. Tokenize with WordPiece or byte-level tokenizer
3. Create WinRT tensors (input_ids + offsets), bind, evaluate
4. Get sentence embedding (mean-pool if token-level output)
5. Compute cosine similarity against reference string embedding
6. Report if above threshold

## Working with This Codebase

- The project is partially open source. Arsenal Kit headers are referenced but not included.
- Python scripts in `util/` and `scripts/` are standalone — they run outside the DLL build.
- Rust crates build as static libraries linked into the final DLL.
- Debug builds (`_DEBUG`) use different argument parsing (direct string args vs BeaconDataParse).
- The `.cna` script handles argument packing and DLL selection (x86/x64).

## Testing

- Rust unit tests: `cargo test` in each `rust-addons/` directory
- DLL testing requires a Cobalt Strike teamserver or the postex-kit mock infrastructure
- Model training/evaluation: run Python scripts in `util/redux_deeppass/pytorch/`
- Performance monitoring: `scripts/performance_monitor.py`

## Code Style

- C++ uses Win32 conventions (BOOL, CHAR*, UCHAR*, goto Cleanup pattern)
- Heavy use of WinRT C++ projections (winrt::, auto, range-for)
- Rust code follows standard Rust conventions with `extern "stdcall"` FFI boundary
- Comments are thorough with doxygen-style documentation on public functions
