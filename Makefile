TEST ?= virtio_unit_test

.PHONY: bootstrap check-deps dependency-contract compile test regression strict-regression

bootstrap:
	./scripts/bootstrap.sh

dependency-contract:
	bash ./scripts/tests/external_net_packet_test.sh

check-deps: dependency-contract
	./scripts/check_deps.sh

compile:
	TEST="$(TEST)" ./scripts/vcs.sh --compile-only

test:
	TEST="$(TEST)" ./scripts/vcs.sh

regression strict-regression:
	./scripts/strict_regression.sh
