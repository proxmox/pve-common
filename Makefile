VERSION=5.0
PKGREL=34

PACKAGE=libpve-common-perl

ARCH=all
GITVERSION:=$(shell git rev-parse HEAD)

BUILDDIR ?= build

DEB=${PACKAGE}_${VERSION}-${PKGREL}_${ARCH}.deb

all: ${DEB}

.PHONY: dinstall
dinstall: deb
	dpkg -i ${DEB}


.PHONY: deb
deb ${DEB}:
	$(MAKE) -C test check
	rm -rf ${BUILDDIR}
	rsync -a src/ ${BUILDDIR}
	rsync -a debian/ ${BUILDDIR}/debian
	echo "git clone git://git.proxmox.com/git/pve-common.git\\ngit checkout ${GITVERSION}" > ${BUILDDIR}/debian/SOURCE
	cd ${BUILDDIR}; dpkg-buildpackage -b -us -uc
	lintian ${DEB}

.PHONY: clean distclean
distclean: clean
clean:
	rm -rf *~ *.deb *.changes ${BUILDDIR} *.buildinfo

.PHONY: check
check:
	$(MAKE) -C test check

.PHONY: upload
upload: ${DEB}
	tar cf - ${DEB}|ssh -X repoman@repo.proxmox.com -- upload --product pve,pmg --dist stretch

