rwildcard = $(foreach d, $(wildcard $1*), $(filter $(subst *, %, $2), $d) $(call rwildcard, $d/, $2))

CC := arm-none-eabi-gcc
AS := arm-none-eabi-as
LD := arm-none-eabi-ld
OC := arm-none-eabi-objcopy
OPENSSL := openssl

PYTHON := python
PYTHON_VER_MAJOR := $(word 2,$(subst ., ,$(shell $(PYTHON) --version 2>&1)))
ifneq ($(PYTHON_VER_MAJOR),2)
	PYTHON := python2
endif

PYTHON3 := python
PYTHON3_VER_MAJOR := $(word 3,$(subst ., ,$(shell $(PYTHON3) --version 2>&1)))
ifneq ($(PYTHON_VER_MAJOR),3)
	PYTHON3 := python3
endif

dir_source := source
dir_build := build
dir_out := out
dir_tools := p3ds
dir_patches := patches
dir_top := $(CURDIR)

ARM9FLAGS := -mcpu=arm946e-s -march=armv5te
ARM11FLAGS := -mcpu=mpcore
ASFLAGS := -mlittle-endian
CFLAGS := -MMD -MP -marm $(ASFLAGS) -fno-builtin -fshort-wchar -Wall -Wextra -O2 -std=c11 -Wno-main -I $(dir_source)/lib

revision := $(shell git rev-list HEAD --count)

get_objects = $(patsubst $(dir_source)/%.s, $(dir_build)/%.o, \
			  $(patsubst $(dir_source)/%.c, $(dir_build)/%.o, \
			  $(call rwildcard, $1, *.s *.c)))

objects_lib := $(call get_objects, $(dir_source)/lib)
objects_draw := $(dir_build)/mset_4x/draw.o $(dir_build)/mset_4x/memfuncs.o

objects_launcher := $(call get_objects, $(dir_source)/launcher)

objects_mset_4x := $(objects_draw) \
				   $(patsubst $(dir_build)/launcher/%, $(dir_build)/mset_4x/%, \
				   $(objects_launcher) $(objects_mset))
objects_mset_4x_dg := $(objects_draw) \
				   $(patsubst $(dir_build)/launcher/%, $(dir_build)/mset_4x_dg/%, \
				   $(objects_launcher) $(objects_mset))
objects_spider_4x := $(patsubst $(dir_build)/launcher/%, $(dir_build)/spider_4x/%, \
					 $(objects_launcher))
objects_spider_5x := $(patsubst $(dir_build)/launcher/%, $(dir_build)/spider_5x/%, \
					 $(objects_launcher))
objects_spider_9x := $(patsubst $(dir_build)/launcher/%, $(dir_build)/spider_9x/%, \
					 $(objects_launcher))

objects_cfw := $(objects_lib) $(call get_objects, $(dir_source)/cfw)

rops := $(dir_build)/mset_4x/rop.dat $(dir_build)/mset_4x_dg/rop.dat \
		$(dir_build)/spider_4x/rop.dat $(dir_build)/spider_5x/rop.dat \
		$(dir_build)/spider_9x/rop.dat

