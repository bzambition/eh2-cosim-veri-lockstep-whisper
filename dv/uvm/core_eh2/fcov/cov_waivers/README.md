# Coverage Waivers

This directory contains documented waivers for functional coverage points
that are known to be unreachable, architecturally blocked, or impractical
to hit in simulation.

## Purpose

Coverage waivers allow the verification team to close coverage gaps that
are understood and accepted. Each waiver documents *what* is waived, *why*
it cannot or should not be covered, and *who* approved it.

Without waivers, these gaps would block signoff or require expensive,
low-value directed tests.

## File Naming Convention

Use lowercase snake_case with a descriptive suffix:

```
<description>_waiver.yaml
```

Examples:
- `dual_issue_presync_stall_cross_waiver.yaml`
- `nmi_during_debug_cross_waiver.yaml`

## Waiver Format

Each waiver is a standalone YAML file with the following fields:

```yaml
waiver:
  name: "Human-readable description"
  coverage_point: "covergroup.coverpoint_or_cross"
  reason: "Why this coverage point is waived"
  author: "Name of person who reviewed and approved"
  date: "YYYY-MM-DD"
  ticket: "Tracking issue URL or ID (empty string if none)"
  status: "active"   # active | superseded | withdrawn
```

### Field Details

| Field           | Required | Description                                              |
|-----------------|----------|----------------------------------------------------------|
| `name`          | Yes      | Short description of the waived coverage                 |
| `coverage_point`| Yes      | Dot-separated path: `covergroup.coverpoint_or_cross`     |
| `reason`        | Yes      | Technical justification for the waiver                   |
| `author`        | Yes      | Person who approved the waiver                           |
| `date`          | Yes      | Date the waiver was created (YYYY-MM-DD)                 |
| `ticket`        | No       | Link to tracking issue; use `""` if none                 |
| `status`        | No       | Defaults to `active`; set to `withdrawn` to deactivate   |

## Usage in Testbench

The `eh2_cov_waiver_pkg` SystemVerilog package provides functions to load
and query waivers at runtime:

```systemverilog
import eh2_cov_waiver_pkg::*;

// Load all waivers from the directory
load_waivers("path/to/cov_waivers/");

// Check if a specific point is waived
if (is_waived("uarch_cg.stall_cross"))
  $display("stall_cross is waived");
```

## Adding a New Waiver

1. Create a new `.yaml` file following the naming convention above.
2. Fill in all required fields with a clear technical reason.
3. Get review approval from at least one verification lead.
4. The waiver is active immediately; no code changes needed.
