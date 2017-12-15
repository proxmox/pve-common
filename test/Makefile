SUBDIRS = etc_network_interfaces

all:

.PHONY: check install clean distclean

check:
	for d in $(SUBDIRS); do $(MAKE) -C $$d check; done
	./lock_file.pl
	./calendar_event_test.pl
	./convert_size_test.pl

install: check
distclean: clean
clean:
