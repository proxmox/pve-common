include /usr/share/dpkg/pkg-info.mk

PACKAGE=libpve-common-perl

ARCH=all

BUILDDIR ?= ${PACKAGE}-${DEB_VERSION_UPSTREAM}

DEB=${PACKAGE}_${DEB_VERSION_UPSTREAM_REVISION}_${ARCH}.deb
DSC=${PACKAGE}_${DEB_VERSION_UPSTREAM_REVISION}.dsc
TARGZ=${PACKAGE}_${DEB_VERSION_UPSTREAM_REVISION}.tar.gz

all:
	${MAKE} -C src

.PHONY: dinstall
dinstall: deb
	dpkg -i ${DEB}

${BUILDDIR}: src debian test
	rm -rf ${BUILDDIR} ${BUILDDIR}.tmp; mkdir ${BUILDDIR}.tmp
	cp -a -t ${BUILDDIR}.tmp $^ Makefile
	echo "git clone git://git.proxmox.com/git/pve-common.git\\ngit checkout $(shell git rev-parse HEAD)" > ${BUILDDIR}.tmp/debian/SOURCE
	mv ${BUILDDIR}.tmp ${BUILDDIR}

.PHONY: deb
deb: ${DEB}
${DEB}: ${BUILDDIR}
	cd ${BUILDDIR}; dpkg-buildpackage -b -us -uc
	lintian ${DEB}

.PHONY: dsc
dsc ${TARGZ}: ${DSC}
${DSC}: ${BUILDDIR}
	cd ${BUILDDIR}; dpkg-buildpackage -S -us -uc -d -nc
	lintian ${DSC}

.PHONY: clean distclean
distclean: clean
clean:
	rm -rf *~ *.deb *.changes ${PACKAGE}-*/ *.buildinfo *.dsc *.tar.gz

.PHONY: check
check:
	$(MAKE) -C test check

.PHONY: install
install:
	${MAKE} -C src install

.PHONY: upload
upload: ${DEB}
	tar cf - ${DEB}|ssh -X repoman@repo.proxmox.com -- upload --product pve,pmg --dist bullseye
