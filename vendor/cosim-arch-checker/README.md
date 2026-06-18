# cosim-arch-checker

Core-agnostic RVVI-API checker facade for lockstep architectural comparison.
The SV side calls the standard RVVI API (`rvviApi.h` / `rvviApiPkg.sv`); this
library implements the reference and comparison functions and uses Whisper
(VeeR-ISS) as the reference backend.

## Architecture

```
DUT RVVI-TRACE
  -> generic SV scoreboard importing rvviApiPkg
  -> rvviDut*/rvviRef* DPI functions in this library
  -> Whisper server backend
```

The checker keeps comparison logic in C++:

- PC and instruction comparison
- written GPR comparison
- CSR comparison with external mask configuration
- staged memory-write comparison
- RVVI ref configuration and metric/error reporting

The checker does not own core-specific trace adaptation. Each core provides its
own RVVI-TRACE adapter and passes paths/configuration from the host testbench or
build system.

## Key Files

```
bridge/whisper/whisper_client.cpp   Whisper server socket client
bridge/whisper/whisper_rvvi.cpp     RVVI-API facade and Whisper backend
cac/src/                            Existing architecture state utilities
tests/                              C++ teeth tests for CSR/MEM/RVVI facade
```

## Configuration

The RVVI facade accepts runtime configuration from `rvviRefConfigSetString`:

- `1`: Whisper executable path
- `2`: Whisper JSON config path
- `3`: Whisper server-file path

Environment fallbacks are also supported for harnesses that cannot call the
configuration API:

- `WHISPER_PATH` or `WHISPER_RVVI_WHISPER_PATH`
- `WHISPER_RVVI_JSON_PATH` or `WHISPER_JSON_PATH`
- `CAC_CSR_MASK_FILE` for CSR compare masks

No repository-specific path is hardcoded in the checker.

## Build And Test

```
make all CC=<c++17 compiler>
make test CC=<c++17 compiler>
```

The tests intentionally inject CSR and memory mismatches. Their mismatch text in
stdout is expected and proves the checker still has teeth.
