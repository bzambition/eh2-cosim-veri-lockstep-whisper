# Coverage Waivers

This directory contains coverage refinement and waiver files for the EH2 UVM
verification platform.

## Files

- `unr.vRefine` - Unreachable code refinement
- `aux_code.vRefine` - Auxiliary code refinement

## Usage

These files are consumed by the coverage merge and reporting tools:

```bash
# VCS coverage with waivers
urg -dir build/cov/simv.vdb -report build/cov_report -elfile waivers/unr.vRefine
```

## Adding New Waivers

1. Identify the coverage point that needs to be waived
2. Document the reason (architecturally unreachable, testbench limitation, etc.)
3. Add the waiver to the appropriate file
4. Reference the waiver in the coverage report
