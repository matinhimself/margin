FROM golang:1.25.5-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN --mount=type=cache,target=/root/.cache/go-build CGO_ENABLED=1 go build -trimpath -ldflags="-s -w" -o /out/library ./cmd/library

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl sqlite3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/library /usr/local/bin/library
USER 65532:65532
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD curl --fail --silent http://127.0.0.1:8787/healthz || exit 1
ENTRYPOINT ["library"]
CMD ["serve", "-addr", "0.0.0.0:8787", "-db", "/data/library.sqlite"]
