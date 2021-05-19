SUBDIRS = etc_network_interfaces

all:

.PHONY: check install clean distclean

export PERLLIB=../src

check: lock_file.test calendar_event_test.test convert_size_test.test procfs_tests.test format_test.test
	for d in $(SUBDIRS); do $(MAKE) -C $$d check; done

%.test: %.pl
	TZ=UTC-1 ./$<

distclean: clean
clean:
