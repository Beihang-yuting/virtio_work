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
