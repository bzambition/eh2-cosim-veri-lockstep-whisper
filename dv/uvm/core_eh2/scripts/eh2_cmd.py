#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""EH2 configuration helpers for the Ibex-style DV flow."""

from pathlib import Path
from typing import Dict, Tuple

import yaml

import setup_imports


def get_config(config_name: str) -> Dict:
    """Return one EH2 configuration from eh2_configs.yaml."""
    cfg_path = setup_imports._EH2_ROOT / "eh2_configs.yaml"
    with open(cfg_path, "r", encoding="utf-8") as f:
        configs = yaml.safe_load(f) or {}
    if config_name not in configs:
        raise KeyError(
            "Unknown EH2 config '{}'; available: {}".format(
                config_name, ", ".join(sorted(configs))))
    params = dict(configs[config_name].get("parameters", {}) or {})
    return {
        "name": config_name,
        "description": configs[config_name].get("description", ""),
        "parameters": params,
    }


def get_isas_for_config(cfg: Dict) -> Tuple[str, str]:
    """Return GCC and ISS ISA strings for one EH2 configuration."""
    params = cfg.get("parameters", {})
    base = "rv32imac"
    bitmanip = [
        name for name, enabled in [
            ("zba", params.get("BITMANIP_ZBA", 0)),
            ("zbb", params.get("BITMANIP_ZBB", 0)),
            ("zbc", params.get("BITMANIP_ZBC", 0)),
            ("zbs", params.get("BITMANIP_ZBS", 0)),
        ]
        if int(enabled)
    ]
    if bitmanip:
        return (base + "_zba_zbb_zbc_zbs", base + "_" + "_".join(bitmanip))
    return (base, base)


def render_compile_defines(config_name: str) -> str:
    """Render Verilog defines for simple simulator command integrations."""
    cfg = get_config(config_name)
    defines = []
    for key, value in sorted(cfg["parameters"].items()):
        if isinstance(value, int):
            defines.append("+define+{}={}".format(key, value))
    return " ".join(defines)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="EH2 config helper")
    parser.add_argument("config", nargs="?", default="default")
    parser.add_argument("--defines", action="store_true")
    args = parser.parse_args()

    if args.defines:
        print(render_compile_defines(args.config))
    else:
        print(get_config(args.config))