baked_files := $(patsubst $(dir_patches)/%/, $(dir_build)/patches/%.baked, $(wildcard $(dir_patches)/*/))

provide_files := $(dir_out)/firmware_bin.here \
				 $(dir_out)/slot0x25keyX_bin.here \
				 $(dir_out)/cakes/firmkey_bin.here

.PHONY: all
all: launcher patches

.PHONY: release
release: Cakes_$(revision).zip

.PHONY: launcher
launcher: $(dir_out)/Cakes.dat

.PHONY: patches
patches: $(baked_files)

.PHONY: clean
clean:
	rm -rf $(dir_out) $(dir_build) Cakes_$(revision).zip

$(dir_out)/%.here:
	@mkdir -p "$(@D)"
	touch $@

Cakes_$(revision).zip: launcher patches $(provide_files)
	sh -c "cd $(dir_out); zip -r ../$@ *"

# Throw everything together
$(dir_out)/Cakes.dat: $(rops) $(dir_build)/cfw/main.bin
	@mkdir -p "$(@D)"
	touch $@
	dd if=$(dir_build)/mset_4x/rop.dat of=$@
	dd if=$(dir_build)/mset_4x_dg/rop.dat of=$@ bs=512 seek=80
	dd if=$(dir_build)/spider_4x/rop.dat of=$@ bs=512 seek=144
	dd if=$(dir_build)/spider_5x/rop.dat of=$@ bs=512 seek=176
	dd if=$(dir_build)/spider_9x/rop.dat of=$@ bs=512 seek=208
	dd if=$(dir_build)/cfw/main.bin of=$@ bs=512 seek=256

$(dir_build)/patches/%.baked: $(dir_patches)/%/info.json $(dir_patches)/%/patches.s
	@mkdir -p $(dir_out)/cakes/patches
	@mkdir -p $(dir_build)/patches/$*
	$(PYTHON3) $(dir_patches)/bundle.py $^ $(dir_build)/patches/$* $(dir_out)/cakes/patches
	@touch $@

$(dir_build)/mset_4x/rop.dat: $(dir_build)/mset_4x/main.bin
	$(PYTHON) $(dir_tools)/build-rop.py MSET_4X $< $@

$(dir_build)/mset_4x_dg/rop.dat: $(dir_build)/mset_4x_dg/main.bin
	$(PYTHON) $(dir_tools)/build-rop.py MSET_4X_DG $< $@

$(dir_build)/spider_4x/rop.dat: $(dir_build)/spider_4x/rop.dat.dec
	$(PYTHON) $(dir_tools)/spider-encrypt.py $< $@
$(dir_build)/spider_4x/rop.dat.dec: $(dir_build)/spider_4x/main.bin
	$(PYTHON) $(dir_tools)/build-rop.py SPIDER_4X $< $@

$(dir_build)/spider_5x/rop.dat: $(dir_build)/spider_5x/rop.dat.dec
	$(PYTHON) $(dir_tools)/spider-encrypt.py $< $@
$(dir_build)/spider_5x/rop.dat.dec: $(dir_build)/spider_5x/main.bin
	$(PYTHON) $(dir_tools)/build-rop.py SPIDER_5X $< $@

$(dir_build)/spider_9x/rop.dat: $(dir_build)/spider_9x/rop.dat.dec
	$(PYTHON) $(dir_tools)/spider-encrypt.py $< $@
$(dir_build)/spider_9x/rop.dat.dec: $(dir_build)/spider_9x/main.bin
	$(PYTHON) $(dir_tools)/build-rop.py SPIDER_9X $< $@

# Create bin from elf
$(dir_build)/%/main.bin: $(dir_build)/%/main.elf
	$(OC) -S -O binary $< $@

# Different flags for different things
$(dir_build)/cfw/main.elf: ASFLAGS := $(ARM9FLAGS) $(ASFLAGS)
$(dir_build)/cfw/main.elf: CFLAGS := -DARM9 $(ARM9FLAGS) $(CFLAGS)
$(dir_build)/cfw/main.elf: $(objects_cfw)
	# TODO: Undefined reference to '__aeabi_uidiv'
	$(CC) -nostartfiles $(LDFLAGS) -T linker_cfw.ld $(OUTPUT_OPTION) $^
	#$(LD) $(LDFLAGS) -T linker_cfw.ld $(OUTPUT_OPTION) $^

$(dir_build)/mset_4x/main.elf: ASFLAGS := $(ARM11FLAGS) $(ASFLAGS)
$(dir_build)/mset_4x/main.elf: CFLAGS := -DENTRY_MSET -DENTRY_MSET_4x \
							   $(ARM11FLAGS) $(CFLAGS)
$(dir_build)/mset_4x/main.elf: $(objects_mset_4x)
	$(LD) $(LDFLAGS) -T linker_mset.ld $(OUTPUT_OPTION) $^

$(dir_build)/mset_4x_dg/main.elf: ASFLAGS := $(ARM11FLAGS) $(ASFLAGS)
$(dir_build)/mset_4x_dg/main.elf: CFLAGS := -DENTRY_MSET -DENTRY_MSET_4x_DG \
							   $(ARM11FLAGS) $(CFLAGS)
$(dir_build)/mset_4x_dg/main.elf: $(objects_mset_4x_dg)
	$(LD) $(LDFLAGS) -T linker_mset.ld $(OUTPUT_OPTION) $^

$(dir_build)/spider_4x/main.elf: ASFLAGS := $(ARM11FLAGS) $(ASFLAGS)
$(dir_build)/spider_4x/main.elf: CFLAGS := -DENTRY_SPIDER -DENTRY_SPIDER_4x \
								 $(ARM11FLAGS) $(CFLAGS)
$(dir_build)/spider_4x/main.elf: $(objects_spider_4x)
	$(LD) $(LDFLAGS) -T linker_spider.ld $(OUTPUT_OPTION) $^

$(dir_build)/spider_5x/main.elf: ASFLAGS := $(ARM11FLAGS) $(ASFLAGS)
$(dir_build)/spider_5x/main.elf: CFLAGS := -DENTRY_SPIDER -DENTRY_SPIDER_5x \
								 $(ARM11FLAGS) $(CFLAGS)
$(dir_build)/spider_5x/main.elf: $(objects_spider_5x)
	$(LD) $(LDFLAGS) -T linker_spider.ld $(OUTPUT_OPTION) $^

$(dir_build)/spider_9x/main.elf: ASFLAGS := $(ARM11FLAGS) $(ASFLAGS)
$(dir_build)/spider_9x/main.elf: CFLAGS := -DENTRY_SPIDER -DENTRY_SPIDER_9x \
								 $(ARM11FLAGS) $(CFLAGS)
$(dir_build)/spider_9x/main.elf: $(objects_spider_9x)
	$(LD) $(LDFLAGS) -T linker_spider.ld $(OUTPUT_OPTION) $^

$(dir_build)/%.o: $(dir_source)/%.c
	@mkdir -p "$(@D)"
	$(COMPILE.c) $(OUTPUT_OPTION) $<

$(dir_build)/%.o: $(dir_source)/%.s
	@mkdir -p "$(@D)"
	$(COMPILE.s) $(OUTPUT_OPTION) $<

$(dir_build)/cfw/fatfs/%.o: $(dir_source)/cfw/fatfs/%.c
	@mkdir -p "$(@D)"
	$(COMPILE.c) -mthumb -mthumb-interwork -Wno-unused-function $(OUTPUT_OPTION) $<

$(dir_build)/cfw/fatfs/%.o: $(dir_source)/cfw/fatfs/%.s
	@mkdir -p "$(@D)"
	$(COMPILE.s) -mthumb -mthumb-interwork $(OUTPUT_OPTION) $<

.SECONDEXPANSION:
$(dir_build)/%.o: $(dir_source)/launcher/$$(notdir $$*).c
	@mkdir -p "$(@D)"
	$(COMPILE.c) $(OUTPUT_OPTION) $<

.SECONDEXPANSION:
$(dir_build)/%.o: $(dir_source)/launcher/$$(notdir $$*).s
	@mkdir -p "$(@D)"
	$(COMPILE.s) $(OUTPUT_OPTION) $<

.SECONDEXPANSION:
$(objects_draw): $(dir_build)/%.o: $(dir_source)/lib/$$(notdir $$*).c
	@mkdir -p "$(@D)"
	$(COMPILE.c) $(OUTPUT_OPTION) $<

include $(call rwildcard, $(dir_build), *.d)
