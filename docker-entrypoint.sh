#!/bin/sh
# Entrypoint for the bundled kubo-ds-s3 image.
# It only initializes a repo when none exists yet (so the image still runs on an empty
# volume), then execs `ipfs`. It does NOT configure the datastore for you — mount your
# own repo, or set `Datastore.Spec` (e.g. s3ds) yourself. See the README.
set -e

: "${IPFS_PATH:=/data/ipfs}"
export IPFS_PATH
mkdir -p "$IPFS_PATH"

if [ ! -f "$IPFS_PATH/config" ]; then
  ipfs init ${IPFS_PROFILE:+--profile "$IPFS_PROFILE"}
fi

exec ipfs "$@"
