# Task 3 report

## Summary

Implemented canonical VIO placement normalization, frozen defensive plan/query objects, PF/VF candidate selection, water-level balancing, and selected VF-template materialization.

## Files

- `dpu_common/src/dpu_normalized_placement_plan.sv`
- `dpu_common/src/dpu_placement_normalizer.sv`
- `dpu_common/src/dpu_resource_pkg.sv`
- `dpu_common/tests/dpu_placement_test.sv`

## RED

After adding selection-policy tests, staged with `rsync -a --delete --exclude .git --exclude build --exclude csrc ./ ubuntu@10.11.10.53:/home/ubuntu/test_cosim/virtio-vio-qpair-placement/` and ran `ssh ubuntu@10.11.10.53 "bash -lic 'cd /home/ubuntu/test_cosim/virtio-vio-qpair-placement && TEST=dpu_placement_test ./scripts/vcs.sh'"`. VCS failed as expected with undefined `dpu_normalized_placement_plan` and unknown `dpu_placement_normalizer`.

## Focused GREEN

Ran VCS compile and `build/simv +UVM_TESTNAME=dpu_placement_test +UVM_VERBOSITY=UVM_LOW +UVM_NO_RELNOTES` on ubuntu@10.11.10.53; VCS and simulation exited zero and `scripts/strict_log_check.sh sim build/strict/dpu_placement_test.log` accepted the log.

## Full regression

Ran `bash -lic 'cd /home/ubuntu/test_cosim/virtio-vio-qpair-placement && ./scripts/strict_regression.sh'` serially on ubuntu@10.11.10.53. The maintained test logs were subsequently checked with `strict_log_check.sh`; all 22 logs passed (`CHECK_RC:0`).

## Self-review and concerns

Task 3 temporary rejection guards remain for SEEDED_RANDOM, nonempty constraints, and nonempty overrides. Advanced semantics are intentionally deferred to Task 4. No BDF/BAR or qid resolution was added.

## Commit

See the implementation commit recorded below.

## Fix round 1

Added a global-capacity admission check across ascending request resolution, an explicit invalid-candidate-kind rejection, canonical target/pair sorting in the frozen-plan copy path, and complete `26/25/25/25` coverage for the 101-qpair case. Empty-request plan capacities are defined as zero. The diagnostic helper now accepts its already-created diagnostic by `ref`, which avoids VCS clearing the handle on a rejection path.

RED command: `ssh ubuntu@10.11.10.53 "bash -lic 'cd /home/ubuntu/test_cosim/virtio-vio-qpair-placement && TEST=dpu_placement_test ./scripts/vcs.sh >build/strict/task3_fix_round1_red.log 2>&1'"`. It compiled and failed at `dpu_placement_test.sv(221)` with `UVM_FATAL ... global qpair capacity overflow was accepted`.

Focused GREEN command: `ssh ubuntu@10.11.10.53 "bash -lic 'cd /home/ubuntu/test_cosim/virtio-vio-qpair-placement && TEST=dpu_placement_test ./scripts/vcs.sh >build/strict/task3_fix_round1_green.log 2>&1'"`, followed by `./scripts/strict_log_check.sh sim build/strict/task3_fix_round1_green.log`; VCS exit was zero, UVM errors/fatals were zero, and strict-log check passed.

Full serial regression command: `ssh ubuntu@10.11.10.53 "bash -lic 'cd /home/ubuntu/test_cosim/virtio-vio-qpair-placement && ./scripts/strict_regression.sh >build/strict/task3_fix_round1_full.log 2>&1'"`. Result: `STRICT_REGRESSION PASS tests=22`.

Fix-round commit: pending.
