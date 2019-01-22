VERSION=5.0
PKGREL=44

PACKAGE=libpve-common-perl

ARCH=all

BUILDDIR ?= ${PACKAGE}-${VERSION}

DEB=${PACKAGE}_${VERSION}-${PKGREL}_${ARCH}.deb
DSC=${PACKAGE}_${VERSION}-${PKGREL}.dsc
TARGZ=${PACKAGE}_${VERSION}-${PKGREL}.tar.gz

all:
	${MAKE} -C src

.PHONY: dinstall
dinstall: deb
	dpkg -i ${DEB}

${BUILDDIR}: src debian
	rm -rf ${BUILDDIR}
	rsync -a * ${BUILDDIR}
	echo "git clone git://git.proxmox.com/git/pve-common.git\\ngit checkout $(shell git rev-parse HEAD)" > ${BUILDDIR}/debian/SOURCE

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
	rm -rf *~ *.deb *.changes ${BUILDDIR} *.buildinfo *.dsc *.tar.gz

.PHONY: check
check:
	$(MAKE) -C test check

.PHONY: install
install:
	${MAKE} -C src install

.PHONY: upload
upload: ${DEB}
	tar cf - ${DEB}|ssh -X repoman@repo.proxmox.com -- upload --product pve,pmg --dist stretch

