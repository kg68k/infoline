# Makefile for info-line (convert source code from UTF-8 to Shift_JIS)
#   Do not use non-ASCII characters in this file.

MKDIR_P = mkdir -p
U8TOSJ = u8tosj

SRC_DIR = src
BLD_DIR = build


DOCS = infoline.txt CHANGELOG.txt LICENSE.txt
SJ_DOCS = $(addprefix $(BLD_DIR)/,$(DOCS))

SRCS = $(wildcard $(SRC_DIR)/*)
SJ_SRCS = $(subst $(SRC_DIR)/,$(BLD_DIR)/,$(SRCS))

.PHONY: all directories clean

all: directories $(SJ_DOCS) $(SJ_SRCS)

directories: $(BLD_DIR)

$(BLD_DIR):
	$(MKDIR_P) $@


# convert src/* (UTF-8) to build/* (Shift_JIS)
$(BLD_DIR)/%: $(SRC_DIR)/%
	$(U8TOSJ) < $^ >! $@

$(BLD_DIR)/infoline.txt: infoline.txt
	$(U8TOSJ) < $^ >! $@

$(BLD_DIR)/CHANGELOG.txt: CHANGELOG.md
	$(U8TOSJ) < $^ >! $@

$(BLD_DIR)/LICENSE.txt: LICENSE.txt
	$(U8TOSJ) < $^ >! $@


clean:
	rm -f $(SJ_DOCS) $(SJ_SRCS)

# EOF
