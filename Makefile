SHELL := bash
.PHONY: all lint fmt test smoke check release

all: lint test

lint:
	shellcheck --version >/dev/null
	shellcheck bootstrap.sh tests/*.bash tests/*.sh
	shfmt -d -i 2 -ci bootstrap.sh tests/

fmt:
	shfmt -w -i 2 -ci bootstrap.sh tests/

test:
	bats tests/unit

smoke:
	bash tests/run-smoke.sh

check:
	BOOTSTRAP_LIB_ONLY=1 bash bootstrap.sh
	bash -n bootstrap.sh

release:
	@test -n "$(V)" || { echo "usage: make release V=2.0.1"; exit 1; }
	sed -i 's/^readonly SCRIPT_VERSION=.*/readonly SCRIPT_VERSION="$(V)"/' bootstrap.sh
	git commit -am "release v$(V)"
	git tag -s "v$(V)" -m "v$(V)"
	git push --follow-tags
