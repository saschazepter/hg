# If you want to change PREFIX, do not just edit it below. The changed
# value wont get passed on to recursive make calls. You should instead
# override the variable on the command like:
#
# % make PREFIX=/opt/ install

export PREFIX=/usr/local

# Default to Python 3.
#
# Windows ships Python 3 as `python.exe`, which may not be on PATH.  py.exe is.
ifeq ($(OS),Windows_NT)
PYTHON?=py -3
else
PYTHON?=python3
endif

PYOXIDIZER?=pyoxidizer

$(eval HGROOT := $(shell pwd))
HGPYTHONS ?= $(HGROOT)/build/pythons
PURE=
PYFILESCMD=find mercurial hgext doc -name '*.py'
PYFILES:=$(shell $(PYFILESCMD))
DOCFILES=mercurial/helptext/*.txt
export LANGUAGE=C
export LC_ALL=C
TESTFLAGS ?= $(shell echo $$HGTESTFLAGS)
OSXVERSIONFLAGS ?= $(shell echo $$OSXVERSIONFLAGS)
CARGO = cargo

# Set this to e.g. "mingw32" to use a non-default compiler.
COMPILER=

COMPILERFLAG_tmp_ =
COMPILERFLAG_tmp_${COMPILER} ?= -c $(COMPILER)
COMPILERFLAG=${COMPILERFLAG_tmp_${COMPILER}}

help:
	@echo 'Commonly used make targets:'
	@echo '  all          - build program and documentation'
	@echo '  install      - install program and man pages to $$PREFIX ($(PREFIX))'
	@echo '  install-home - install with setup.py install --home=$$HOME ($(HOME))'
	@echo '  local        - build for inplace usage'
	@echo '  tests        - run all tests in the automatic test suite'
	@echo '  test-foo     - run only specified tests (e.g. test-merge1.t)'
	@echo '  dist         - run all tests and create a source tarball in dist/'
	@echo '  clean        - remove files created by other targets'
	@echo '                 (except installed files or dist source tarball)'
	@echo '  update-pot   - update i18n/hg.pot'
	@echo
	@echo 'Example for a system-wide installation under /usr/local:'
	@echo '  make all && su -c "make install" && hg version'
	@echo
	@echo 'Example for a local installation (usable in this directory):'
	@echo '  make local && ./hg version'

all: build doc

local:
	$(PYTHON) setup.py $(PURE) \
	  build_py -c -d . \
	  build_ext $(COMPILERFLAG) -i \
	  build_hgexe $(COMPILERFLAG) -i \
	  build_mo
	env HGRCPATH= $(PYTHON) hg version

build:
	$(PYTHON) setup.py $(PURE) build $(COMPILERFLAG)

build-chg:
	make -C contrib/chg

build-rhg:
	(cd rust/rhg; cargo build --release)

wheel:
	FORCE_SETUPTOOLS=1 $(PYTHON) setup.py $(PURE) bdist_wheel $(COMPILERFLAG)

doc:
	$(MAKE) -C doc

cleanbutpackages:
	rm -f hg.exe
	-$(PYTHON) setup.py clean --all # ignore errors from this command
	find contrib doc hgext hgext3rd i18n mercurial tests hgdemandimport \
		\( -name '*.py[cdo]' -o -name '*.so' \) -exec rm -f '{}' ';'
	rm -f MANIFEST MANIFEST.in hgext/__index__.py tests/*.err
	rm -f mercurial/__modulepolicy__.py
	if test -d .hg; then rm -f mercurial/__version__.py; fi
	rm -rf build mercurial/locale
	$(MAKE) -C doc clean
	$(MAKE) -C contrib/chg distclean
	rm -rf rust/target
	rm -f mercurial/rustext.so

clean: cleanbutpackages
	rm -rf packages

install: install-bin install-doc

install-bin: build
	$(PYTHON) setup.py $(PURE) install --root="$(DESTDIR)/" --prefix="$(PREFIX)" --force

install-chg: build-chg
	make -C contrib/chg install PREFIX="$(PREFIX)"

install-doc: doc
	cd doc && $(MAKE) $(MFLAGS) install

install-home: install-home-bin install-home-doc

install-home-bin: build
	$(PYTHON) setup.py $(PURE) install --home="$(HOME)" --prefix="" --force

install-home-doc: doc
	cd doc && $(MAKE) $(MFLAGS) PREFIX="$(HOME)" install

install-rhg: build-rhg
	install -m 755 rust/target/release/rhg "$(PREFIX)"/bin/

MANIFEST-doc:
	$(MAKE) -C doc MANIFEST

MANIFEST.in: MANIFEST-doc
	hg manifest | sed -e 's/^/include /' > MANIFEST.in
	echo include mercurial/__version__.py >> MANIFEST.in
	sed -e 's/^/include /' < doc/MANIFEST >> MANIFEST.in

dist:	tests dist-notests

dist-notests:	doc MANIFEST.in
	TAR_OPTIONS="--owner=root --group=root --mode=u+w,go-w,a+rX-s" $(PYTHON) setup.py -q sdist

check: tests

tests:
        # Run Rust tests if cargo is installed
	if command -v $(CARGO) >/dev/null 2>&1; then \
		$(MAKE) rust-tests; \
	fi
	cd tests && $(PYTHON) run-tests.py $(TESTFLAGS)

test-%:
	cd tests && $(PYTHON) run-tests.py $(TESTFLAGS) $@

testpy-%:
	@echo Looking for Python $* in $(HGPYTHONS)
	[ -e $(HGPYTHONS)/$*/bin/python ] || ( \
	cd $$(mktemp --directory --tmpdir) && \
        $(MAKE) -f $(HGROOT)/contrib/Makefile.python PYTHONVER=$* PREFIX=$(HGPYTHONS)/$* python )
	cd tests && $(HGPYTHONS)/$*/bin/python run-tests.py $(TESTFLAGS)

