# Postgres tests

These tests check the `helm/postgres` chart and the PostgresCluster it deployed.

```
tests/
  test-postgres.sh          runner: runs every test, prints a summary, writes JUnit
  postgres/
    lib.sh                  shared settings and helpers (sourced, not a test)
    01-helm_lint.sh         one script per test, run in NN order
    ...
    13-backup_to_s3.sh
```

**Run one test on its own.** Each script is self-contained and can be run from
any directory. It prints what it checked and ends with `PASS:`, `FAIL:` or
`SKIP:`, and its exit code is 0 (pass), 1 (fail) or 77 (skipped):

```bash
./tests/postgres/09-connect_primary.sh
```

**Run them together**, for example in CI:

```bash
./tests/test-postgres.sh                        # all tests
./tests/test-postgres.sh connect_primary backups   # only these
./tests/test-postgres.sh --list                 # names and descriptions
./tests/test-postgres.sh --junit report.xml     # also write a JUnit XML report
```

```text
  test-postgres.sh [names] [--junit FILE]
     │
     ▼
  find tests/postgres/NN-*.sh   (all, or only the named ones)
     │
     ▼
  ┌─ for each test, in NN order ─────────────────────────────────────────┐
  │ bash NN-name.sh in its own process, under a timeout                  │
  │ (its "# timeout:" header, or TEST_TIMEOUT)                           │
  │    │                                                                 │
  │    ├─ exit 0 ────────────────────▶ --- PASS                          │
  │    ├─ exit 77 ───────────────────▶ --- SKIP                          │
  │    └─ exit 1, 124 (timed out), ──▶ --- FAIL                          │
  │       or anything else              + ::error under GitHub Actions   │
  └──┬───────────────────────────────────────────────────────────────────┘
     │  after the last test
     ▼
  summary table, plus a JUnit XML file with --junit
  exit 1 if any test failed, otherwise 0
```

The runner executes each script in a separate process with a timeout. It prints
the script's output under `=== RUN` and then `--- PASS`, `--- FAIL` or
`--- SKIP`, and a summary table at the end. A failure never changes another
test's result. The exit code is 1 if any test failed; skipped tests do not
count as failures.

**To add a test,** copy an existing script and give it the next number. Name
it `NN-name.sh` and make it source `lib.sh`. Line 2 holds the description that
`--list` shows. A test that needs longer than `TEST_TIMEOUT` declares
`# timeout: <seconds>` in its header, as `13-backup_to_s3.sh` does. The runner
picks up new scripts automatically.

| Test | Checks |
|------|--------|
| `helm_lint` | `helm lint --strict` on the chart |
| `helm_template` | the rendered chart is accepted by the API server in a server-side **dry run**. This catches values that do not match the CRD schema, such as `imagePullSecrets: [name]`, which `helm lint` lets through. Nothing is changed. |
| `cluster_ready` | the PostgresCluster status shows every instance set and pgBouncer fully ready |
| `pods_running` | the expected number of Postgres, repo-host and pgBouncer pods exist, are `Running`, and every container is ready. Completed Job pods are ignored. |
| `pvcs_bound` | one data PVC per instance, plus one PVC per volume-backed pgBackRest repo, all `Bound` |
| `primary_elected` | exactly one pod has `role=master` |
| `postgres_ready` | `pg_isready` on every instance; the primary is read-write and replicas are in recovery |
| `replication` | every replica is streaming (skipped for a single instance) |
| `connect_primary` | the app user from `pg1-pguser-pg1` logs in over TCP to the primary Service, with TLS required |
| `connect_pgbouncer` | the same login through the pgBouncer Service (skipped if pgBouncer is off) |
| `read_write` | writes and reads back a row in a temp table; nothing is kept |
| `backups` | the pgBackRest stanza exists, WAL archiving is succeeding, and at least one backup exists |
| `backup_to_s3` | creates a 1000-row table and takes a **full backup to the S3 repo** (repo2, Garage). It then checks that the backup's stop LSN is past the table's commit, so a restore contains the table. It also checks that `backup.manifest` is in the bucket, and runs `pgbackrest verify` to re-read every file from S3 and compare checksums. |

`backup_to_s3` is the only test that changes anything: the table is dropped
afterwards, but the backup is kept and expires under the repo's retention
(`repo2-retention-full`). Running it on a schedule therefore adds full backups,
and you may want a lower retention for CI-only runs. It has its own timeout,
`# timeout: 900` (only applied when run through the runner). It creates the table as `postgres`, because since
Postgres 15 ordinary users cannot create tables in the `public` schema.

The connection tests run `psql` from a replica pod, so the connection crosses the
pod network. The password is read from the Secret and passed on stdin, so it never
appears on a command line or in CI logs.

