# Makefile for infoline

ifeq ($(notdir $(CURDIR)),src)
$(error do not execute make in src directory)
endif

AS	= has060
ASFLAGS	= -w
LD	= hlk
LDFLAGS	=

BINDIR	= /usr/local/bin

IL_R	= infoline.r
IL_X	= infoline.x

DOCS	= infoline.txt LICENSE.txt CHANGELOG.txt
INFOL_ZIP = infol.zip

all: $(IL_R)

$(INFOL_ZIP): $(IL_R) $(DOCS)
	rm -f $@
	zip -9 $@ $^

$(IL_R): infoline.o
	$(LD) $(LDFLAGS) -o $@ $^ -r

$(IL_X): infoline.o
	$(LD) $(LDFLAGS) -o $@ $^

infoline.o: infoline.s
	$(AS) $(ASFLAGS) -o $@ $^

install:
	cp -p $(IL_R) $(BINDIR)

clean:
	rm -f infoline.[ox]

distclean:
	rm -f infoline.[oxr]

# EOF