rust-tests: py_feature = $(shell $(PYTHON) -c \
 'import sys; print(["python27-bin", "python3-bin"][sys.version_info[0] >= 3])')
rust-tests:
	cd $(HGROOT)/rust/hg-cpython \
		&& $(CARGO) test --quiet --all \
			--no-default-features --features "$(py_feature) $(HG_RUST_FEATURES)"

check-code:
	hg manifest | xargs python contrib/check-code.py

format-c:
	clang-format --style file -i \
	  `hg files 'set:(**.c or **.cc or **.h) and not "listfile:contrib/clang-format-ignorelist"'`

update-pot: i18n/hg.pot

i18n/hg.pot: $(PYFILES) $(DOCFILES) i18n/posplit i18n/hggettext
	$(PYTHON) i18n/hggettext mercurial/commands.py \
	  hgext/*.py hgext/*/__init__.py \
	  mercurial/fileset.py mercurial/revset.py \
	  mercurial/templatefilters.py \
	  mercurial/templatefuncs.py \
	  mercurial/templatekw.py \
	  mercurial/filemerge.py \
	  mercurial/hgweb/webcommands.py \
	  mercurial/util.py \
	  $(DOCFILES) > i18n/hg.pot.tmp
        # All strings marked for translation in Mercurial contain
        # ASCII characters only. But some files contain string
        # literals like this '\037\213'. xgettext thinks it has to
        # parse them even though they are not marked for translation.
        # Extracting with an explicit encoding of ISO-8859-1 will make
        # xgettext "parse" and ignore them.
	$(PYFILESCMD) | xargs \
	  xgettext --package-name "Mercurial" \
	  --msgid-bugs-address "<mercurial-devel@mercurial-scm.org>" \
	  --copyright-holder "Olivia Mackall <olivia@selenic.com> and others" \
	  --from-code ISO-8859-1 --join --sort-by-file --add-comments=i18n: \
	  -d hg -p i18n -o hg.pot.tmp
	$(PYTHON) i18n/posplit i18n/hg.pot.tmp
        # The target file is not created before the last step. So it never is in
        # an intermediate state.
	mv -f i18n/hg.pot.tmp i18n/hg.pot

%.po: i18n/hg.pot
        # work on a temporary copy for never having a half completed target
	cp $@ $@.tmp
	msgmerge --no-location --update $@.tmp $^
	mv -f $@.tmp $@

# Packaging targets

