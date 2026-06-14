# SPDX-License-Identifier: Apache-2.0
# Ibex-compatible metadata accessor for EH2 wrapper.mk.

define get-metadata-variable
    env PYTHONPATH=$(PYTHONPATH) python3 ./scripts/metadata.py \
    --op "print_field" \
    --dir-metadata $(METADATA-DIR) \
    --field $(1)
endef
define get-meta
    $(shell $(call get-metadata-variable,$(1)))
endef
