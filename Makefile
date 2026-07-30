TEST ?= virtio_unit_test
TESTS := virtio_unit_test virtio_stress_unit_test virtio_protocol_test virtio_e2e_test virtio_full_integration_test

.PHONY: bootstrap check-deps compile test regression

bootstrap:
	./scripts/bootstrap.sh

check-deps:
	./scripts/check_deps.sh

compile:
	TEST="$(TEST)" ./scripts/vcs.sh --compile-only

test:
	TEST="$(TEST)" ./scripts/vcs.sh

regression:
	@set -e; \
	for test_name in $(TESTS); do \
		$(MAKE) --no-print-directory test TEST=$$test_name; \
	done
