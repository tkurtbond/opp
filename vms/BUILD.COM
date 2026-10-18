$ ! BUILD.COM - builds opp, the Oberon pretty printer, in the directory
$ ! opp's kit was unpacked in: assembles the MACRO-32 in [.KIT], opp's
$ ! and poc's runtime's, links [.BIN]OPP.EXE, and makes the help library
$ ! OPP.HLB from OPP.HLP. It needs MACRO, LINK and LIBRARY alone, not poc.
$ ! Then @SETUP defines the command OPP (README.TXT). Written for opp's kit
$ ! (tools/make-vax-kit, VAX-VMS-PORT.md step 7).
$ !
$ !   @BUILD
$ !
$ ! To build again, delete [.BIN]OPP.EXE first; BUILD.COM builds only what
$ ! is not there.
$ PROC = F$ENVIRONMENT("PROCEDURE")
$ TOP = F$PARSE(PROC, , , "DEVICE") + F$PARSE(PROC, , , "DIRECTORY")
$ TOP_OPEN = F$EXTRACT(0, F$LENGTH(TOP) - 1, TOP)
$ CLOSE_BRACKET = F$EXTRACT(F$LENGTH(TOP) - 1, 1, TOP)
$ KIT_DIR = TOP_OPEN + ".KIT" + CLOSE_BRACKET
$ BIN_DIR = TOP_OPEN + ".BIN" + CLOSE_BRACKET
$ SAVED_DEFAULT = F$ENVIRONMENT("DEFAULT")
$ ! OPP.COM links poc's runtime from POC$RTL: when that is defined, so it
$ ! names [.KIT] while it runs, and any definition of the process's own is
$ ! put back after
$ SAVED_RTL = F$TRNLNM("POC$RTL", "LNM$PROCESS")
$ IF F$SEARCH(BIN_DIR + "OPP.EXE") .NES. "" THEN GOTO HELP_LIBRARY
$ IF F$SEARCH(KIT_DIR + "OPP.COM") .NES. "" THEN GOTO KIT_THERE
$ WRITE SYS$ERROR "BUILD: there is no ", KIT_DIR, "OPP.COM; unpack the kit here first"
$ EXIT %X10000014
$KIT_THERE:
$ ON WARNING THEN GOTO FAILED
$ ON CONTROL_Y THEN GOTO FAILED
$ SET DEFAULT 'KIT_DIR'
$ DEFINE/NOLOG POC$RTL 'KIT_DIR'
$ WRITE SYS$OUTPUT "BUILD: assembling and linking OPP.EXE"
$ MACRO/OBJECT POCRTL.MAR
$ @OPP
$ RENAME OPP.EXE 'BIN_DIR'OPP.EXE
$ DELETE/NOLOG *.OBJ;*
$ DELETE/NOLOG OPP.OPT;*
$ SET DEFAULT 'SAVED_DEFAULT'
$ DEASSIGN POC$RTL
$ IF SAVED_RTL .NES. "" THEN DEFINE/NOLOG POC$RTL 'SAVED_RTL'
$HELP_LIBRARY:
$ ON WARNING THEN GOTO FAILED
$ IF F$SEARCH(TOP + "OPP.HLB") .NES. "" THEN GOTO DONE
$ WRITE SYS$OUTPUT "BUILD: making the help library OPP.HLB"
$ LIBRARY/CREATE/HELP 'TOP'OPP.HLB 'TOP'OPP.HLP
$DONE:
$ WRITE SYS$OUTPUT "BUILD: opp is built; now @", TOP, "SETUP"
$ EXIT 1
$FAILED:
$ STATUS = $STATUS
$ SET NOON
$ SET DEFAULT 'SAVED_DEFAULT'
$ IF F$TRNLNM("POC$RTL", "LNM$PROCESS") .NES. "" THEN DEASSIGN POC$RTL
$ IF SAVED_RTL .NES. "" THEN DEFINE/NOLOG POC$RTL 'SAVED_RTL'
$ WRITE SYS$ERROR "BUILD: building opp failed"
$ EXIT STATUS .OR. %X10000000
