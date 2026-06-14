#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 Shared Script Utilities

Common functions used across all regression scripts.
Modeled after ibex's scripts_lib.py, adapted for eh2-veri.
"""

import os
import shlex
import subprocess
import sys
import pickle
import yaml
from pathlib import Path
from typing import Dict, List, Optional, Union


def run_one(verbose: bool, cmd: List[str],
            redirect_stdstreams: Optional[Union[str, Path]] = None,
            timeout_s: Optional[int] = None,
            env: Optional[Dict[str, str]] = None) -> int:
    """Run a command, returning its retcode.

    Args:
        verbose: If True, print the command to stderr (like bash -x).
        cmd: Command as list of strings.
        redirect_stdstreams: Path to redirect stdout/stderr to.
        timeout_s: Timeout in seconds.
        env: Optional environment variables.

    Returns:
        Process return code.
    """
    stdstream_dest = None
    needs_closing = False

    if redirect_stdstreams is not None:
        if str(redirect_stdstreams) == '/dev/null':
            stdstream_dest = subprocess.DEVNULL
        elif isinstance(redirect_stdstreams, (str, Path)):
            stdstream_dest = open(redirect_stdstreams, 'wb')
            needs_closing = True

    cmd_str = ' '.join(shlex.quote(w) for w in cmd)
    if verbose:
        print('+ ' + cmd_str, file=sys.stderr)
        if stdstream_dest and stdstream_dest != subprocess.DEVNULL:
            try:
                print('+ ' + cmd_str, file=stdstream_dest)
            except (TypeError, AttributeError):
                pass

    try:
        ps = subprocess.run(cmd,
                            stdout=stdstream_dest,
                            stderr=stdstream_dest,
                            close_fds=False,
                            timeout=timeout_s,
                            env=env)
        return ps.returncode
    except subprocess.CalledProcessError:
        return 1
    except OSError as e:
        print(e, file=sys.stderr)
        return 1
    except subprocess.TimeoutExpired:
        print(f"Error: Timeout[{timeout_s}s]: {cmd_str}", file=sys.stderr)
        return 1
    finally:
        if needs_closing and stdstream_dest not in (None, subprocess.DEVNULL):
            stdstream_dest.close()


def format_to_cmd(input_arg: Union[str, List]) -> List[str]:
    """Format a list of mixed types into list of strings for subprocess."""
    cmd_list = []
    for item in input_arg:
        cmd_list.append(format_to_str(item))
    return cmd_list


def format_to_str(arg) -> str:
    """Format a single argument to string."""
    if isinstance(arg, Path):
        return str(arg.resolve())
    if arg is None:
        return ''
    return str(arg)


def subst_opt(string: str, name: str, replacement: str) -> str:
    """Substitute <name> placeholder in string with replacement."""
    needle = f'<{name}>'
    if needle in string:
        return string.replace(needle, replacement)
    return string


def subst_dict(string: str, var_dict: Dict[str, Union[str, Path]]) -> str:
    """Apply substitutions from var_dict to string."""
    for key, value in var_dict.items():
        if isinstance(value, Path):
            string = subst_opt(string, key, str(value.resolve()))
        else:
            string = subst_opt(string, key, value)
    return string


def read_yaml(yaml_file: Path) -> dict:
    """Read YAML file to a dictionary."""
    with open(yaml_file, 'r', encoding='utf-8') as f:
        try:
            yaml_data = yaml.safe_load(f)
        except yaml.YAMLError as exc:
            print(f"YAML error: {exc}", file=sys.stderr)
            sys.exit(1)
    return yaml_data


def pprint_dict(d: dict, output) -> None:
    """Pretty-print a dictionary as valid YAML."""
    klen = 1
    for k in d.keys():
        klen = max(klen, len(str(k)))

    for k, v in d.items():
        kpad = ' ' * (klen - len(str(k)))
        val_str = _yaml_value_format(v)
        output.write(f'{k}:{kpad} {val_str}\n')


def _yaml_value_format(val) -> str:
    """Format a value for YAML output."""
    if isinstance(val, str) and any(c in val for c in ['[', ']', ':', "'", '"', '\n']):
        lines = val.split('\n')
        return '|\n' + '\n'.join([f'  {line}' for line in lines])
    if val is None:
        return ''
    return str(val)


def format_dict_to_printable_dict(arg: dict) -> dict:
    """Convert all dictionary values to strings."""
    clean_dict = {}
    for k, v in arg.items():
        if isinstance(v, dict):
            clean_dict[k] = str(v)
        elif isinstance(v, list):
            clean_dict[k] = ' '.join([format_to_str(item) for item in v])
        elif isinstance(v, Path):
            clean_dict[k] = str(v.resolve())
        else:
            clean_dict[k] = format_to_str(v)
    return clean_dict


class TestdataCls:
    """Base class for test data persistence (pickle + YAML export)."""

    pickle_file: Optional[Path] = None
    yaml_file: Optional[Path] = None

    @classmethod
    def construct_from_pickle(cls, metadata_pickle: Path):
        """Construct object from a pickle file."""
        with open(metadata_pickle, 'rb') as handle:
            obj = pickle.load(handle)
        return obj

    def export(self, write_yaml: bool = False):
        """Write object to disk as pickle (and optionally YAML)."""
        if not self.pickle_file:
            raise RuntimeError("pickle_file not set")
        self.pickle_file.parent.mkdir(parents=True, exist_ok=True)
        with open(self.pickle_file, 'wb') as handle:
            pickle.dump(self, handle)

        if write_yaml and self.yaml_file:
            self.yaml_file.parent.mkdir(parents=True, exist_ok=True)
            with open(self.yaml_file, 'w') as handle:
                pprint_dict(self.format_to_printable_dict(), handle)

    def format_to_printable_dict(self) -> dict:
        """Return a printable dict of the object."""
        from dataclasses import asdict
        return format_dict_to_printable_dict(asdict(self))
