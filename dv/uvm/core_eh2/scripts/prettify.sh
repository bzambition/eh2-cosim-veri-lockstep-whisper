#!/usr/bin/env bash
# Format trace_core*.log files into aligned columns for readability.
# Usage: ./scripts/prettify.sh [search_root]
#   search_root defaults to current directory

_SEARCH_ROOT="${1:-.}"
_GET_TRACES=$(find "$_SEARCH_ROOT" -type f -iregex '.*trace_core.*\.log')

for trace in $_GET_TRACES; do
    column -t -s $'\t' -o ' ' -R 1,2,3,4,5 "$trace" > "$(dirname "$trace")"/trace_pretty.log
done
