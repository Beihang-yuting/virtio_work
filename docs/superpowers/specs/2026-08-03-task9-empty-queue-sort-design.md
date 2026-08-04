# Task 9 empty-queue migration-sort warning

## Goal

Remove VCS's `Warning-[DT-MCEQ] Method called on empty queue` from the Task 9
migration restore regression without changing migration ownership semantics.

## Cause

`virtio_atomic_ops::claim_restored_queue_ownership()` unconditionally calls
`claim_indices.sort()`. Queues with neither an indirect table nor an explicit
`dma_map_buf()` mapping produce an empty `claim_indices` queue. VCS reports the
warning even though the following delete loop performs no work.

## Design

Only sort when more than one claim index exists. Zero and one index already
have the required order, so the existing highest-to-lowest deletion behavior
is unchanged for all non-empty multi-mapping cases.

## Verification

1. Rebuild and run `virtio_migration_dirty_test` on `ubuntu@10.11.10.53`.
   The red check is that its log currently contains `Warning-[DT-MCEQ]`.
2. Apply the one-condition guard and repeat the migration run. Require exit
   status zero, no `DT-MCEQ` warnings, and final UVM warning/error/fatal counts
   all zero.
3. Rebuild and run `virtio_protocol_test` on the same host. Require exit
   status zero and final UVM warning/error/fatal counts all zero.

## Non-goals

This does not change queue ownership transfer, descriptor tokens, mapping
materialization, sort order for multiple claims, or unrelated VCS compile
warnings.
