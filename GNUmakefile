VOC=voc
VOCFLAGS=-f
VOCMAIN=-m
CC ?= cc

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

# make install copies Opp to BINDIR, under the name opp.
BINDIR ?= $(HOME)/local/bin
# and its man page, opp.1, to MANDIR.
MANDIR ?= $(HOME)/local/share/man/man1

# voc's collector misses a pointer held only in a callee-saved register
# (vishap-bugs 14), which garbled or crashed opp on large files. As
# Peaseblossom's Stage 0 does, the programs are linked with a Heap_GC that
# stores those registers on the stack and then calls libvoc's: voc adds
# LDFLAGS to its link command, ahead of libvoc, and dlsym is in libdl on
# Linux. That needs a dynamic link, so VOCMAIN is -m, not -M, and the
# programs need voc's libvoc-O2.so to run (found without LD_LIBRARY_PATH on
# Linux, as voc links it).
SPILL = tools/voc-heap-gc-spill.o
SPILL_LIBS = $(if $(filter Linux,$(shell uname -s)),-ldl)
export LDFLAGS := $(abspath $(SPILL)) $(SPILL_LIBS) $(LDFLAGS)

.PHONY: corpus format all clean test test-verbose install uninstall

all: $(PROGRAMS)

# Opp parses its command line with ArgParser, so it needs its symbol file
# (built along with ArgParser.o) and is rebuilt when it changes.
Opp: ArgParser.o

# ArgParser writes its errors to standard error with Err.
ArgParser.o: Err.o

# opp's own modules, each built before the modules that import it.
Opp: Err.o OppText.o OppScanner.o OppDoc.o OppFormat.o OppCheck.o OppHost.o

OppFormat.o: OppText.o OppScanner.o OppDoc.o

OppCheck.o: OppText.o OppScanner.o

OppScanner.o: OppText.o

OppHost.o: OppText.o

# OppDocTest checks the layout engine, OppDoc.
OppDocTest: OppText.o OppDoc.o

OppDoc.o: OppText.o


%: %.Mod $(SPILL)
	$(VOC) $(VOCFLAGS) $(VOCMAIN) $<
	@nm $@ | grep -q ' T Heap_GC$$' || { echo "$@ was linked without $(SPILL)'s Heap_GC" >&2; rm -f $@; exit 1; }

$(SPILL): tools/voc-heap-gc-spill.c
	$(CC) -fPIC -c $< -o $@

%.o : %.Mod
	$(VOC) $(VOCFLAGS) -s $<


# Run the fixtures in tests/ against the programs and report how
# many passed and failed.  See tests/run-tests.sh for the fixture format.
test: all
	./tests/run-tests.sh
	./tests/in-place.sh

# Like test, but announces each test and its outcome as it goes.
test-verbose: all
	./tests/run-tests.sh -v

# The bodies of real Oberon that make corpus formats: poc (both
# branches), voc, the other Oberon repos, and opp itself (its source and
# its tests' inputs).  A directory that does not
# exist is skipped.
OBERON_REPOS ?= $(HOME)/Repos/Oberon
VOC_SOURCE ?= /usr/local/sw/src/lang/Oberon/vishap/compiler
CORPUS_DIRS ?= $(OBERON_REPOS)/Peaseblossom-main $(OBERON_REPOS)/Peaseblossom \
  $(VOC_SOURCE) $(OBERON_REPOS)/ArgParser $(OBERON_REPOS)/Ropes \
  $(OBERON_REPOS)/oberon-tools $(OBERON_REPOS)/polibfyaml \
  $(OBERON_REPOS)/pofltk $(OBERON_REPOS)/oberon-experiments $(CURDIR)

# Format every module in CORPUS_DIRS in all three modes at widths 60, 80
# and 120, checking that opp succeeds and is idempotent, and reporting the
# lines still too long.  See tools/corpus.py.
corpus: Opp
	python3 -I tools/corpus.py ./Opp tools/corpus-known-errors $(CORPUS_DIRS)

# Format opp's own source with opp, in the style tests/opp-own-source.test
# checks.
OPP_SOURCES = Opp.Mod OppCheck.Mod OppDoc.Mod OppDocTest.Mod OppFormat.Mod \
  OppHost.Mod OppScanner.Mod OppText.Mod vms/OppHost.Mod
format: Opp
	./Opp --no-config --in-place -k --no-module-indent $(OPP_SOURCES)

install: Opp
	install -d $(BINDIR)
	install -m 755 Opp $(BINDIR)/opp
	install -d $(MANDIR)
	install -m 644 opp.1 $(MANDIR)/opp.1

uninstall:
	rm -f $(BINDIR)/opp $(MANDIR)/opp.1

clean:
	-rm -fv $(PROGRAMS) *.c *.h *.o *.sym $(SPILL)
	-rm -rfv *.dSYM
