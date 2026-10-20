# Builds

The images used to be built by a GitHub Actions workflow here
(`.github/workflows/build.yml`). It was removed on 2026-10-20. GitHub's job
concurrency is per account, and the same account runs the openzfs fork CI
(wrouesnel/zfs `zfs-qemu`) that gates our upstream pull requests, so image
builds were taking runners from it.

Images are now built, checked and pushed from the maintainer's machine, with
the same script the workflow ran:

    builder/build.sh all USER/SLUG [TARGET...]          # build, then --check each pair
    builder/build.sh push USER/SLUG TARGET [LABEL...]   # only after both checks pass

`scripts/build-local.sh [TARGET...]` runs every committed reproducer that way,
one job at a time (ubuntu24 first), skipping images already on GHCR, and logs
to `work/local/`. A pair is pushed only when the break prints its expected `RESULT BUG` and the
fix prints `RESULT OK` on that kernel, as before.

Two workflows remain, and neither builds anything:

- `aliases.yml` (daily, and by hand) points the `repro-prN-...` and
  `fixed-issueN-...` alias tags at published images (`scripts/aliases.py`).
- `retire-tags.yml` (by hand) deletes tags that a newer image replaces.

The `results` branch (`results.tsv`, `results.md`) was written by the removed
workflow and is no longer updated. `builder/build.sh check` still appends rows
to `RESULTS_FILE` when it is set, and `scripts/results.sh RESULTS.tsv` turns
them into the matrix. [index.md](index.md) is regenerated with
`scripts/index.sh`, which reads the published tags from GHCR.
