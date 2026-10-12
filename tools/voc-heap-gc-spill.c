/* opp's protection from voc's collector bug, copied from Peaseblossom's
   tools/bootstrap/voc-heap-gc-spill.c (see its doc/developer/bootstrapping-
   with-voc.md): voc's Heap.GC finds roots by scanning the
   stack, and its way of getting the callee-saved registers onto the stack
   first does nothing in C compiled without optimization, so a pointer held
   only in one of them (rbx, r12-r15 on x86_64; ebx, esi, edi on i386;
   x19-x28 on aarch64) is missed and its object freed while in use.

   This file defines Heap_GC, so the programs the GNUmakefile links with
   voc call it in place of libvoc's, from their own code and from libvoc's
   alike (the ELF dynamic linker binds every call of a library's
   exported function to the executable's definition). It stores every
   callee-saved register in its own frame (__builtin_unwind_init, which gcc
   and clang both have), which lies inside the stretch voc's MarkStack
   scans, and then calls libvoc's Heap_GC. Peaseblossom checked it with
   the bug's reproducer on atla, cymoril, artos and alerik, 2026-10-02.

   It needs a dynamic link (voc -m): linked statically, libvoc's own calls
   of Heap_GC stay bound to its own. Without it, opp's voc build garbled
   or crashed on large files (PLAN.md, Phase 3).

   Only Heap_GC is replaced, not voc's Heap module, so it fits whichever
   commit each host's voc was built from. */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

void Heap_GC(unsigned char markStack)
{
  static void (*voc_heap_gc)(unsigned char);

  __builtin_unwind_init();
  if (voc_heap_gc == NULL) {
    voc_heap_gc = (void (*)(unsigned char))dlsym(RTLD_NEXT, "Heap_GC");
    if (voc_heap_gc == NULL) {
      fputs("voc-heap-gc-spill: libvoc's Heap_GC not found\n", stderr);
      abort();
    }
  }
  voc_heap_gc(markStack);
}
