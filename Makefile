DEPS_ARGS ?=

deps:
	bash scripts/install_deps.sh $(DEPS_ARGS)

release:
	bash build.sh release

install: release
	bash scripts/install_as_pylib.sh

develop:
	bash build.sh develop
	bash scripts/install_as_pylib.sh

test: proto develop
	bash build.sh test

clean:
	rm -rf build

.PHONY: deps release install develop test clean
