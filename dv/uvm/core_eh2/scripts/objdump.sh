#!/usr/bin/env bash
# Generate objdump disassembly for all test ELF files found in the output tree.
# Usage: ./scripts/objdump.sh [search_root]
#   search_root defaults to ./out/run

_SEARCH_ROOT="${1:-./out/run}"
_GET_OBJS=$(find "$_SEARCH_ROOT" -type f -iregex '.*test\.o')

if [[ -z "${RISCV_TOOLCHAIN}" ]]; then
   echo "Please define RISCV_TOOLCHAIN to have access to objdump."
   exit 1
fi

for obj in $_GET_OBJS; do
    "$RISCV_TOOLCHAIN"/bin/riscv32-unknown-elf-objdump -d "$obj" > "$(dirname "$obj")"/test.dump
done
