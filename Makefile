# hmerge plugin build (macOS arm64 / clang; for Linux use gcc with
# -shared -fPIC -DSYSTEM=OPUNIX, as gtools does).
#   make            release build: hmerge.plugin (-O3, portable, no -mcpu)
#   make ubsan      trap-mode UndefinedBehaviorSanitizer build for testing:
#                   any undefined behavior crashes Stata instead of silently
#                   misbehaving (the regular UBSan runtime cannot be loaded
#                   into Stata's process)
CC      = clang
CFLAGS  = -O3 -Wall -Wextra
OSFLAGS = -bundle -DSYSTEM=APPLEMAC

hmerge.plugin: hmerge.c stplugin.c stplugin.h
	$(CC) $(CFLAGS) $(OSFLAGS) -o $@ hmerge.c stplugin.c

ubsan: hmerge.c stplugin.c stplugin.h
	$(CC) -O1 -g -fsanitize=undefined -fsanitize-trap=undefined -Wall $(OSFLAGS) -o hmerge.plugin hmerge.c stplugin.c

.PHONY: ubsan

# the file distributed through net install (hmerge.pkg installs it as hmerge.plugin)
dist: hmerge.plugin
	cp hmerge.plugin hmerge_macarm64.plugin

.PHONY: dist
