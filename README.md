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
      S3_BUCKET: ipfs-blocks
      S3_ENDPOINT: http://minio:9000
      S3_ACCESS_KEY: minioadmin
      S3_SECRET_KEY: minioadmin
    ports: ["8080:8080", "5001:5001"]
```

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `S3_BUCKET` | _(unset)_ | S3 bucket for blocks. If unset, the repo is left with the default local datastore (no S3). |
| `S3_REGION` | `us-east-1` | AWS region. |
| `S3_ENDPOINT` | _(empty)_ | Custom endpoint for S3-compatible stores (MinIO, etc.). Empty = real AWS S3. |
| `S3_ROOT_DIRECTORY` | `blocks` | Key prefix inside the bucket. |
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

Then configure the `s3ds` datastore. After `ipfs init`, set `Datastore.Spec` so the `/blocks` mount uses `s3ds`:

```json
{
  "type": "mount",
  "mounts": [
    {
      "mountpoint": "/blocks",
      "type": "measure",
      "prefix": "s3.datastore",
      "child": {
        "type": "s3ds",
        "region": "us-east-1",
        "bucket": "my-ipfs-bucket",
        "rootDirectory": "blocks",
        "regionEndpoint": "",
        "accessKey": "",
        "secretKey": ""
      }
    },
    {
      "mountpoint": "/",
      "type": "measure",
      "prefix": "leveldb.datastore",
      "child": { "type": "levelds", "path": "datastore", "compression": "none" }
    }
  ]
}
```

`rootDirectory` for the `s3ds` child must also be reflected in the repo's `datastore_spec` file. The Docker image handles all of this automatically; for the raw binary, mirroring the image's [`docker-entrypoint.sh`](docker-entrypoint.sh) is the simplest path. Blank `accessKey`/`secretKey` fall back to the AWS credential chain. See the [go-ds-s3 README](https://github.com/ipfs/go-ds-s3#readme) for the full config reference.

## Distributed architecture (one S3, many nodes)

Blocks live in the `/blocks` mount (`s3ds` → S3); only node-local metadata (pins, keys, MFS) stays in the local `levelds`. Because the heavy block data is in shared S3, **several independent Kubo nodes can point at the same bucket and all serve the same content** — including a node that never added it and has no peers. This was verified end-to-end: a second, offline node with an empty local store retrieved and served 4&nbsp;MB of content (CLI and HTTP gateway) purely from the shared bucket. That makes the bucket a single source of truth you can place behind a CDN, with stateless Kubo gateway nodes in front.

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
