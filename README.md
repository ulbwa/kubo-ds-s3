# kubo-ds-s3

Automated builds of [Kubo](https://github.com/ipfs/kubo) with the [go-ds-s3](https://github.com/ipfs/go-ds-s3) (`s3ds`) datastore **compiled in**, published — per stable Kubo release — as a **Docker image** (GHCR) and a **linux/amd64 binary** (GitHub Releases).

## What this is

This repository contains GitHub Actions that watch stable Kubo releases. For each new stable release it builds a custom `ipfs` binary that has the `s3ds` datastore (block storage backed by S3 / S3-compatible object storage) **bundled directly into Kubo**, and publishes it two ways:

- a Docker image on GHCR: `ghcr.io/<owner>/kubo-ds-s3` (`<owner>` is this repo's GitHub owner),
- a static `linux/amd64` binary attached to a GitHub Release.

There is nothing to install into a stock Kubo — the artifact **is** Kubo, with S3 support already inside it.

## Why bundled, not a `.so` plugin

go-ds-s3 can technically be built as an external Go plugin (`.so`) loaded at runtime. In practice that does **not** work with modern Kubo, and this was verified directly:

- The official Kubo binaries — both the `dist.ipfs.tech` downloads and the `ipfs/kubo` Docker image — are built **without CGO**, so they cannot load any external plugin at all (`not built with cgo support`).
- Even a from-source CGO-enabled Kubo rejects the plugin with `plugin was built with a different version of package …` — the well-known, fragile Go-plugin ABI/dependency-drift problem (go-ds-s3 [#294](https://github.com/ipfs/go-ds-s3/issues/294)).

**Bundling** (Kubo's `preload` mechanism) compiles `s3ds` into the Kubo binary at build time. The result is a single, self-contained `ipfs`:

- no runtime plugin loading and no ABI/version matching to get wrong,
- no CGO required (so the binary is static and portable),
- it is exactly the upstream Kubo otherwise — same commands, gateway, and config.

This is the approach go-ds-s3's own README recommends for reliability.

## Use the Docker image

The image initializes the repo on first start and configures `s3ds` from environment variables, then runs the daemon.

```bash
docker run -d --name ipfs \
  -e S3_BUCKET=my-ipfs-bucket \
  -e S3_REGION=us-east-1 \
  -e S3_ENDPOINT=https://s3.us-east-1.amazonaws.com \
  -e S3_ACCESS_KEY=... \
  -e S3_SECRET_KEY=... \
  -p 8080:8080 -p 5001:5001 \
  -v ipfs-data:/data/ipfs \
  ghcr.io/<owner>/kubo-ds-s3:v0.42.0
```

For an S3-compatible backend (e.g. MinIO), point `S3_ENDPOINT` at it:

```yaml
# docker-compose excerpt
services:
  ipfs:
    image: ghcr.io/<owner>/kubo-ds-s3:v0.42.0
    environment:
      S3_BUCKET: ipfs-data
      S3_ENDPOINT: http://minio:9000
      S3_ACCESS_KEY: minioadmin
      S3_SECRET_KEY: minioadmin
    ports: ["8080:8080", "5001:5001"]
```

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `S3_BUCKET` | _(unset)_ | S3 bucket for the **entire** datastore (blocks **and** pins). If unset, the repo keeps the default local datastore (no S3). |
| `S3_REGION` | `us-east-1` | AWS region. |
| `S3_ENDPOINT` | _(empty)_ | Custom endpoint for S3-compatible stores (MinIO, etc.). Empty = real AWS S3. |
| `S3_ROOT_DIRECTORY` | `ipfs` | Key prefix inside the bucket (blocks under `<prefix>/blocks/`, pins under `<prefix>/pins/`). |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | _(empty)_ | Credentials. If empty, the standard AWS credential chain is used (env / `~/.aws`). |
| `IPFS_PROFILE` | _(unset)_ | Optional Kubo init profile (e.g. `server`). |

Configuration only happens on first start (when `$IPFS_PATH/config` does not exist).

## Use the binary

Download `kubo-ds-s3_kubo-<KUBO>_linux-amd64` from [Releases](../../releases), verify it, and use it as a drop-in `ipfs`:

```bash
sha256sum -c kubo-ds-s3_kubo-v0.42.0_linux-amd64.sha256
install -m755 kubo-ds-s3_kubo-v0.42.0_linux-amd64 /usr/local/bin/ipfs
ipfs --version
```

Then configure the datastore. After `ipfs init`, set `Datastore.Spec` to a single `s3ds` so the **entire** datastore (blocks, pins, MFS, IPNS) lives in S3:

```json
{
  "type": "s3ds",
  "region": "us-east-1",
  "bucket": "my-ipfs-bucket",
  "rootDirectory": "ipfs",
  "regionEndpoint": "",
  "accessKey": "",
  "secretKey": ""
}
```

Kubo also keeps a `datastore_spec` file that must match this spec's DiskSpec — for `s3ds` that is `{"bucket":"…","region":"…","rootDirectory":"…"}` (sorted keys, no trailing newline), otherwise the daemon refuses to start. The Docker image writes it (and removes the unused local `blocks/`/`datastore/` dirs that `ipfs init` created) automatically; for the raw binary, mirroring the image's [`docker-entrypoint.sh`](docker-entrypoint.sh) is the simplest path. Blank `accessKey`/`secretKey` fall back to the AWS credential chain. See the [go-ds-s3 README](https://github.com/ipfs/go-ds-s3#readme) for the full config reference.

## Configuring Kubo

The image is plain Kubo, configured the normal Kubo way — via the JSON `config` file in the repo. The repo lives at `IPFS_PATH`, which is `/data/ipfs` in the image, so the config file is `/data/ipfs/config`. Mount a volume there to persist and edit it:

```bash
docker run -d --name ipfs \
  -e S3_BUCKET=my-bucket -e S3_ENDPOINT=… -e S3_ACCESS_KEY=… -e S3_SECRET_KEY=… \
  -v /srv/ipfs:/data/ipfs \
  -p 8080:8080 -p 5001:5001 \
  ghcr.io/<owner>/kubo-ds-s3:v0.42.0
```

On first start the entrypoint runs `ipfs init` (and, if `S3_BUCKET` is set, writes the s3ds config) into `/srv/ipfs/config`. After that, tweak it however you like — edit the file directly, or use the CLI and restart:

```bash
docker exec ipfs ipfs config Routing.Type autoclient
docker exec ipfs ipfs config --json Swarm.ConnMgr.HighWater 200
docker restart ipfs
```

**Bring your own config.** The entrypoint only initializes when `/data/ipfs/config` is absent. If the mounted volume already holds an initialized repo (`config`, `datastore_spec`, `keystore`, …), the image skips both `ipfs init` and the s3ds env shortcut and runs Kubo against your config verbatim — full control, no env vars. The simplest way to get there: start the container once to let it init, stop it, edit `/srv/ipfs/config`, and start it again.

> If you change `Datastore.Spec` by hand, keep the `datastore_spec` file in sync (see [Use the binary](#use-the-binary)) or the daemon won't start.

**Binary:** same model without Docker — `IPFS_PATH` (default `~/.ipfs`) points at the repo and `ipfs config …` edits `$IPFS_PATH/config`.

## Distributed architecture (one S3, many nodes)

The **entire** datastore — blocks, pins, MFS and IPNS records — lives in S3; only the node identity (`config` + `keystore`) stays local, so each node keeps its own PeerID. Several independent Kubo nodes pointed at the same bucket therefore share not just the content but the **pinset**: pin something on one node and every other node sees and serves it. Verified end-to-end — a second, offline node with an empty local store (~36&nbsp;KB, no `blocks/`/`datastore/` dirs) listed the first node's pins and served its content (CLI + HTTP gateway) purely from the shared bucket. The bucket is the single source of truth you can put behind a CDN, with stateless Kubo nodes in front.

This whole-datastore-in-S3 layout is simply how the **image's entrypoint** configures Kubo by default — it is not a limitation of Kubo or of the binary. Using the binary (or by giving the image your own `config`, see [Configuring Kubo](#configuring-kubo)) you can set any `Datastore.Spec` you need: keep pins and metadata in a local `levelds` and put only `/blocks` in S3, split blocks across several backends, and so on. The shared-pinset behaviour and the caveats below apply specifically to the choice of routing the entire datastore to one bucket.

**Caveats of sharing the whole datastore.** Mutable state (the pinset, the MFS root) is plain object storage with no locking, so concurrent writes from multiple nodes can race. Designate one "writer" node for pinning/MFS and treat the rest as read replicas; don't run `ipfs repo gc` on more than one node at a time. Metadata operations are S3 round-trips, so they are slower than a local datastore — fine for a serve-heavy fleet, less so for write-heavy workloads.

## Artifacts and tags

Each build produces one GitHub Release tagged `kubo-ds-s3/v<KUBO>+build.<REV>` (e.g. `kubo-ds-s3/v0.42.0+build.1`):

- `<KUBO>` — the targeted Kubo version.
- `<REV>` — increments when go-ds-s3 is rebuilt for the same Kubo version (e.g. after an upstream go-ds-s3 commit).

Release assets: `kubo-ds-s3_kubo-<KUBO>_linux-amd64` + its `.sha256`.
Docker tags: `:<KUBO>`, `:<KUBO>-build.<REV>`, `:latest`.

## How it works

A daily scheduled workflow ([`.github/workflows/watch-and-build.yml`](.github/workflows/watch-and-build.yml), also runnable via `workflow_dispatch`):

1. Finds the latest stable Kubo release (stable = tag matching `^v\d+\.\d+\.\d+$`; release candidates excluded).
2. Resolves the Go toolchain from that Kubo tag's `go.mod`.
3. Builds Kubo with go-ds-s3 added to `plugin/loader/preload_list` (s3ds compiled in), as a static `linux/amd64` binary.
4. Pushes the Docker image to GHCR and publishes the binary to a GitHub Release — one release per `(Kubo version, build rev)`.

State is derived from existing releases: a `build-meta` HTML comment in each release body records the go-ds-s3 source commit, so the watcher rebuilds only when the Kubo version or the go-ds-s3 source changes. This repo intentionally contains **no functional tests** — validating that s3ds works inside Kubo is the job of a separate test repository.

## Repository configuration

Optional repository variables override the watched sources (defaults shown):

| Variable | Default |
|---|---|
| `KUBO_REPO` | `ipfs/kubo` |
| `GO_DS_S3_REPO` | `ipfs/go-ds-s3` |
| `GO_DS_S3_BRANCH` | `master` |

The workflow needs `contents: write` (Releases) and `packages: write` (GHCR), both granted via the default `GITHUB_TOKEN`. Manual runs accept `kubo_version` (target a specific version) and `force` (rebuild even if unchanged).

## Licensing

This repo's own code (workflows, Dockerfile, entrypoint, README) is under the **MIT License** (see `LICENSE`).

The produced `ipfs` binary and image are derivative works of **Kubo** (dual MIT/Apache-2.0) and **go-ds-s3** (MIT) and statically link their dependency graph (including `aws-sdk-go`, Apache-2.0). Redistribution is governed by those upstream licenses.
