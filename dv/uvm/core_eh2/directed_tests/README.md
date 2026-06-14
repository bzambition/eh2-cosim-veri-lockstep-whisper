# EH2 Directed Tests

This directory contains custom directed tests plus scripts and headers for
running vendored open-source test suites against the EH2 core.

## Contents

- `eh2_macros.h` - EH2-specific constants (signature addresses, core status
  codes, ePMP CSR definitions)
- `custom_macros.h` - Assembly macros for PMP testing (region setup, mode
  switching, access helpers)
- `link.ld` - Linker script for directed tests (base address 0x80000000)
- `gen_testlist.py` - Script to generate `directed_testlist.yaml` from vendored
  test suites
- `directed_testlist.yaml` - Generated test list (do not edit manually)

## Vendored Test Suites

The following test suites are vendored under `../../vendor/`:

- **riscv-tests** - RISC-V ISA tests (rv32mi, rv32uc, rv32ui, rv32um)
- **riscv-arch-tests** - RISC-V architecture compliance tests
- **epmp-tests** - ePMP (enhanced Physical Memory Protection) tests from
  riscv-isa-sim

## Generating the Test List

To generate the full directed test list with all vendored suites:

```bash
python3 gen_testlist.py --add_tests riscv-tests,riscv-arch-tests,epmp-tests
```

Individual suites can be selected:

```bash
python3 gen_testlist.py --add_tests riscv-tests
python3 gen_testlist.py --add_tests riscv-arch-tests,epmp-tests
```

## Adding Custom Directed Tests

Custom directed tests must be added in `gen_testlist.py` within the
`add_configs_and_handwritten_directed_tests()` function. Each test entry
should specify:

- `test` - unique test name
- `desc` - description
- `iterations` - number of iterations (typically 1)
- `test_srcs` - path to test source file(s)
- `config` - configuration to use (e.g., `riscv-tests`)
- `gcc_opts` - (optional) override default compiler options
