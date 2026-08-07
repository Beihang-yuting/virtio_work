TEST ?= virtio_unit_test

.PHONY: bootstrap check-deps compile test regression strict-regression

bootstrap:
	./scripts/bootstrap.sh

check-deps:
	./scripts/check_deps.sh

compile:
	TEST="$(TEST)" ./scripts/vcs.sh --compile-only

test:
	TEST="$(TEST)" ./scripts/vcs.sh

regression strict-regression:
	./scripts/strict_regression.sh
