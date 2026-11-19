# Garage + Caddy: manual setup

## TL;DR

This is a fresh install with the names this repo uses: namespace
`crunchy-postgres`, bucket `my-bucket`. If you are reinstalling, read
[Reinstalling over an old PVC](#reinstalling-over-an-old-pvc) first.

**1. Install Garage.** This creates the bucket and a key, and stores the key in
Secret `objstore-garage`.

```bash
helm install objstore oci://ghcr.io/quenchworks/charts/garage --version 0.0.19 \
  -n crunchy-postgres --set config.defaultBucket=my-bucket --set persistence.size=50G
```

**2. Raise the capacity from the chart's 1G.** Open a shell in the Garage pod and
run:

```bash
kubectl -n crunchy-postgres exec -it objstore-garage-0 -- sh

garage status                                  # copy the node ID (first column)
garage layout assign -z dc1 -c 45G <node-id>
garage layout show                             # prints the exact "apply --version N" to run
garage layout apply --version <N>
exit
```

**3. Install Caddy.** Only needed if a client requires HTTPS, as pgBackRest does.
Save the values in [step 4](#4-install-caddy-https-in-front-of-garage) as
`caddy-values.yaml`, then run:

```bash
helm install my-caddy oci://ghcr.io/quenchworks/charts/caddy --version 0.0.26 \
  -n crunchy-postgres -f caddy-values.yaml
```

**4. Check it:**

```bash
kubectl -n crunchy-postgres exec objstore-garage-0 -- garage bucket info my-bucket
./scripts/setup-garage-s3.sh test
```

Point clients at `https://my-caddy-caddy.crunchy-postgres.svc` with region
`garage`, path-style addressing and TLS verification off. The keys are in Secret
`objstore-garage` (`access-key`, `secret-key`); see
[Connection details for clients](#connection-details-for-clients).

`./scripts/setup-garage-s3.sh up` does all of this in one command.

## Contents

- [TL;DR](#tldr)
- [What Garage is](#what-garage-is)
- [This setup](#this-setup)
  - [Do you need Caddy?](#do-you-need-caddy)
- [Names and commands used below](#names-and-commands-used-below)
- [Steps at a glance](#steps-at-a-glance)
- [1. Install Garage](#1-install-garage)
- [2. Set the layout capacity](#2-set-the-layout-capacity)
- [3. Bucket and key](#3-bucket-and-key)
- [4. Install Caddy (HTTPS in front of Garage)](#4-install-caddy-https-in-front-of-garage)
- [5. Verify](#5-verify)
- [Connection details for clients](#connection-details-for-clients)
- [The helper script: setup-garage-s3.sh](#the-helper-script-setup-garage-s3sh)
- [Troubleshooting](#troubleshooting)
  - [Reinstalling over an old PVC](#reinstalling-over-an-old-pvc)
  - [Writes fail after about 1 GB](#writes-fail-after-about-1-gb)
  - [layout apply fails, or nothing changes](#layout-apply-fails-or-nothing-changes)
  - [Lost a key's secret](#lost-a-keys-secret)
  - [Caddy pod keeps restarting](#caddy-pod-keeps-restarting)
  - [signed header content-length is not present](#signed-header-content-length-is-not-present)
  - [No such key from your workstation](#no-such-key-from-your-workstation)
- [Advanced: replicating across clusters (COOP)](#advanced-replicating-across-clusters-coop)
  - [Choosing an approach](#choosing-an-approach)
  - [Connecting the two clusters](#connecting-the-two-clusters)
  - [Approach 1: clients write to both sites (Postgres)](#approach-1-clients-write-to-both-sites-postgres)
  - [Approach 2: scheduled bucket sync (rclone)](#approach-2-scheduled-bucket-sync-rclone)
  - [Approach 3: one Garage cluster across sites](#approach-3-one-garage-cluster-across-sites)
  - [Failing over to site B (approaches 1 and 2)](#failing-over-to-site-b-approaches-1-and-2)
- [Removing it](#removing-it)

## What Garage is

[Garage](https://garagehq.deuxfleurs.fr/) is an open-source object store that
speaks the Amazon S3 API. Any tool that can write to S3 can write to Garage
instead: pgBackRest, the AWS CLI, restic, rclone, Velero and others. It is
written in Rust, ships as one binary, and is developed by Deuxfleurs, a French
non-profit that runs its own hosting on second-hand machines. It is licensed
under the AGPL v3.

It was designed for small, self-hosted setups:

- **Low resources.** It runs comfortably on a few hundred MB of RAM and on
  ordinary disks, so it fits in a homelab or a dev cluster.
- **Built for unreliable, spread-out machines.** You give each node a zone and a
  capacity. Garage stores each object on several nodes in different zones (the
  *replication factor*, usually 3), so a node or a whole site can go offline
  without losing data.
- **No central coordinator.** Every node can answer requests. A node's role is
  set by the *layout* (step 2), not by a primary/replica election.
- **Simple to run.** One config file and one CLI (`garage`) for nodes, buckets
  and keys.

**Where it fits best:**

- self-hosted S3 for backups, such as pgBackRest repositories, restic or Velero;
- dev and test clusters that need a real S3 endpoint without a cloud account;
- a homelab or small office, especially with machines in two or three places;
- static website hosting (Garage can serve a bucket as a website).

**Where it is a poor fit:**

- **Workloads that need S3 features Garage lacks.** It implements the common
  calls (put, get, list, multipart uploads, presigned URLs, basic lifecycle
  rules), but not, for example, object versioning, object lock or bucket
  policies. Check the
  [S3 compatibility list](https://garagehq.deuxfleurs.fr/documentation/reference-manual/s3-compatibility/)
  before relying on a feature.
- **Very high-throughput, single-site storage at large scale.** Systems such
  as Ceph or MinIO are built for that.
- **Disaster recovery, when Garage runs in the same cluster as the data it
  protects.** That is the setup in this guide, and it is covered in the next
  section.

## This setup

This guide installs Garage and Caddy by hand:

- **Garage** stores the objects and serves the S3 API over plain HTTP.
- **Caddy** sits in front of Garage and adds HTTPS. It is only needed for
  clients that require HTTPS (see below).

**It is a single node.** It runs with `replication_factor = 1` and the SQLite
metadata engine, so every object has exactly one copy, on one PVC. That is enough
to give pgBackRest a real S3 target and prove the backup path works. It is **not**
an off-site copy, because losing that node or its disk loses the backups. To make
it one, run Garage, or any other S3 store, outside this cluster.

This guide covers only the object store. Connecting Postgres/pgBackRest to it is a
separate step, described in [README.md](README.md#secret). Any S3 client can
use the store once you finish here.

`setup-garage-s3.sh up` runs the same steps automatically. Use this guide to see
what the script does, to debug it, or to build a second store.

```text
  S3 client (pgBackRest, aws-cli, ...)
  credentials: Secret objstore-garage (access-key, secret-key)
                          │
                          │  HTTPS :443, certificate not verified
                          ▼
  ┌─ Caddy · release my-caddy · svc my-caddy-caddy ────────┐
  │ :443  ─▶ :8443  terminate TLS                          │
  │                 (cert in Secret my-caddy-caddy-tls)    │
  │ :8443 ─▶ :8080  plain HTTP                             │
  │ kube-probe* requests get 200 "ok" here                 │
  └───────────────────────┬────────────────────────────────┘
                          │  HTTP :3900 (reverse_proxy)
                          ▼
  ┌─ Garage · release objstore · svc objstore-garage ──────┐
  │ S3 API on :3900                                        │
  │ bucket my-bucket                                       │
  │ data on PVC data-objstore-garage-0                     │
  └────────────────────────────────────────────────────────┘
```

### Do you need Caddy?

**Only if a client insists on HTTPS.** Garage serves S3 over plain HTTP and has
no TLS of its own. Caddy exists only to add HTTPS in front of it.

| Client | Plain `http://` endpoint? | Needs Caddy? |
|---|---|---|
| pgBackRest (Crunchy PGO) | no, HTTPS only | **yes** |
| Barman Cloud (CloudNativePG) | yes | no |
| AWS CLI, rclone, restic, Velero | yes | no |

- **If none of your clients need HTTPS:** skip step 4 and use
  `http://objstore-garage.<NS>.svc:3900` directly. Step 5 already tests this path.
- **If a client needs HTTPS:** keep Caddy.
- **For traffic that leaves the cluster:** consider HTTPS even when it isn't
  required, because plain HTTP sends the request signatures and data
  unencrypted. Inside one cluster it is usually acceptable for dev use.

## Names and commands used below

The commands use this repo's names. Change them if yours differ:

| What | Name |
|---|---|
| Namespace | `crunchy-postgres` |
| Garage Helm release / pod / Service | `objstore` / `objstore-garage-0` / `objstore-garage` |
| Garage PVC | `data-objstore-garage-0` |
| Bucket | `my-bucket` |
| Caddy Helm release / Service | `my-caddy` / `my-caddy-caddy` |

**`garage` commands run inside the Garage pod.** Open a shell there once and run
them as shown:

```bash
kubectl -n crunchy-postgres exec -it objstore-garage-0 -- sh
```

Or run a single command from your machine:

```bash
kubectl -n crunchy-postgres exec objstore-garage-0 -- garage status
```

Requirements:

- `kubectl` and `helm`, pointed at the cluster;
- the cluster can pull from `ghcr.io`;
- the namespace exists (`kubectl create namespace crunchy-postgres`).

## Steps at a glance

```text
  1  helm install Garage      chart creates the layout, bucket, key, Secret
     │
     ▼
  2  Raise layout capacity    1G ─▶ 45G
     │
     ▼
  3  Check bucket and key     optional: an extra bucket with its own key
     │
     ▼
  4  helm install Caddy       TLS on :443 ─▶ Garage :3900   (HTTPS clients only)
     │
     ▼
  5  Verify                   garage status / bucket info, then the test script
     │
     ▼
     Store ready for any S3 client
```

## 1. Install Garage

```bash
helm install objstore oci://ghcr.io/quenchworks/charts/garage --version 0.0.19 \
  -n crunchy-postgres --set config.defaultBucket=my-bucket --set persistence.size=50G
kubectl -n crunchy-postgres rollout status sts/objstore-garage
```

On first boot the chart does the following:

1. Bootstraps a single-node layout.
2. Creates an admin key and the bucket `my-bucket`.
3. Grants the key read, write and owner on the bucket.
4. Stores the key in Secret `objstore-garage`, under the keys `access-key` and
   `secret-key`, along with RPC and admin tokens.

To see every chart option: `helm show values oci://ghcr.io/quenchworks/charts/garage --version 0.0.19`.

Reinstalling? Read [Reinstalling over an old PVC](#reinstalling-over-an-old-pvc) first.

## 2. Set the layout capacity

The chart bootstraps the layout with a capacity of **1G**, whatever the PVC size.
Garage stops accepting writes once that is used up. Set the capacity to a little
below the PVC size. In the Garage pod, run:

```bash
garage status                                  # node ID in the first column; Capacity about 1 GB
garage layout assign -z dc1 -c 45G <node-id>
garage layout show                             # shows the staged change and the version to apply
garage layout apply --version <N>
garage status                                  # Capacity now 41.9 GiB
```

`layout assign` only stages the change, and nothing happens until
`layout apply`. `N` is the current layout version plus one, and `layout show`
prints the exact command.

## 3. Bucket and key

**Check the ones the chart created:**

```bash
garage bucket list
garage bucket info my-bucket       # size, object count, and which keys are allowed
garage key list
```

**Optional: a further bucket with its own key.** You might want one per
application or cluster:

```bash
garage bucket create pg-backups
garage key create pg-backups-key                # prints the Key ID and Secret key
garage bucket allow --read --write --owner pg-backups --key pg-backups-key
garage bucket info pg-backups
```

To store the key for clients, run this from your machine, not in the pod.
Paste in the two values that `key create` printed:

```bash
 kubectl -n crunchy-postgres create secret generic pg-backups-s3 \
   --from-literal=access-key=GK... --from-literal=secret-key=...
```

The leading space keeps the command out of your shell history, as long as
`HISTCONTROL` includes `ignorespace` (the default on Ubuntu). To see a key's
secret again later, use `garage key info pg-backups-key --show-secret`.

Garage docs: [quick start](https://garagehq.deuxfleurs.fr/documentation/quick-start/)
(layout, buckets and keys) and [layout](https://garagehq.deuxfleurs.fr/documentation/operations/layout/).

## 4. Install Caddy (HTTPS in front of Garage)

Garage has no TLS of its own. Caddy provides it, with a certificate that the
chart generates. **Skip this step if all your clients can use plain HTTP**; see
[Do you need Caddy?](#do-you-need-caddy).

Save this as `caddy-values.yaml`:

```yaml
# caddy-values.yaml
config:
  caddyfile: |
    {
    	admin :2019
    }
    :8080 {
    	@kubeprobe header User-Agent kube-probe*
    	handle @kubeprobe {
    		respond "ok" 200
    	}
    	handle {
    		reverse_proxy objstore-garage:3900
    	}
    }
tls:
  enabled: true
  selfSigned:
    validityDays: 3650
service:
  httpsPort: 443
```

Then install:

```bash
helm install my-caddy oci://ghcr.io/quenchworks/charts/caddy --version 0.0.26 \
  -n crunchy-postgres -f caddy-values.yaml
kubectl -n crunchy-postgres rollout status deploy/my-caddy-caddy
```

How Caddy handles a request:

```text
  HTTPS request to svc my-caddy-caddy :443
     │
     ▼
  :8443  terminate TLS (cert in Secret my-caddy-caddy-tls)
     │
     ▼
  :8080  ◀── plain HTTP requests from inside the pod also arrive here
     │
     ├─ User-Agent kube-probe* ──▶ respond 200 "ok"   (kubelet health probe)
     │
     └─ anything else ───────────▶ reverse_proxy objstore-garage:3900 ─▶ Garage
```

What these values do:

- **`:8080`** proxies everything to Garage.
- **The `kube-probe` rule** is needed because the chart's health probes request
  `GET /`. Garage answers an unsigned request with `403`, and without the rule
  the pod would restart forever.
- **`tls.enabled`** makes the chart add an `:8443` site. It uses a Helm-generated
  CA and certificate (Secret `my-caddy-caddy-tls`) and forwards to `:8080`.
- **`validityDays`** keeps the certificate from expiring after the chart's
  default of one year.
- **`httpsPort: 443`** means clients need no port number.

Caddy docs: [reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy),
[tls](https://caddyserver.com/docs/caddyfile/directives/tls). Garage's own
[reverse proxy guide](https://garagehq.deuxfleurs.fr/documentation/cookbook/reverse-proxy/)
includes a Caddy example.

## 5. Verify

**In the Garage pod:**

```bash
garage status                  # the node is healthy, with the new capacity
garage bucket info my-bucket   # the bucket exists and the key has RWO
```

**HTTPS through Caddy** (skip this if you did not install Caddy). An unsigned
request should get `403` back from Garage. That proves TLS and the proxy work.
If you get `502`, Caddy cannot reach Garage.

```bash
kubectl -n crunchy-postgres run curl --rm -i --restart=Never --image=curlimages/curl -- \
  curl -sk -o /dev/null -w '%{http_code}\n' https://my-caddy-caddy.crunchy-postgres.svc/
```

**Full read and write test:**

```bash
./scripts/setup-garage-s3.sh test
```

This changes no configuration. It checks the following:

- the Secret's key exists in Garage, and the secret matches;
- the bucket exists;
- an `aws-cli` pod can list, put, get and delete over HTTP directly against
  Garage;
- the same pod can list, put and get over HTTPS through Caddy.

## Connection details for clients

| Setting | Value |
|---|---|
| Endpoint (HTTPS) | `https://my-caddy-caddy.<NS>.svc` (port 443) |
| Endpoint (HTTP, direct) | `http://objstore-garage.<NS>.svc:3900` |
| Region | `garage` |
| Addressing | **path-style** (Garage does not support virtual-host style here) |
| TLS verification | off (the certificate is self-signed), unless you supply your own |
| Credentials | Secret `objstore-garage`, keys `access-key` / `secret-key` |

For Postgres backups, continue with [README.md](README.md): `secret`, then `snippet`.

## The helper script: `setup-garage-s3.sh`

`scripts/setup-garage-s3.sh` does everything in this guide in one command, and
adds safety checks you would otherwise have to remember. Run it from the repo
root. It is safe to re-run.

| Command | What it does |
|---|---|
| `up` | Install Garage, set the capacity, install or upgrade Caddy, verify, then print a pgBackRest snippet |
| `capacity` | Set the layout capacity only (step 2) |
| `test` | Verify only (step 5); changes no configuration |
| `down` | Uninstall both and delete Garage's PVC, after you type the namespace to confirm |
| `secret` | Postgres side: create the pgBackRest S3 Secret `pg1-pgbackrest-s3` |
| `snippet` | Postgres side: print the `pgBackRestConfig` block for `helm/postgres/values.yaml` |

`secret` and `snippet` belong to connecting Postgres, not to the object store.
They are described in [README.md](README.md#secret).

**What it does for you:**

- **Refuses a reinstall over an old PVC.** If `data-objstore-garage-0` exists
  and there is no Garage release, it stops before installing. This prevents
  the [key mismatch](#reinstalling-over-an-old-pvc).
- **Leaves an existing Garage alone.** `up` never reinstalls or upgrades a
  running Garage. Caddy is upgraded in place (`helm upgrade --install`), so
  re-running `up` applies Caddyfile changes.
- **Sets the capacity only when it changes.** It runs `layout assign`, and
  runs `layout apply` with the right version only if a change was staged. Running
  it again does nothing.
- **Checks that the keys match without printing them.**
  - The access key in Secret `objstore-garage` must appear in `garage key list`.
  - The secret key is compared by SHA-256 hash with the one Garage is running
    with.
- **Tests real S3 traffic.** Throwaway `amazon/aws-cli` pods do list, put, get
  and delete, first directly against Garage and then over HTTPS through Caddy.
  The pods read the keys through `secretKeyRef`, so they never appear on a
  command line, in the pod spec or in your shell history.
- **Asks before deleting data.** `down` makes you type the namespace before
  removing anything.

**Settings.** Every name is an environment variable; the defaults are at the top
of the script:

| Variable | Default | Meaning |
|---|---|---|
| `NS` | `crunchy-postgres` | namespace for both releases |
| `BUCKET` | `my-bucket` | bucket the chart creates |
| `GARAGE_RELEASE` / `CADDY_RELEASE` | `objstore` / `my-caddy` | Helm release names; the pod, Service, Secret and PVC names follow from them |
| `GARAGE_VERSION` / `CADDY_VERSION` | `0.0.19` / `0.0.26` | chart versions |
| `GARAGE_SIZE` | `50G` | PVC size |
| `GARAGE_CAPACITY` | `45G` | layout capacity; keep it below `GARAGE_SIZE` |
| `CADDY_CERT_DAYS` | `3650` | validity of Caddy's self-signed certificate |

For example, a second store in its own namespace:

```bash
kubectl create namespace backups      # the script does not create it
NS=backups BUCKET=archive GARAGE_SIZE=200G GARAGE_CAPACITY=190G ./scripts/setup-garage-s3.sh up
NS=backups ./scripts/setup-garage-s3.sh test
```

**Related scripts on the Postgres side** use this store but do not manage it.
They are described in [tests/README.md](../tests/README.md):

- `tests/postgres/12-backups.sh` and `13-backup_to_s3.sh` check that backups
  reach the bucket and can be read back;
- `tests/test-instance.sh` builds a throwaway cluster that backs up under its
  own bucket path, then deletes that path when it finishes.

**Limitation:** `up` has not yet been run from scratch in an empty namespace.
`test`, `capacity` and each step on its own were run against the live setup.

## Troubleshooting

Each entry gives the symptom, how to confirm it, and the fix. Run the `garage`
commands in the Garage pod.

### Reinstalling over an old PVC

**Symptom:** S3 calls return `403 Forbidden: No such key: GK...`, and the Garage
log says `already bootstrapped, skipping layout/key setup`.

**Cause:** the StatefulSet's PVC survives `helm uninstall`. A new install finds
the old data and skips bootstrap, so Garage keeps its old key. The chart has
meanwhile written a new random key to the Secret, so the two disagree.

**Check.** Before installing, the PVC should not exist:

```bash
kubectl -n crunchy-postgres get pvc data-objstore-garage-0     # want: NotFound
```

After an install, the access key in the Secret should appear in `garage key list`:

```bash
kubectl -n crunchy-postgres get secret objstore-garage -o jsonpath='{.data.access-key}' | base64 -d; echo
garage key list
```

**Fix (destroys all stored objects):**

```bash
helm uninstall objstore -n crunchy-postgres
kubectl -n crunchy-postgres delete pvc data-objstore-garage-0
```

Then start again at step 1. Any client that uses the old key, such as the
`pg1-pgbackrest-s3` Secret, needs the new key afterwards.

### Writes fail after about 1 GB

**Cause:** the layout capacity is still the chart's 1G.

**Check:** `garage status`. The `Capacity` column shows about 1 GB instead of
roughly the PVC size.

**Fix:** step 2.

### `layout apply` fails, or nothing changes

- **No `STAGED ROLE CHANGES` in `garage layout show`:** the capacity already has
  that value, so there is nothing to apply.
- **`apply` refuses the version:** it must be the current version plus one. Use
  the command that `garage layout show` prints.
- **To drop a staged change instead:** `garage layout revert --yes`.

### Lost a key's secret

The key still exists, so you can show its secret again:

```bash
garage key info pg-backups-key --show-secret    # don't run it where output is logged
```

### Caddy pod keeps restarting

**Cause:** the health probes get `403` from Garage, because the `kube-probe`
rule is missing from the Caddyfile.

**Check:** `kubectl -n crunchy-postgres describe pod -l app.kubernetes.io/instance=my-caddy`.
The events show `Liveness probe failed: HTTP probe failed with statuscode: 403`.

**Fix:** `helm upgrade my-caddy ... -f caddy-values.yaml` with the values from step 4.

### `signed header content-length is not present`

A single-object `DELETE` made through Caddy with the AWS CLI fails like this.
Delete directly against `http://objstore-garage:3900` instead. pgBackRest's
deletes through Caddy are not affected.

### `No such key` from your workstation

Check that your local port-forward points at this Garage: the `clickhouse` and
`demo1` namespaces run other Garages. Use a free local port, for example
`kubectl -n crunchy-postgres port-forward svc/objstore-garage 13900:3900`.

## Advanced: replicating across clusters (COOP)

For continuity of operations (COOP), the goal is a copy of the data in a
**second Kubernetes cluster at another site**. If the primary site is lost, the
COOP site already has the data and can take over.

```text
  Site A · primary cluster                    Site B · COOP cluster
 ┌──────────────────────────────┐            ┌──────────────────────────────┐
 │ clients (pgBackRest, apps)   │            │ standby clients (idle until  │
 │          │                   │            │ failover)                    │
 │          ▼                   │            │          ▲                   │
 │ Caddy ─▶ Garage A            │ ─────────▶ │ Caddy ─▶ Garage B            │
 │          bucket my-bucket    │  VPN or    │          bucket my-bucket    │
 │                              │  ZeroTier  │                              │
 └──────────────────────────────┘            └──────────────────────────────┘
```

### Choosing an approach

| Approach | How the copy gets there | Data at risk if site A is lost | Complexity |
|---|---|---|---|
| **1. Clients write to both sites** | each client writes to Garage A and Garage B itself | almost none (WAL arrives within seconds) | low |
| **2. Scheduled bucket sync** | a CronJob copies bucket A to bucket B | everything since the last sync | low |
| **3. One Garage cluster across sites** | Garage replicates every write itself | none | high; needs 3 sites |

**Recommendation: approach 1 for Postgres, approach 2 for everything else.** Keep
one independent Garage per cluster; approaches 1 and 2 both work that way.
Independent stores also mean a mistake, a bad upgrade or a bug in one store
cannot damage the other. Use approach 3 only if you have three sites.

### Connecting the two clusters

Each site needs to reach the other's S3 endpoint. Your ZeroTier network can
carry this traffic.

**1. Expose only the S3 port.** Do **not** change the Caddy chart's Service to
`LoadBalancer`, because that would also expose Caddy's admin API on port 2019.
Instead, add a separate Service at the site that receives data:

```yaml
# s3-external.yaml  (kubectl -n crunchy-postgres apply -f s3-external.yaml)
apiVersion: v1
kind: Service
metadata:
  name: s3-external
spec:
  type: LoadBalancer            # or NodePort if you have no load balancer
  selector:
    app.kubernetes.io/instance: my-caddy
    app.kubernetes.io/name: caddy
  ports:
    - name: https
      port: 443
      targetPort: https         # Caddy's :8443
```

Restrict who can reach it, using `loadBalancerSourceRanges` or a firewall that
allows only the other site.

**2. Use a certificate the other site can verify.** Inside one cluster, the
self-signed certificate with verification off is acceptable. Across sites, give
Caddy a real certificate, through the chart's `tls.certManager` or
`tls.existingSecret` values, and turn verification back on in the clients.

**3. Give each remote writer its own key, limited to one bucket.** At site B, in
the Garage pod:

```bash
garage key create site-a-writer
garage bucket allow --read --write my-bucket --key site-a-writer   # no --owner
```

Site A then stores that key in a Secret (see [step 3](#3-bucket-and-key)). If
site A is compromised, revoke just that key: `garage key delete site-a-writer --yes`.

### Approach 1: clients write to both sites (Postgres)

pgBackRest can use up to four repos. Add site B's Garage as another repo, for
example `repo3`, next to the existing repo2 at site A:

- WAL is pushed to every repo as it is produced, so site B is seconds behind.
- Scheduled backups are run per repo, so give repo3 its own schedule.
- A Postgres **standby cluster** at site B can follow repo3. It replays the WAL
  continuously and is promoted if site A is lost. The `helm/postgres` chart
  already has `standby` values for this.

Connecting Postgres is set up on the Postgres side, not here. See Crunchy's
[disaster recovery](https://access.crunchydata.com/documentation/postgres-operator/latest/tutorials/backups-disaster-recovery/disaster-recovery)
guide, which covers repo-based standby clusters.

### Approach 2: scheduled bucket sync (rclone)

A CronJob at site A copies the bucket to site B with
[rclone](https://rclone.org/s3/). rclone reads its whole configuration from
environment variables, so no config file is needed.

The job assumes site B's keys are in Secret `coop-dst-s3`, with the keys
`access-key` and `secret-key`.

```yaml
# coop-sync.yaml  (kubectl -n crunchy-postgres apply -f coop-sync.yaml)
apiVersion: batch/v1
kind: CronJob
metadata:
  name: coop-sync
spec:
  schedule: "*/15 * * * *"       # every 15 minutes = at most 15 minutes of data at risk
  concurrencyPolicy: Forbid      # never run two syncs at once
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: rclone
              image: rclone/rclone:1.68.2
              args: ["sync", "src:my-bucket", "dst:my-bucket", "--checksum", "--s3-no-check-bucket"]
              env:
                # source: Garage A, in this cluster
                - { name: RCLONE_CONFIG_SRC_TYPE, value: s3 }
                - { name: RCLONE_CONFIG_SRC_PROVIDER, value: Other }
                - { name: RCLONE_CONFIG_SRC_ENDPOINT, value: "http://objstore-garage:3900" }
                - { name: RCLONE_CONFIG_SRC_REGION, value: garage }
                - { name: RCLONE_CONFIG_SRC_FORCE_PATH_STYLE, value: "true" }
                - name: RCLONE_CONFIG_SRC_ACCESS_KEY_ID
                  valueFrom: { secretKeyRef: { name: objstore-garage, key: access-key } }
                - name: RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY
                  valueFrom: { secretKeyRef: { name: objstore-garage, key: secret-key } }
                # destination: Garage B, at the COOP site
                - { name: RCLONE_CONFIG_DST_TYPE, value: s3 }
                - { name: RCLONE_CONFIG_DST_PROVIDER, value: Other }
                - { name: RCLONE_CONFIG_DST_ENDPOINT, value: "https://<site-b-address>" }
                - { name: RCLONE_CONFIG_DST_REGION, value: garage }
                - { name: RCLONE_CONFIG_DST_FORCE_PATH_STYLE, value: "true" }
                - name: RCLONE_CONFIG_DST_ACCESS_KEY_ID
                  valueFrom: { secretKeyRef: { name: coop-dst-s3, key: access-key } }
                - name: RCLONE_CONFIG_DST_SECRET_ACCESS_KEY
                  valueFrom: { secretKeyRef: { name: coop-dst-s3, key: secret-key } }
```

Things to know:

- **`sync` also deletes.** Objects deleted at site A are deleted at site B too.
  That keeps pgBackRest's expired backups from piling up, but it also copies an
  accidental delete. `rclone copy` never deletes, but then site B only grows.
- **It may catch a backup half-written.** pgBackRest ignores a backup that has no
  manifest, and the next sync completes it, so this is safe but means the newest
  backup can lag. Approach 1 avoids this.
- **Deletes through Caddy.** Single-object deletes through Caddy fail (see
  [Troubleshooting](#signed-header-content-length-is-not-present)), so check
  that deletions arrive at site B. If they do not, point the destination at
  Garage B's port 3900 over the VPN instead. ZeroTier already encrypts that
  traffic.
- **Check it works:** `kubectl -n crunchy-postgres logs job/<latest coop-sync job>`,
  and compare `garage bucket info my-bucket` (size and object count) at both
  sites.

### Approach 3: one Garage cluster across sites

Garage can run a single cluster with nodes in both Kubernetes clusters. Each site
is a *zone*, and every write is replicated to the other zones as it happens.
This is synchronous, but harder to run:

- **It needs three sites to survive losing one.** With the usual 3 copies,
  reads and writes need 2 copies to answer. With only two sites, one site holds
  2 of the 3 copies. If that site is lost, the survivor has 1 copy and stops
  serving until you change the layout by hand. A third site can be small, for
  example a VM or NAS running one Garage node.
- **Every node must reach every other node on RPC port 3901**, across clusters.
  Each pod needs an address the other site can reach, set as `rpc_public_addr`.
  It must also share the same `rpc_secret`.
- **The quenchworks chart cannot do this.** It is single-node, with
  `replication_factor=1`. Use Garage's official chart (`script/helm/garage` in
  the [Garage repository](https://git.deuxfleurs.fr/Deuxfleurs/garage)), or
  run Garage outside Kubernetes at the extra sites.

Once the nodes can reach each other, joining them uses plain `garage` commands:

```bash
garage node id                                   # on each node: <full-id>@<ip>:3901
garage node connect <full-id-of-B>@<B-ip>:3901   # from any one node, once per other node
garage status                                    # all nodes healthy
garage layout assign -z site-a -c 45G <id-A>
garage layout assign -z site-b -c 45G <id-B>
garage layout assign -z site-c -c 45G <id-C>
garage layout show                               # then run the apply it prints
garage layout apply --version <N>
```

### Failing over to site B (approaches 1 and 2)

1. **Check the data at site B:** `garage bucket info my-bucket`. With approach 2,
   look at when the last `coop-sync` job succeeded.
2. **Stop the sync** if site A comes and goes, so it cannot overwrite site B:
   `kubectl -n crunchy-postgres patch cronjob coop-sync -p '{"spec":{"suspend":true}}'`.
3. **Switch clients to site B's endpoint.** For Postgres, promote the standby
   cluster at site B (on the Postgres side).
4. **Fail back later:** once site A is repaired, sync B ─▶ A (swap `src` and
   `dst`), switch the clients back, then resume the original job.

**Test it regularly.** A COOP copy you have never restored from is only a hope.
At least each quarter, restore at site B and check the data.

## Removing it

**This deletes every stored object.**

```bash
helm uninstall my-caddy -n crunchy-postgres
helm uninstall objstore -n crunchy-postgres
kubectl -n crunchy-postgres delete pvc data-objstore-garage-0
```
