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
CARGO = cargo

# Set this to e.g. "mingw32" to use a non-default compiler.
COMPILER=

COMPILERFLAG_tmp_ =
COMPILERFLAG_tmp_${COMPILER} ?= -c $(COMPILER)
COMPILERFLAG=${COMPILERFLAG_tmp_${COMPILER}}

VENV_NAME=$(shell $(PYTHON) -c "import sys; v = sys.version_info; print(f'.venv_{sys.implementation.name}{v.major}.{v.minor}')")
PYBINDIRNAME=$(shell $(PYTHON) -c "import os; print('Scripts' if os.name == 'nt' else 'bin')")

help:
	@echo 'Commonly used make targets:'
	@echo '  all          - build program and documentation'
	@echo '  install      - install program and man pages to $$PREFIX ($(PREFIX))'
	@echo '  install-home - install with pip install --user'
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
	$(PYTHON) -m venv $(VENV_NAME) --clear --upgrade-deps
	$(VENV_NAME)/$(PYBINDIRNAME)/python -m \
	  pip install -e . -v --config-settings --global-option="$(PURE)"
	env HGRCPATH= $(VENV_NAME)/$(PYBINDIRNAME)/hg version

build:
	$(PYTHON) setup.py $(PURE) build $(COMPILERFLAG)

build-chg:
	make -C contrib/chg

build-rhg:
	(cd rust/rhg; cargo build --release)

wheel:
	$(PYTHON) setup.py $(PURE) bdist_wheel $(COMPILERFLAG)

doc:
	$(MAKE) -C doc

cleanbutpackages:
	rm -f hg.exe
	rm -rf mercurial.egg-info dist
	find contrib doc hgext hgext3rd i18n mercurial tests hgdemandimport \
		\( -name '*.py[cdo]' -o -name '*.so' \) -exec rm -f '{}' ';'
	rm -rf .venv_*
	rm -f hgext/__index__.py tests/*.err
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

install-bin:
	$(PYTHON) -m pip install --prefix="$(PREFIX)" --force -v --config-settings --global-option="$(PURE)"

install-chg: build-chg
	make -C contrib/chg install PREFIX="$(PREFIX)"

install-doc: doc
	cd doc && $(MAKE) $(MFLAGS) install

install-home: install-home-bin install-home-doc

install-home-bin:
	$(PYTHON) -m pip install --user --force -v --config-settings --global-option="$(PURE)"

install-home-doc: doc
	cd doc && $(MAKE) $(MFLAGS) PREFIX="$(HOME)" install

install-rhg: build-rhg
	install -m 755 rust/target/release/rhg "$(PREFIX)"/bin/

dist:	tests dist-notests

dist-notests:	doc
	TAR_OPTIONS="--owner=root --group=root --mode=u+w,go-w,a+rX-s" $(PYTHON) setup.py -q sdist

check: tests

tests:
        # Run Rust tests if cargo is installed
	if command -v $(CARGO) >/dev/null 2>&1; then \
		$(MAKE) rust-tests; \
		$(MAKE) cargo-clippy; \
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

rust-tests:
	cd $(HGROOT)/rust \
		&& $(CARGO) test --quiet --all \
		--features "$(HG_RUST_FEATURES)" --no-default-features

cargo-clippy:
	cd $(HGROOT)/rust \
		&& $(CARGO) clippy --all --features "$(HG_RUST_FEATURES)" -- -D warnings

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
  rhel9 \
  deb \
  docker-rhel7 \
  docker-rhel8 \
  docker-rhel9 \
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
  linux-wheels-x86_64-musl \
  linux-wheels-i686 \
  linux-wheels-i686-musl \
  ppa

# Forward packaging targets for convenience.
$(packaging_targets):
	$(MAKE) -C contrib/packaging $(MAKEFLAGS) $@


pyoxidizer:
	$(PYOXIDIZER) build --path ./rust/hgcli --release


# a temporary target to setup all we need for run-tests.py --pyoxidizer
# (should go away as the run-tests implementation improves
pyoxidizer-windows-tests: PYOX_DIR=build/pyoxidizer/x86_64-pc-windows-msvc/release/app
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


# a temporary target to setup all we need for run-tests.py --pyoxidizer
# (should go away as the run-tests implementation improves
pyoxidizer-macos-tests: PYOX_DIR=build/pyoxidizer/x86_64-apple-darwin/release/app
pyoxidizer-macos-tests: pyoxidizer
	rm -rf $(PYOX_DIR)/templates
	cp -a mercurial/templates $(PYOX_DIR)/templates
	rm -rf $(PYOX_DIR)/helptext
	cp -a mercurial/helptext $(PYOX_DIR)/helptext
	rm -rf $(PYOX_DIR)/defaultrc
	cp -a mercurial/defaultrc $(PYOX_DIR)/defaultrc
	rm -rf $(PYOX_DIR)/contrib
	cp -a contrib $(PYOX_DIR)/contrib
	rm -rf $(PYOX_DIR)/doc
	cp -a doc $(PYOX_DIR)/doc

pytype-docker:
	contrib/docker/pytype/recipe.sh

.PHONY: help all local build doc cleanbutpackages clean install install-bin \
	install-doc install-home install-home-bin install-home-doc \
	dist dist-notests check tests rust-tests check-code format-c \
	update-pot pyoxidizer pyoxidizer-windows-tests pyoxidizer-macos-tests \
	$(packaging_targets) \
	pytype-docker
