# Copyright (c) 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Paul Scheffler <paulsc@iis.ee.ethz.ch>
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>

# Toolchain
RISCV_XLEN    ?= 32
RISCV_MARCH   ?= rv$(RISCV_XLEN)im_zicsr #Default: i_zicsr
RISCV_MABI    ?= ilp32
RISCV_PREFIX  ?= riscv64-unknown-elf-
RISCV_CC      ?= $(RISCV_PREFIX)gcc
RISCV_CXX     ?= $(RISCV_PREFIX)g++
RISCV_OBJDUMP ?= $(RISCV_PREFIX)objdump
RISCV_OBJCOPY ?= $(RISCV_PREFIX)objcopy
RISCV_AS      ?= $(RISCV_PREFIX)as
RISCV_AR      ?= $(RISCV_PREFIX)ar
RISCV_LD      ?= $(RISCV_PREFIX)ld
RISCV_STRIP   ?= $(RISCV_PREFIX)strip

# Compiler and linker flags
# -ffunction-sections/-fdata-sections + --gc-sections let the linker drop
# unused functions/data per binary. print.c (printf), idma/gpio/clint/obi_timer
# are linked into every elf but most tests only use uart -> without GC they
# waste a big chunk of the 4K SRAM. With GC, each binary keeps only what it
# actually references.
#
# ORIGINAL (pre-GC) lines, kept for reference / easy revert:
#   RISCV_FLAGS ?= -march=$(RISCV_MARCH) -mabi=$(RISCV_MABI) -mcmodel=medany \
#       -static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding
#   RISCV_LDFLAGS ?= -static -nostartfiles -lm -lgcc $(RISCV_FLAGS)
# (i.e. drop "-ffunction-sections -fdata-sections" and "-Wl,--gc-sections" below)
RISCV_FLAGS ?= -march=$(RISCV_MARCH) -mabi=$(RISCV_MABI) -mcmodel=medany \
	-static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding \
	-ffunction-sections -fdata-sections
RISCV_CCFLAGS ?= $(RISCV_FLAGS) -Iinclude -I$(INCDIR) -I$(CURDIR)
RISCV_LDFLAGS ?= -static -nostartfiles -lm -lgcc -Wl,--gc-sections $(RISCV_FLAGS)


# Directory defaults
BINDIR   ?= bin
BUILDDIR ?= build
CRT0     ?= crt0.S
LINK     ?= link.ld
SRCDIR   ?= lib/src
INCDIR   ?= lib/inc

# Collecting source files
LIB_SOURCES  := $(wildcard $(SRCDIR)/*.[cS])
TOP_SOURCES  := $(filter-out $(CRT0), $(wildcard *.[cS]))
TEST_SOURCES := $(wildcard test/*.[cS])
PROG_SOURCES := $(TOP_SOURCES) $(TEST_SOURCES)

PROG_NAMES   := $(basename $(PROG_SOURCES))

# Creating object fiel list from source files
CRT0_OBJ  := $(BUILDDIR)/$(basename $(CRT0)).o
LIB_OBJS  := $(addsuffix .o, $(addprefix $(BUILDDIR)/, \
	         $(basename $(LIB_SOURCES))))
PROG_OBJS := $(addsuffix .o, $(addprefix $(BUILDDIR)/, \
	         $(basename $(PROG_SOURCES))))

# Everything to be built
ALL_TARGETS := $(PROG_NAMES:%=$(BINDIR)/%.elf) \
	           $(PROG_NAMES:%=$(BINDIR)/%.dump) \
	           $(PROG_NAMES:%=$(BINDIR)/%.hex)

# Dependency files for automatic rebuilds
DEPFILES := $(CRT0_OBJ:.o=.d) $(LIB_OBJS:.o=.d) $(PROG_OBJS:.o=.d)

# Ensure intermediate object files are not deleted after linking
.SECONDARY: $(CRT0_OBJ) $(LIB_OBJS) $(PROG_OBJS)

all: compile

$(BINDIR):
	mkdir -p $(BINDIR)

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

# Assembly to object compilation
$(BUILDDIR)/%.o: %.S
	mkdir -p $(dir $@)
	$(RISCV_CC) $(RISCV_CCFLAGS) -MMD -MP -c $< -o $@

# C to object compilation
$(BUILDDIR)/%.o: %.c
	mkdir -p $(dir $@)
	$(RISCV_CC) $(RISCV_CCFLAGS) -MMD -MP -c $< -o $@

# Linking
$(BINDIR)/%.elf: $(BUILDDIR)/%.o $(CRT0_OBJ) $(LIB_OBJS) $(LINK)
	mkdir -p $(dir $@)
	$(RISCV_CC) -o $@ $(filter-out $(LINK), $^) $(RISCV_LDFLAGS) -T$(LINK)

# Dump ELF data and disassembly
$(BINDIR)/%.dump: $(BINDIR)/%.elf
	mkdir -p $(dir $@)
	$(RISCV_OBJDUMP) -D -s $< >$@

# Convert ELF to hex format for easy loading into simulators or hardware
$(BINDIR)/%.hex: $(BINDIR)/%.elf
	mkdir -p $(dir $@)
	$(RISCV_OBJCOPY) -O verilog $< $@

# Phonies
.PHONY: all clean compile

clean:
	rm -rf $(BINDIR) $(BUILDDIR)

compile: $(BINDIR) $(BUILDDIR) $(ALL_TARGETS)

-include $(DEPFILES)