## Testing a fresh install (`test-instance.sh`)

By default the tests check an existing cluster (`pg1`). To test the chart itself
from a clean install, without touching `pg1`, use `test-instance.sh`:

```bash
./tests/test-instance.sh run                      # create, run all tests, delete
./tests/test-instance.sh run --junit report.xml   # arguments go to test-postgres.sh
KEEP=1 ./tests/test-instance.sh run               # leave it running afterwards to debug
./tests/test-instance.sh up                       # only create it (and wait for ready)
./tests/test-instance.sh status                   # show its cluster, pods and PVCs
./tests/test-instance.sh down                     # delete it
```

```text
  test-instance.sh run [args]
   │
   ├─ up
   │   1  create namespace pg-test and label it as made by this script
   │   2  copy Secrets:  crunchy-regcred
   │                     pg1-pgbackrest-s3 ─▶ pgtest-pgbackrest-s3
   │   3  helm install pgtest   (values.yaml + test overrides;
   │                             bucket, endpoint, region read from pg1)
   │        └─▶ the operator creates instances, pgBouncer, repo host, PVCs,
   │            stanzas on repo1 and repo2, and an initial backup to repo1
   │            (repo2 path: /pgbackrest/pg-test/pgtest/repo2)
   │   4  every 5s, up to READY_TIMEOUT: wait until instances and pgBouncer
   │      are ready, both stanzas exist, and the initial backup is done
   │
   ├─ tests
   │   5  test-postgres.sh [args] with NS=pg-test CLUSTER=pgtest
   │
   ├─ down   (skipped with KEEP=1)
   │   6  helm uninstall, then delete the namespace (only if it has the label)
   │   7  aws s3 rm --recursive s3://<bucket>/pgbackrest/pg-test/pgtest/
   │
   └─ exit with the tests' exit code
```

`up` does the following:

1. Creates namespace `pg-test` and labels it as made by this script.
2. Copies in the two Secrets the cluster needs: the Crunchy image pull secret
   `crunchy-regcred`, and the S3 credentials (as `pgtest-pgbackrest-s3`).
3. Installs `helm/postgres` as release `pgtest`. The chart's own `values.yaml` is
   used, with overrides for 2 instances and 1 pgBouncer, retention 1 and no
   backup schedules. The S3 bucket, endpoint and region are copied from `pg1`'s
   spec. repo2 uses its own path, `/pgbackrest/pg-test/pgtest/repo2`, so test
   backups never mix with `pg1`'s.
4. Waits, for up to `READY_TIMEOUT` (600s), until:
   - every instance and pgBouncer is ready;
   - both repos have a stanza;
   - the operator's initial backup has finished.

   It prints progress as it goes. On a timeout it prints the pods and recent
   events.

`down` does the following:

1. Uninstalls the release and deletes the namespace, including its PVCs.
2. Removes the cluster's path from the bucket, using an `aws-cli` pod run against
   Garage directly.

It **refuses to delete a namespace that this script did not label**, and
`TEST_NS` can never be the source namespace. `run` always runs `down` at the
end, even when tests fail, unless `KEEP=1`. It exits with the tests' exit code.

A run takes about 3–4 minutes, most of it waiting for the initial backup. The
operator must watch all namespaces; yours does, because `PGO_NAMESPACE` is unset.

Settings: `TEST_NS=pg-test`, `CLUSTER=pgtest`, `TEST_REPLICAS=2`,
`SRC_NS=crunchy-postgres`, `SRC_CLUSTER=pg1`, `PULL_SECRET=crunchy-regcred`,
`READY_TIMEOUT=600`, `KEEP=0`.

## Configuration

Environment variables, with defaults:

- `NS=crunchy-postgres`
- `CLUSTER=pg1`
- `CHART_DIR=helm/postgres`
- `USER_SECRET=<cluster>-pguser-<cluster>`
- `STANZA=db` (pgBackRest stanza)
- `TEST_TIMEOUT=120` (runner only; seconds per test without its own `# timeout:`)

## CI

The runner needs `bash`, `kubectl`, `helm`, `python3` and a kubeconfig for the
cluster. Its identity needs permission to:

- `get`/`list` postgresclusters, pods, PVCs and secrets in the namespace;
- create `pods/exec`;
- `patch` postgresclusters, for the dry run.

When run under GitHub Actions, each failure is also emitted as an `::error`
annotation.

```yaml
- name: Postgres tests
  run: ./tests/test-instance.sh run --junit postgres-tests.xml   # or test-postgres.sh to check pg1 itself
- name: Publish test report
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: postgres-tests
    path: postgres-tests.xml
```

GitLab, Jenkins and most other CI systems read the same JUnit file natively.
