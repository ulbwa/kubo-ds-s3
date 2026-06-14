#!/bin/sh
# Entrypoint for the bundled kubo-ds-s3 image.
# On first start it initializes the repo and, if S3_BUCKET is set, routes the ENTIRE
# IPFS datastore (blocks, pins, MFS, IPNS) to s3ds (S3) so all state is shared across
# nodes, then execs `ipfs`. Only the node identity (config/keystore) stays local.
set -e

: "${IPFS_PATH:=/data/ipfs}"
export IPFS_PATH
mkdir -p "$IPFS_PATH"

if [ ! -f "$IPFS_PATH/config" ]; then
  ipfs init --empty-repo ${IPFS_PROFILE:+--profile "$IPFS_PROFILE"}

  if [ -n "${S3_BUCKET:-}" ]; then
    S3_REGION="${S3_REGION:-us-east-1}"
    S3_ROOT_DIRECTORY="${S3_ROOT_DIRECTORY:-ipfs}"
    S3_ENDPOINT="${S3_ENDPOINT:-}"
    S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
    S3_SECRET_KEY="${S3_SECRET_KEY:-}"

    # block reads/writes go straight to S3 (no local negative cache)
    ipfs config --json Datastore.BloomFilterSize 0

    # The ENTIRE datastore is a single s3ds: blocks, pins, MFS and IPNS records all
    # live in S3, so a fleet of nodes sharing one bucket shares the full pinset.
    ipfs config --json Datastore.Spec "{\"type\":\"s3ds\",\"region\":\"${S3_REGION}\",\"bucket\":\"${S3_BUCKET}\",\"rootDirectory\":\"${S3_ROOT_DIRECTORY}\",\"regionEndpoint\":\"${S3_ENDPOINT}\",\"accessKey\":\"${S3_ACCESS_KEY}\",\"secretKey\":\"${S3_SECRET_KEY}\"}"

    # datastore_spec must equal kubo's computed DiskSpec for s3ds (sorted keys, no newline)
    printf '%s' "{\"bucket\":\"${S3_BUCKET}\",\"region\":\"${S3_REGION}\",\"rootDirectory\":\"${S3_ROOT_DIRECTORY}\"}" > "$IPFS_PATH/datastore_spec"

    # `ipfs init` created local flatfs/levelds dirs for the default spec; with s3ds they
    # are unused — remove them so nothing IPFS-data-related is kept on local disk.
    rm -rf "$IPFS_PATH/blocks" "$IPFS_PATH/datastore"
  fi
fi

exec ipfs "$@"
