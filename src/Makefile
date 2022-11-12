
PREFIX=/usr
BINDIR=${PREFIX}/bin
MANDIR=${PREFIX}/share/man
DOCDIR=${PREFIX}/share/doc
MAN1DIR=${MANDIR}/man1/
PERLDIR=${PREFIX}/share/perl5

LIB_SOURCES = \
	AtomicFile.pm \
	CGroup.pm \
	CLIFormatter.pm \
	CLIHandler.pm \
	CalendarEvent.pm \
	Certificate.pm \
	CpuSet.pm \
	Daemon.pm \
	Exception.pm \
	Format.pm \
	INotify.pm \
	JSONSchema.pm \
	Job/Registry.pm \
	LDAP.pm \
	Network.pm \
	OTP.pm \
	PBSClient.pm \
	PTY.pm \
	ProcFSTools.pm \
	RESTEnvironment.pm \
	RESTHandler.pm \
	SafeSyslog.pm \
	SectionConfig.pm \
	SysFSTools.pm \
	Syscall.pm \
	Systemd.pm \
	Ticket.pm \
	Tools.pm

all:

install: $(addprefix PVE/,${LIB_SOURCES})
	install -d -m 0755 ${DESTDIR}${PERLDIR}/PVE
	install -d -m 0755 ${DESTDIR}${PERLDIR}/PVE/Job
	for i in ${LIB_SOURCES}; do install -D -m 0644 PVE/$$i ${DESTDIR}${PERLDIR}/PVE/$$i; done


.PHONY: clean
clean: 	
	rm -rf *~ 

.PHONY: distclean
distclean: clean