packaging_targets := \
  rhel7 \
  rhel8 \
  deb \
  docker-rhel7 \
  docker-rhel8 \
  docker-debian-bullseye \
  docker-debian-buster \
  docker-debian-stretch \
  docker-fedora \
  docker-ubuntu-xenial \
  docker-ubuntu-xenial-ppa \
  docker-ubuntu-bionic \
  docker-ubuntu-bionic-ppa \
  docker-ubuntu-focal \
  docker-ubuntu-focal-ppa \
  fedora \
  linux-wheels \
  linux-wheels-x86_64 \
  linux-wheels-i686 \
  ppa

# Forward packaging targets for convenience.
$(packaging_targets):
	$(MAKE) -C contrib/packaging $@

osx:
	rm -rf build/mercurial
	/usr/bin/python2.7 setup.py install --optimize=1 \
	  --root=build/mercurial/ --prefix=/usr/local/ \
	  --install-lib=/Library/Python/2.7/site-packages/
	make -C doc all install DESTDIR="$(PWD)/build/mercurial/"
        # Place a bogon .DS_Store file in the target dir so we can be
        # sure it doesn't get included in the final package.
	touch build/mercurial/.DS_Store
        # install zsh completions - this location appears to be
        # searched by default as of macOS Sierra.
	install -d build/mercurial/usr/local/share/zsh/site-functions/
	install -m 0644 contrib/zsh_completion build/mercurial/usr/local/share/zsh/site-functions/_hg
        # install bash completions - there doesn't appear to be a
        # place that's searched by default for bash, so we'll follow
        # the lead of Apple's git install and just put it in a
        # location of our own.
	install -d build/mercurial/usr/local/hg/contrib/
	install -m 0644 contrib/bash_completion build/mercurial/usr/local/hg/contrib/hg-completion.bash
	make -C contrib/chg \
	  HGPATH=/usr/local/bin/hg \
	  PYTHON=/usr/bin/python2.7 \
	  DESTDIR=../../build/mercurial \
	  PREFIX=/usr/local \
	  clean install
	mkdir -p $${OUTPUTDIR:-dist}
	HGVER=$$(python contrib/genosxversion.py $(OSXVERSIONFLAGS) build/mercurial/Library/Python/2.7/site-packages/mercurial/__version__.py) && \
	OSXVER=$$(sw_vers -productVersion | cut -d. -f1,2) && \
	pkgbuild --filter \\.DS_Store --root build/mercurial/ \
	  --identifier org.mercurial-scm.mercurial \
	  --version "$${HGVER}" \
	  build/mercurial.pkg && \
	productbuild --distribution contrib/packaging/macosx/distribution.xml \
	  --package-path build/ \
	  --version "$${HGVER}" \
	  --resources contrib/packaging/macosx/ \
	  "$${OUTPUTDIR:-dist/}"/Mercurial-"$${HGVER}"-macosx"$${OSXVER}".pkg

pyoxidizer:
	$(PYOXIDIZER) build --path ./rust/hgcli --release


PYOX_DIR=build/pyoxidizer/x86_64-pc-windows-msvc/release/app

# a temporary target to setup all we need for run-tests.py --pyoxidizer
# (should go away as the run-tests implementation improves
pyoxidizer-windows-tests: pyoxidizer
	rm -rf $(PYOX_DIR)/templates
	cp -ar $(PYOX_DIR)/lib/mercurial/templates $(PYOX_DIR)/templates
	rm -rf $(PYOX_DIR)/helptext
	cp -ar $(PYOX_DIR)/lib/mercurial/helptext $(PYOX_DIR)/helptext
	rm -rf $(PYOX_DIR)/defaultrc
	cp -ar $(PYOX_DIR)/lib/mercurial/defaultrc $(PYOX_DIR)/defaultrc
	rm -rf $(PYOX_DIR)/contrib
	cp -ar contrib $(PYOX_DIR)/contrib
	rm -rf $(PYOX_DIR)/doc
	cp -ar doc $(PYOX_DIR)/doc


.PHONY: help all local build doc cleanbutpackages clean install install-bin \
	install-doc install-home install-home-bin install-home-doc \
	dist dist-notests check tests rust-tests check-code format-c \
	update-pot pyoxidizer pyoxidizer-windows-tests \
	$(packaging_targets) \
	osx
