# Garage S3 + Caddy TLS proxy for pgBackRest

`setup-garage-s3.sh` stands up an S3-compatible object store (Garage) inside the
`crunchy-postgres` namespace, puts an HTTPS proxy (Caddy) in front of it, and
verifies the result. The goal is to give the `pg1` cluster an S3 backup
repository (`repo2`) alongside its existing PVC repository (`repo1`).

> **Status:** working end to end. `pg1` backs up to Garage as `repo2`. Verified
> on 2026-11-18:
> - full backups complete;
> - WAL archives to both repos;
> - `pgbackrest verify` re-reads backups from S3 with matching checksums;
> - `pgbackrest expire` deletes old backups and WAL from the bucket.
>
> Re-check any time with `./tests/test-postgres.sh backups backup_to_s3`
> (see `tests/README.md`).

To set up Garage and Caddy by hand, without the script and without any Postgres
steps, see [GARAGE-CADDY-SETUP.md](GARAGE-CADDY-SETUP.md).

## How backups flow

```text
  WAL archiving (continuous)

    Primary ── archive-push ──┬──▶ Repo host pg1-repo-host-0 ──▶ repo1  PVC 1Gi
                              │
                              └──▶ Caddy :443 ──▶ Garage :3900 ──▶ repo2  bucket my-bucket
                                   HTTPS,         HTTP
                                   verify off

  Backups (on schedule)

    CronJob ── start ──▶ Repo host ◀── data files ── Primary
                             │
                             ├──▶ repo1                       pg1-repo1-full: daily full
                             │
                             └──▶ Caddy ──▶ Garage ──▶ repo2  pg1-repo2-full: weekly full
                                                              pg1-repo2-diff: daily differential

  S3 keys:  Secret pg1-pgbackrest-s3 (repo2-s3-key, repo2-s3-key-secret),
            added to the pgBackRest config on the primary and the repo host.
  Replica:  streams WAL from the primary; it does not archive.
```

- **WAL goes to both repos.** Every WAL segment is archived to repo1 and to repo2.
- **Backups follow the schedules in `values.yaml`.** repo1 gets a daily full
  backup. repo2 gets a weekly full backup and a differential on the other days.
- **A restore can use either repo.**

## Why two components

- **Garage** serves the S3 API over plain HTTP only. It has no TLS support and
  expects a reverse proxy for HTTPS.
- **pgBackRest only speaks HTTPS to S3.** It cannot be pointed at an `http://`
  endpoint, so something has to terminate TLS in front of Garage.
- **Caddy** does that. The chart generates a self-signed certificate, so
  pgBackRest runs with `repoN-storage-verify-tls: "n"`: traffic is encrypted but
  the certificate is not validated.

If you move to EDB/CloudNativePG, none of this proxy is needed: Barman Cloud
accepts a plain `http://` endpoint, so it can talk to Garage directly.

## Prerequisites

- `kubectl` and `helm` (v4 was used) pointed at the target cluster.
- `python3` (used to build one JSON snippet for the test pods).
- Cluster can pull from `ghcr.io` (charts and images) and Docker Hub
  (`amazon/aws-cli` for the test pods).
- The `crunchy-postgres` namespace exists (override with `NS=...`).

## Usage

Run from the repo root.

```bash
./scripts/setup-garage-s3.sh up        # install/upgrade Garage + Caddy, verify, print the pg1 snippet
./scripts/setup-garage-s3.sh test      # verify only
./scripts/setup-garage-s3.sh secret    # create the pgBackRest S3 secret for pg1
./scripts/setup-garage-s3.sh snippet   # print the pg1 values.yaml block
./scripts/setup-garage-s3.sh down      # uninstall both AND delete Garage's PVC (asks first)
```

Everything is overridable with environment variables, for example
`NS=other BUCKET=backups GARAGE_SIZE=100G ./scripts/setup-garage-s3.sh up`.
Defaults are at the top of the script (namespace, bucket, release names, chart
versions, `PG_CLUSTER`, and `REPO`, the pgBackRest repo number).

## What each step does

### `up`

