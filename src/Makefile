
PREFIX=/usr
BINDIR=${PREFIX}/bin
MANDIR=${PREFIX}/share/man
DOCDIR=${PREFIX}/share/doc
MAN1DIR=${MANDIR}/man1/
PERLDIR=${PREFIX}/share/perl5

LIB_SOURCES=			\
	Subscription.pm		\
	CalendarEvent.pm	\
	OTP.pm			\
	Ticket.pm		\
	RESTEnvironment.pm	\
	CpuSet.pm		\
	Daemon.pm		\
	SectionConfig.pm	\
	Network.pm		\
	ProcFSTools.pm		\
	CLIHandler.pm		\
	RESTHandler.pm		\
	JSONSchema.pm		\
	SafeSyslog.pm		\
	AtomicFile.pm		\
	INotify.pm		\
	Tools.pm		\
	Syscall.pm		\
	Exception.pm

all:

.PHONY: install
install:
	install -d -m 0755 ${DESTDIR}${PERLDIR}/PVE
	for i in ${LIB_SOURCES}; do install -D -m 0644 PVE/$$i ${DESTDIR}${PERLDIR}/PVE/$$i; done


.PHONY: clean
clean: 	
	rm -rf *~ 

.PHONY: distclean
distclean: clean

