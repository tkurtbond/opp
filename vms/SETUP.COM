$ ! SETUP.COM - makes opp, the Oberon pretty printer, usable in this
$ ! process, once BUILD.COM has built it (README.TXT): defines the foreign
$ ! command OPP, and makes OPP.HLB a help library of the process's, so that
$ ! HELP OPP finds it, as the first of HLP$LIBRARY, HLP$LIBRARY_1, ... not
$ ! yet defined. Run it once a session, or from LOGIN.COM. Written for
$ ! opp's kit (tools/make-vax-kit, VAX-VMS-PORT.md step 7).
$ !
$ !   @SETUP
$ PROC = F$ENVIRONMENT("PROCEDURE")
$ TOP = F$PARSE(PROC, , , "DEVICE") + F$PARSE(PROC, , , "DIRECTORY")
$ TOP_OPEN = F$EXTRACT(0, F$LENGTH(TOP) - 1, TOP)
$ CLOSE_BRACKET = F$EXTRACT(F$LENGTH(TOP) - 1, 1, TOP)
$ IMAGE = TOP_OPEN + ".BIN" + CLOSE_BRACKET + "OPP.EXE"
$ IF F$SEARCH(IMAGE) .NES. "" THEN GOTO BUILT
$ WRITE SYS$ERROR "SETUP: opp is not built; @", TOP, "BUILD first"
$ EXIT %X10000014
$BUILT:
$ OPP :== $'IMAGE'
$ HELP_LIBRARY = TOP + "OPP.HLB"
$ IF F$SEARCH(HELP_LIBRARY) .EQS. "" THEN EXIT 1
$ N = 0
$ NAME = "HLP$LIBRARY"
$NEXT_NAME:
$ DEFINED = F$TRNLNM(NAME)
$ IF DEFINED .EQS. "" THEN GOTO FREE_NAME
$ IF F$PARSE(DEFINED, ".HLB") .EQS. F$PARSE(HELP_LIBRARY) THEN EXIT 1
$ N = N + 1
$ NAME = "HLP$LIBRARY_" + F$STRING(N)
$ GOTO NEXT_NAME
$FREE_NAME:
$ DEFINE/NOLOG 'NAME' 'HELP_LIBRARY'
$ EXIT 1
