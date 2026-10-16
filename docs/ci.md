# CI: incremental builds

`.github/workflows/build.yml` builds and checks reproducer x target jobs
(one job: the two OpenZFS builds for that kernel, the images, and a
`--check` of each in a VM) and pushes the pairs that behave as expected.
GitHub's job concurrency is per account, and the same account runs the
openzfs fork CI (wrouesnel/zfs `zfs-qemu`) that gates our upstream pull
requests, so this workflow does as little as it can:

- **Only what changed.** `builder/build.sh inputs ID TARGET` hashes what a
  job's images and checks are made of: the reproducer's directory, its two
  build commits, `CONFIGURE` and `TOOLS`, the target's kernel key, the
  userland key, the runtime, and the scripts that pack the disks
  (`builder/in/*.sh`, `builder/zts-tools.txt`, the layer Containerfiles).
  Every result row records that hash. The plan job reads the results so far
  from the `results` branch and leaves out every job whose images all have a
  result for the same inputs. Editing one reproducer reruns only its jobs; a
  docs change runs nothing. (`builder/build.sh` itself is left out of the
  hash: it orchestrates, it doesn't go into an image.)
- **At most `MAX_JOBS` per run** (40; `workflow_dispatch` takes another
  number), ubuntu24 first: the images every console review pulls. The rest
  wait for the next run. A schedule (every 6 hours) picks them up.
- **The fork comes first.** When the fork's `zfs-qemu` workflow has more
  than two queued runs, a push or scheduled run plans no jobs (a manual
  dispatch still does). The jobs stay owed and run next time.
- `max-parallel` keeps each matrix to a few runners (targets 4, OpenZFS
  userland builds 4, reproducer jobs 5).
- **Full run:** `workflow_dispatch` with `full: true` ignores the recorded
  results (still capped by `max_jobs`; dispatch again until nothing is left).

Every build output is also cached by its own key (builders, userland,
kernels, OpenZFS userland per commit, modules per commit and kernel), so a
job that does run rebuilds only what its key says changed.

## The results branch

After every run on main, the results job merges this run's rows with the
earlier rows of the jobs it didn't run (as long as the reproducer x target
is still built) and commits `results.tsv` and `results.md` to the `results`
branch: the matrix of every reproducer x target, with what the break and the
fix printed and whether the pair is published. Rows:

    ID  TARGET  LABEL  pass|fail|build-failed  TAG  RESULT-LINE  INPUTS

`scripts/merge-results.py` merges, `scripts/results.sh` writes the markdown.
To rerun one job without changing it, delete its rows on the `results`
branch (or dispatch a full run).
