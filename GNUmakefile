VOC=voc
VOCFLAGS=-f
VOCMAIN=-M

# Modules shared between repos, ArgParser.Mod and Err.Mod (both installed
# by the ArgParser repo), are in the directories in VOC_OBERON_MODULES
# (separated by colons), not here.  make finds them through vpath, and voc
# writes their .sym, .c, .h and .o files here, next to the programs that
# import them.  A .Mod here overrides one there.
VOC_OBERON_MODULES ?= /usr/local/sw/versions/oberon/voc/include/
vpath %.Mod $(VOC_OBERON_MODULES)

# Only building needs the shared modules, so clean and uninstall don't
# check for them.
SHARED_MODULES = ArgParser.Mod Err.Mod
ifneq ($(if $(MAKECMDGOALS),$(filter-out clean uninstall,$(MAKECMDGOALS)),all),)
$(foreach m,$(SHARED_MODULES),$(if $(wildcard $(addsuffix /$(m),$(subst :, ,$(VOC_OBERON_MODULES)))),,$(error $(m) is not in VOC_OBERON_MODULES ($(VOC_OBERON_MODULES)); run make install in ~/Repos/Oberon/ArgParser)))
endif

PROGRAMS=Opp OppDocTest

# make install copies Opp to BINDIR, under the name opp.  VOCMAIN is -M,
# which links statically, so it doesn't need voc's libvoc-O2.so to run.
BINDIR ?= $(HOME)/local/bin

.PHONY: all clean test test-verbose install uninstall

all: $(PROGRAMS)

# Opp parses its command line with ArgParser, so it needs its symbol file
# (built along with ArgParser.o) and is rebuilt when it changes.
Opp: ArgParser.o

# ArgParser writes its errors to standard error with Err.
ArgParser.o: Err.o

# opp's own modules, each built before the modules that import it.
Opp: Err.o OppText.o OppScanner.o

OppScanner.o: OppText.o

# OppDocTest checks the layout engine, OppDoc.
OppDocTest: OppText.o OppDoc.o

OppDoc.o: OppText.o


%: %.Mod
	$(VOC) $(VOCFLAGS) $(VOCMAIN) $<

%.o : %.Mod
	$(VOC) $(VOCFLAGS) -s $<


# Run the fixtures in tests/ against the programs and report how
# many passed and failed.  See tests/run-tests.sh for the fixture format.
test: all
	./tests/run-tests.sh

# Like test, but announces each test and its outcome as it goes.
test-verbose: all
	./tests/run-tests.sh -v

install: Opp
	install -d $(BINDIR)
	install -m 755 Opp $(BINDIR)/opp

uninstall:
	rm -f $(BINDIR)/opp

clean:
	-rm -fv $(PROGRAMS) *.c *.h *.o *.sym
	-rm -rfv *.dSYM