1. **Garage install.**
   `helm install objstore oci://ghcr.io/quenchworks/charts/garage` with
   `config.defaultBucket=my-bucket` and `persistence.size=50G`. On first boot the
   chart bootstraps a single-node layout, creates an admin key and the bucket,
   grants the key on the bucket, and stores the key in the Secret
   `objstore-garage` (`access-key`, `secret-key`, plus RPC and admin tokens).
   Before installing, the script **refuses to continue if the PVC
   `data-objstore-garage-0` already exists** (see
   [Stale PVC](#stale-pvc-secret-and-garage-disagree)).
   If the release already exists it is left alone.
   It then sets the **layout capacity** to `GARAGE_CAPACITY` (default 45G). The
   chart bootstraps the layout with 1G whatever the PVC size, so without this
   Garage fills up after about 1 GB. The step only applies a new layout when the
   value changes, and can be run on its own with `capacity`.
2. **Caddy install.**
   `helm upgrade --install my-caddy oci://ghcr.io/quenchworks/charts/caddy` with
   generated values:
   - a Caddyfile on `:8080` that proxies to `objstore-garage:3900`, except that
     requests from kubelet (`User-Agent: kube-probe*`) get a direct `200 ok`
     (see [Health probes](#health-probes-and-the-403));
   - `tls.enabled: true`, which makes the chart add an `:8443` site using a
     Helm-generated CA and certificate that proxies to the `:8080` site;
   - `tls.selfSigned.validityDays` (`CADDY_CERT_DAYS`, default 3650 = 10 years), so
     the chart's self-signed certificate does not expire after the chart's default
     of one year;
   - `service.httpsPort: 443`, so the Service exposes HTTPS on 443 and clients do
     not need a port number.
3. **Verify** (same as `test`).
4. **Print** the `pgBackRestConfig` snippet for `pg1`.

### `test` (verify)

Nothing here modifies configuration; it writes and deletes a small test object.

1. The access key ID in the `objstore-garage` Secret appears in
   `garage key list` inside the pod.
2. The secret key in the Secret matches the one Garage is running with. It
   compares SHA-256 hashes, so the value is never printed.
3. The bucket exists.
4. A throwaway `amazon/aws-cli` pod does list / put / get / delete directly
   against `http://objstore-garage:3900`.
5. The same pod does list / put / get over `https://my-caddy-caddy.crunchy-postgres.svc`
   with `--no-verify-ssl`, and removes the test object directly against Garage
   (see [DELETE through Caddy](#delete-through-caddy)).

The test pods read credentials via `secretKeyRef`, so keys never appear in the
pod spec, on the command line or in shell history.

### `secret`

Creates Secret `pg1-pgbackrest-s3` containing an `s3.conf` file:

```ini
[global]
repo2-s3-key=<access key>
repo2-s3-key-secret=<secret key>
```

The key prefix must match the repo number (`REPO`, default `repo2`). It uses
`kubectl apply`, so re-running it updates the secret in place. It must be re-run
whenever Garage's key changes.

### `snippet`

Prints a `pgBackRestConfig` block for the `postgres` chart's `values.yaml`:

- `configuration` references the `pg1-pgbackrest-s3` Secret.
- `global` sets `repo2-s3-uri-style: path` (Garage needs path-style URLs),
  `repo2-storage-verify-tls: "n"` (self-signed cert), a repo path, and retention:
  keep 2 full backups on repo1 (a 1Gi PVC) and 4 on repo2.
- `manual` makes repo2 the target of an annotation-triggered backup.
- `repos` restates `repo1` (the existing PVC repo), with a daily full backup at
  01:00. It adds `repo2` pointing at bucket `my-bucket`, endpoint
  `my-caddy-caddy.crunchy-postgres.svc`, region `garage`. repo2 gets a weekly
  full backup (Sunday 02:00) and a differential backup on the other days. Without
  `schedules`, the operator takes no recurring backups at all.

`helm/postgres/values.yaml` already contains this block for `pg1`.

`pgBackRestConfig` **replaces** the chart's default backup block, which is why
`repo1` has to be written out again. Paste the block into
`helm/postgres/values.yaml`, then apply it yourself:

```bash
helm upgrade pg1 ./helm/postgres -n crunchy-postgres
kubectl -n crunchy-postgres exec pg1-repo-host-0 -c pgbackrest -- pgbackrest info
```

This reconfigures `pg1`'s backups, which is why the script never does it for you.
Expect `repo2` to appear with a stanza status of `ok`.

### `down`

Asks you to type the namespace, then uninstalls both releases and deletes the PVC
`data-objstore-garage-0`. **All objects stored in Garage are lost.**

## Problems this setup works around

### Stale PVC: secret and Garage disagree

Symptom: S3 calls return `403 Forbidden: No such key: GK...`, and the Garage log
says `already bootstrapped, skipping layout/key setup`.

A StatefulSet's PVC survives `helm uninstall`. If you reinstall over it, Garage
finds the old layout and key and skips bootstrap, but the chart has generated a
new random key in the Secret. The Secret now holds a key Garage does not know.

Fix: delete the PVC along with the release (`down`), then `up`. The script checks
for the PVC before installing and verifies the key afterwards, so it fails loudly
instead of leaving you with a mismatch. The same applies if you ever rotate the
Garage release: update `pg1-pgbackrest-s3` (`secret`) afterwards.

### Health probes and the 403

The Caddy chart's probes do `GET /` on port 8080. Once 8080 proxies to Garage,
an unsigned request to the S3 root returns `403`, the probes fail, and the pod
restarts forever. The Caddyfile answers requests from `kube-probe*` directly and
proxies everything else.

### DELETE through Caddy

A single-object `DELETE` through Caddy fails with
`signed header content-length is not present`. The AWS CLI signs a
`Content-Length: 0` header; Caddy (Go) does not forward it for a body-less
DELETE, so Garage rejects the signature. Uploads, downloads and listings are
unaffected. The script's HTTPS test therefore cleans up directly against Garage.
This explanation is my reading of the symptoms and has not been confirmed against
Caddy's code.

**pgBackRest is not affected.** `pgbackrest expire --repo2-retention-full=1` was run
through Caddy. It removed an expired backup and its WAL from the bucket: the object
count dropped from 2600 to 1299, and no files were left under the removed label.
Only the AWS CLI's single-object delete hits the problem.

### Port 3900 on your workstation

If you port-forward Garage to your machine, check that the local port is free.
A `k9s` port-forward on `localhost:3900` was pointing at a different Garage
(there are others in the `clickhouse` and `demo1` namespaces), which produced
`No such key` errors that looked like bad credentials. Use another local port,
for example `kubectl -n crunchy-postgres port-forward svc/objstore-garage 13900:3900`.

## AWS CLI from your workstation

The Service is cluster-internal, so forward it first, then tell the CLI the
endpoint. Garage uses region `garage` and path-style addressing:

```ini
# ~/.aws/config  (use a named profile if you also use real AWS)
[default]
output = table
region = garage
endpoint_url = http://localhost:13900
s3 =
    addressing_style = path
```

`~/.aws/credentials` takes the `access-key` / `secret-key` values from the
`objstore-garage` Secret.

## Known issues

- **Match pgBackRest versions.** Do not pin `imagePgBackRest` (or the other
  images) in `helm/postgres/values.yaml` unless it matches the operator's
  Postgres image. A 2.51 pin against the 2.59 in Postgres broke WAL archiving
  and stanza creation, for repo1 as well as repo2.
- **Not off-site.** Garage runs in the same cluster, on `local-path` storage on
  one node. It proves the S3 path, but it is not disaster recovery.
- **The proxy is a single point of failure.** If Caddy is down, archiving fails
  and Postgres keeps WAL on disk until it can archive again. Fine for dev; give
  it replicas for anything serious.
- **Self-signed certificate, verification off.** Acceptable inside the cluster.
  The chart generates it (CN `my-caddy-caddy`, issued by `my-caddy-caddy-ca`,
  stored in Secret `my-caddy-caddy-tls`).
  - On a **fresh install** the cert lasts `CADDY_CERT_DAYS`.
  - On an **upgrade** the chart keeps the existing Secret, so an install made
    before this setting existed keeps its one-year cert until the Secret is
    deleted.
  - With verification off, pgBackRest ignores expiry, so expiry only matters if
    verification is turned on.

  For real use, supply a cert via the chart's `tls.existingSecret` or
  `tls.certManager`, and turn `storage-verify-tls` back on.
- **`up` from scratch has not been run end to end** on a clean namespace; the
  `test` mode and the individual steps were run against the live setup.
- **Chart versions are pinned** (Garage 0.0.19, Caddy 0.0.26). Newer versions may
  change value names.
