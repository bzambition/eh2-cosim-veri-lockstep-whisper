#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Render EH2 riscv-dv configuration templates from regression metadata."""

import argparse
from pathlib import Path
import re
import sys

from metadata import RegressionMetadata
from eh2_cmd import get_config


TOKEN_RE = re.compile(r"\{\{\s*([A-Za-z0-9_]+)\s*\}\}")
IF_RE = re.compile(r"^\s*//%\s*if\s+([A-Za-z0-9_]+)\s*$")
ENDIF_RE = re.compile(r"^\s*//%\s*endif\s*$")


def render_template(config_name: str, template_filename: str) -> str:
    """Render a small token template using values from eh2_configs.yaml."""
    cfg = get_config(config_name)
    params = cfg["parameters"]
    text = Path(template_filename).read_text(encoding="utf-8")
    rendered_lines = []
    keep_stack = [True]

    for line in text.splitlines():
        if_match = IF_RE.match(line)
        if if_match:
            key = if_match.group(1)
            keep_stack.append(keep_stack[-1] and bool(int(params.get(key, 0))))
            continue
        if ENDIF_RE.match(line):
            if len(keep_stack) == 1:
                raise ValueError("Unexpected //% endif in {}".format(
                    template_filename))
            keep_stack.pop()
            continue
        if keep_stack[-1]:
            rendered_lines.append(line)

    if len(keep_stack) != 1:
        raise ValueError("Unclosed //% if block in {}".format(template_filename))
    text = "\n".join(rendered_lines) + "\n"

    def repl(match):
        key = match.group(1)
        if key == "CONFIG_NAME":
            return cfg["name"]
        if key not in params:
            raise KeyError(f"Unknown EH2 template key: {key}")
        return str(params[key])

    return TOKEN_RE.sub(repl, text)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("template_filename")
    parser.add_argument("--dir-metadata", type=Path, required=True)
    args = parser.parse_args(argv)

    md = RegressionMetadata.construct_from_metadata_dir(args.dir_metadata)
    sys.stdout.write(render_template(md.eh2_config, args.template_filename))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
