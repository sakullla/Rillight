# Changelog

## 0.1.1

- Correct Profile 7 enhancement-layer extraction, frame retention and timestamp
  matching; support half-resolution FEL resampling and valid zero residuals.
- On Windows, use GPU color conversion when matched FEL metadata proves a zero
  residual. Nonzero residuals retain CPU composition; this is not general
  hardware FEL decoding.
- Enable zlib in every native SDK for compressed Matroska PGS tracks. Preserve
  subtitle canvas coordinates when video output is resized.
- Convert explicitly tagged BT.2020/PQ PGS palettes into the existing sRGB
  overlay space, retaining authored bitmap layout and alpha. Native HDR subtitle
  peak retention is not implemented.
- Let Windows audio output catch up after short, late TrueHD PCM blocks without
  sleeping between every discarded block.
- Skip redundant stream probing for complete Matroska VOD headers while keeping
  full probing for incomplete/live inputs.

Windows validation covers native regressions and a local 30-second P7/PGS
sample. Real-time FEL evidence applies to that sample's zero-residual frames.
The latest subtitle color changes remain unverified on physical macOS and
Android devices and in native HDR display output.
