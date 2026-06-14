#!/bin/sh
# Entrypoint for the bundled kubo-ds-s3 image.
# On first start it initializes the repo and, if S3_BUCKET is set, configures the
# s3ds datastore (block storage in S3) from environment variables, then execs `ipfs`.
set -e

: "${IPFS_PATH:=/data/ipfs}"
export IPFS_PATH
mkdir -p "$IPFS_PATH"

if [ ! -f "$IPFS_PATH/config" ]; then
  ipfs init --empty-repo ${IPFS_PROFILE:+--profile "$IPFS_PROFILE"}

  if [ -n "${S3_BUCKET:-}" ]; then
    S3_REGION="${S3_REGION:-us-east-1}"
    S3_ROOT_DIRECTORY="${S3_ROOT_DIRECTORY:-blocks}"
    S3_ENDPOINT="${S3_ENDPOINT:-}"
    S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
    S3_SECRET_KEY="${S3_SECRET_KEY:-}"

    # block reads/writes go straight to S3 (no local negative cache)
    ipfs config --json Datastore.BloomFilterSize 0

    # /blocks -> s3ds (S3), / -> levelds (local metadata: pins, keys, MFS)
    ipfs config --json Datastore.Spec "{\"type\":\"mount\",\"mounts\":[{\"mountpoint\":\"/blocks\",\"type\":\"measure\",\"prefix\":\"s3.datastore\",\"child\":{\"type\":\"s3ds\",\"region\":\"${S3_REGION}\",\"bucket\":\"${S3_BUCKET}\",\"rootDirectory\":\"${S3_ROOT_DIRECTORY}\",\"regionEndpoint\":\"${S3_ENDPOINT}\",\"accessKey\":\"${S3_ACCESS_KEY}\",\"secretKey\":\"${S3_SECRET_KEY}\"}},{\"mountpoint\":\"/\",\"type\":\"measure\",\"prefix\":\"leveldb.datastore\",\"child\":{\"type\":\"levelds\",\"path\":\"datastore\",\"compression\":\"none\"}}]}"

    # datastore_spec must equal kubo's computed DiskSpec (sorted keys, no trailing newline)
    printf '%s' "{\"mounts\":[{\"bucket\":\"${S3_BUCKET}\",\"mountpoint\":\"/blocks\",\"region\":\"${S3_REGION}\",\"rootDirectory\":\"${S3_ROOT_DIRECTORY}\"},{\"mountpoint\":\"/\",\"path\":\"datastore\",\"type\":\"levelds\"}],\"type\":\"mount\"}" > "$IPFS_PATH/datastore_spec"
  fi
fi

exec ipfs "$@"
