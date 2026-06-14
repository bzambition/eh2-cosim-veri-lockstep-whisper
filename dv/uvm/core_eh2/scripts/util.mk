# SPDX-License-Identifier: Apache-2.0
# Small make utilities shared by wrapper.mk.

ifeq ($(VERBOSE),1)
verb :=
else
verb := @
endif

.PHONY: dump-vars
dump-vars:
	@echo "OUT-DIR=$(OUT-DIR)"
	@echo "METADATA-DIR=$(METADATA-DIR)"
	@echo "SIMULATOR=$(SIMULATOR)"
	@echo "TEST=$(TEST)"
