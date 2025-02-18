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
PIP_OPTIONS_PURE=--config-settings --global-option="$(PURE)"
PIP_OPTIONS_INSTALL=--no-deps --ignore-installed --no-build-isolation
PIP_PREFIX=$(PREFIX)
PYFILESCMD=find mercurial hgext doc -name '*.py'
PYFILES:=$(shell $(PYFILESCMD))
DOCFILES=mercurial/helptext/*.txt
export LANGUAGE=C
export LC_ALL=C
TESTFLAGS ?= $(shell echo $$HGTESTFLAGS)
CARGO = cargo

VENV_NAME=$(shell $(PYTHON) -c "import sys; v = sys.version_info; print(f'.venv_{sys.implementation.name}{v.major}.{v.minor}')")
PYBINDIRNAME=$(shell $(PYTHON) -c "import os; print('Scripts' if os.name == 'nt' else 'bin')")

.PHONY: help
help:
	@echo 'Commonly used make targets:'
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
	@echo 'See CONTRIBUTING.md for the build and development dependencies.'
	@echo
	@echo 'Example for a system-wide installation under /usr/local for'
	@echo 'downstream packaging (build and runtime deps have to be installed by hand)'
	@echo '  su -c "make install" && hg version'
	@echo
	@echo 'Example for a system-wide installation under /usr/local:'
	@echo '  make doc'
	@echo '  su -c "make install PIP_OPTIONS_INSTALL=" && hg version'
	@echo
	@echo 'On some Linux distributions, you might need to specify both'
	@echo 'PREFIX and PIP_PREFIX (here to install everything in /data/local)'
	@echo '  make install PREFIX=/data/local PIP_PREFIX=/data PIP_OPTIONS_INSTALL='
	@echo
	@echo 'Example for a local installation (usable in this directory):'
	@echo '  make local && ./hg version'

.PHONY: local
local:
	$(PYTHON) -m venv $(VENV_NAME) --clear --upgrade-deps
	$(VENV_NAME)/$(PYBINDIRNAME)/python -m \
	  pip install -e . -v $(PIP_OPTIONS_PURE)
	env HGRCPATH= $(VENV_NAME)/$(PYBINDIRNAME)/hg version

.PHONY: build-chg
build-chg:
	make -C contrib/chg

.PHONY: build-rhg
build-rhg:
	(cd rust/rhg; cargo build --release)

.PHONY: wheel
wheel:
	$(PYTHON) -m build --config-setting=--global-option="$(PURE)"
.PHONY: doc
doc:
	$(MAKE) -C doc

.PHONY: cleanbutpackages
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

.PHONY: clean
clean: cleanbutpackages
	rm -rf packages

.PHONY: install
install: install-bin install-doc

.PHONY: install-bin
install-bin:
	$(PYTHON) -m pip install . --prefix="$(PIP_PREFIX)" --force -v $(PIP_OPTIONS_PURE) $(PIP_OPTIONS_INSTALL)

.PHONY: install-chg
install-chg: build-chg
	make -C contrib/chg install PREFIX="$(PREFIX)"

.PHONY: install-doc
install-doc:
	$(MAKE) -C doc $(MFLAGS) PREFIX="$(PREFIX)"  install

.PHONY: install-home
install-home: install-home-bin install-home-doc

.PHONY: install-home-bin
install-home-bin:
	$(PYTHON) -m pip install . --user --force -v $(PIP_OPTIONS_PURE) $(PIP_OPTIONS_INSTALL)

.PHONY: install-home-doc
install-home-doc:
	$(MAKE) -C doc $(MFLAGS) PREFIX="$(HOME)" install

.PHONY: install-rhg
install-rhg: build-rhg
	install -m 755 rust/target/release/rhg "$(PREFIX)"/bin/

.PHONY: dist
dist: tests dist-notests

.PHONY: dist-notests
dist-notests:	doc
	TAR_OPTIONS="--owner=root --group=root --mode=u+w,go-w,a+rX-s" $(PYTHON) -m build --sdist

.PHONY: check
check: tests

.PHONY: tests
tests:
	# Run Rust tests if cargo is installed
	if command -v $(CARGO) >/dev/null 2>&1; then \
		$(MAKE) rust-tests; \
		$(MAKE) cargo-clippy; \
	fi
	cd tests && $(PYTHON) run-tests.py $(TESTFLAGS)

.PHONY: test-%
test-%:
	cd tests && $(PYTHON) run-tests.py $(TESTFLAGS) $@

.PHONY: testpy-%
testpy-%:
	@echo Looking for Python $* in $(HGPYTHONS)
	[ -e $(HGPYTHONS)/$*/bin/python ] || ( \
	cd $$(mktemp --directory --tmpdir) && \
        $(MAKE) -f $(HGROOT)/contrib/Makefile.python PYTHONVER=$* PREFIX=$(HGPYTHONS)/$* python )
	cd tests && $(HGPYTHONS)/$*/bin/python run-tests.py $(TESTFLAGS)

.PHONY: rust-tests
rust-tests:
	cd $(HGROOT)/rust \
		&& $(CARGO) test --quiet --all \
		--features "$(HG_RUST_FEATURES)" --no-default-features

.PHONY: cargo-clippy
cargo-clippy:
	cd $(HGROOT)/rust \
		&& $(CARGO) clippy --all --features "$(HG_RUST_FEATURES)" -- -D warnings

.PHONY: check-code
check-code:
	hg manifest | xargs python contrib/check-code.py

.PHONY: format-c
format-c:
	clang-format --style file -i \
	  `hg files 'set:(**.c or **.cc or **.h) and not "listfile:contrib/clang-format-ignorelist"'`

.PHONY: update-pot
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
.PHONY: $(packaging_targets)
$(packaging_targets):
	$(MAKE) -C contrib/packaging $(MAKEFLAGS) $@


.PHONY: pyoxidizer
pyoxidizer:
	$(PYOXIDIZER) build --path ./rust/hgcli --release


# a temporary target to setup all we need for run-tests.py --pyoxidizer
# (should go away as the run-tests implementation improves
.PHONY: pyoxidizer-windows-tests
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
.PHONY: pyoxidizer-macos-tests
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

.PHONY: pytype-docker
pytype-docker:
	contrib/docker/pytype/recipe.sh
