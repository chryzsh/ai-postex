#pragma once
// Raw bytes of BiLSTM ONNX model
// Placeholder — replace with actual model bytes exported from PyTorch.
// A single dummy byte prevents C2466 (zero-size array) so the project
// compiles without the real model.  The DLL will not produce valid
// inference results until this is replaced.
unsigned char modelBytes[] = { 0x00 };