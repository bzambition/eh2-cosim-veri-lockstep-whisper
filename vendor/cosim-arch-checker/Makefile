# Compiler settings
CC = g++
CFLAGS = -std=c++17 -Wall -Werror -fpic -Imon/mon_instr -Ibridge/std -Ibridge -Ienv -Ibridge/whisper/svdpi -Ibridge/whisper -I../rvvi/include/host/rvvi -Icac/src/lib -Icac/src
LDLIBS = 
LDFLAGS ?= -static-libstdc++ -static-libgcc

# Directories
SRC_DIR = .
BUILD_DIR = build
LIB_DIR = lib

# Source files
SRCS = $(shell find bridge cac env mon -name '*.cpp' -o -name '*.cxx' -o -name '*.cc')
$(info SRCS=$(SRCS))
OBJS = $(patsubst %.cc, $(BUILD_DIR)/%.o, $(patsubst %.cxx, $(BUILD_DIR)/%.o, $(patsubst %.cpp, $(BUILD_DIR)/%.o, $(SRCS))))
$(info OBJS=$(OBJS))
DEPS = $(OBJS:.o=.d)

# Library name and version
LIB_NAME = cosim

# Targets
.PHONY: all clean test

all: $(LIB_DIR)/lib$(LIB_NAME).so

clean:
	rm -rf $(BUILD_DIR)/* $(LIB_DIR)/*

$(LIB_DIR)/lib$(LIB_NAME).so: $(OBJS)
	$(CC) $(LDFLAGS) $(LDLIBS) -shared -Wl,-soname,lib$(LIB_NAME).so -o $@ $^

test: $(BUILD_DIR)/tests/cac_state_test $(BUILD_DIR)/tests/whisper_rvvi_test
	LD_LIBRARY_PATH=$(dir $(CC))../lib64:$(dir $(CC))../lib:$$LD_LIBRARY_PATH $(BUILD_DIR)/tests/cac_state_test
	LD_LIBRARY_PATH=$(dir $(CC))../lib64:$(dir $(CC))../lib:$$LD_LIBRARY_PATH $(BUILD_DIR)/tests/whisper_rvvi_test

$(BUILD_DIR)/tests/cac_state_test: tests/cac_state_test.cc cac/src/cacCore.cxx cac/src/info.cxx cac/src/memory.cxx cac/src/register.cxx
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ $^

$(BUILD_DIR)/tests/whisper_rvvi_test: tests/whisper_rvvi_test.cc bridge/whisper/whisper_rvvi.cpp bridge/whisper/whisper_client.cpp
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ $^

-include $(DEPS)

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.cc
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -MP -c -o $@ $<

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.cpp
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -MP -c -o $@ $<

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.cxx
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -MP -c -o $@ $<
