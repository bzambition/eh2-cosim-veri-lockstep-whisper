#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 Directed Test Schema

Defines the schema for directed test configuration files.
Modeled after ibex's directed_test_schema.py.
"""

import sys
from pathlib import Path
from typing import List, Any, Optional
from dataclasses import dataclass, field

import scripts_lib

import logging
logger = logging.getLogger(__name__)


@dataclass
class DConfig:
    """Common configuration for building directed tests.

    Contains build information shared by multiple tests to encourage reuse.
    """
    config: str                  # Config name (each DTest must specify this)
    rtl_test: str                # UVM test class name
    rtl_params: dict = field(default_factory=dict)  # RTL parameters
    timeout_s: int = 300         # Simulation timeout
    gcc_opts: str = "-O2 -g -static -nostdlib -nostartfiles"
    ld_script: Optional[str] = None   # Linker script path
    includes: Optional[str] = None    # Include path


@dataclass
class DTest(DConfig):
    """A single directed test entry.

    Inherits from DConfig, adding test-specific fields.
    """
    test: str = ""               # Test name
    desc: str = ""               # Test description
    test_srcs: str = ""          # Test source file path
    iterations: int = 1          # Number of iterations


@dataclass
class DirectedTestsYaml:
    """Schema for the directed-tests.yaml file."""
    yaml_path: Path = None
    configs: List[DConfig] = field(default_factory=list)
    tests: List[DTest] = field(default_factory=list)


def import_model(directed_test_yaml: Path) -> DirectedTestsYaml:
    """Import and validate a directed test YAML file.

    Args:
        directed_test_yaml: Path to the YAML file.

    Returns:
        Validated DirectedTestsYaml object.
    """
    yaml_data = scripts_lib.read_yaml(directed_test_yaml)

    if not isinstance(yaml_data, list):
        logger.error(f"Expected a list in {directed_test_yaml}, got {type(yaml_data)}")
        sys.exit(1)

    configs = []
    tests = []

    for entry in yaml_data:
        if 'test' not in entry:
            # This is a config entry
            configs.append(DConfig(
                config=entry.get('config', ''),
                rtl_test=entry.get('rtl_test', ''),
                rtl_params=entry.get('rtl_params', {}),
                timeout_s=entry.get('timeout_s', 300),
                gcc_opts=entry.get('gcc_opts', '-O2 -g -static'),
                ld_script=entry.get('ld_script'),
                includes=entry.get('includes'),
            ))
        else:
            # This is a test entry - find matching config
            config_name = entry.get('config', '')
            matching_config = None
            for c in configs:
                if c.config == config_name:
                    matching_config = c
                    break

            if matching_config is None:
                logger.error(
                    f"Test '{entry['test']}' references config '{config_name}' "
                    f"which does not exist in {directed_test_yaml}")
                sys.exit(1)

            tests.append(DTest(
                config=matching_config.config,
                rtl_test=matching_config.rtl_test,
                rtl_params=matching_config.rtl_params,
                timeout_s=matching_config.timeout_s,
                gcc_opts=matching_config.gcc_opts,
                ld_script=matching_config.ld_script,
                includes=matching_config.includes,
                test=entry.get('test', ''),
                desc=entry.get('desc', ''),
                test_srcs=entry.get('test_srcs', ''),
                iterations=entry.get('iterations', 1),
            ))

    return DirectedTestsYaml(
        yaml_path=directed_test_yaml,
        configs=configs,
        tests=tests,
    )
