# Builds Kubo with the go-ds-s3 (s3ds) datastore compiled in (bundled via preload).
# No external .so, no CGO, no runtime plugin loading — a single self-contained ipfs binary.
ARG GO_VERSION=1.26.4

# Build natively on the builder arch and cross-compile to the target (CGO disabled => trivial).
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION} AS build
ARG KUBO_VERSION=v0.42.0
ARG GO_DS_S3_REF=master
RUN git clone --depth 1 --branch "${KUBO_VERSION}" https://github.com/ipfs/kubo /kubo
WORKDIR /kubo
# Add go-ds-s3, register the s3ds plugin in kubo's preload list, regenerate preload.go.
RUN go get "github.com/ipfs/go-ds-s3@${GO_DS_S3_REF}" \
 && printf '\ns3ds github.com/ipfs/go-ds-s3/plugin 0\n' >> plugin/loader/preload_list \
 && make plugin/loader/preload.go \
 && go mod tidy
# Static (CGO-disabled) binary with s3ds compiled in.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o /ipfs ./cmd/ipfs

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /ipfs /usr/local/bin/ipfs
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENV IPFS_PATH=/data/ipfs
VOLUME /data/ipfs
# 4001 swarm, 5001 RPC API, 8080 gateway
EXPOSE 4001 5001 8080
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["daemon", "--migrate=true"]
