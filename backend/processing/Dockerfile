FROM golang:1.25.5-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN --mount=type=cache,target=/root/.cache/go-build CGO_ENABLED=1 go build -trimpath -ldflags="-s -w" -o /out/library ./cmd/library

FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-venv poppler-utils tesseract-ocr tesseract-ocr-eng ffmpeg ca-certificates tini \
    && rm -rf /var/lib/apt/lists/*
RUN npm install --global @openai/codex@0.162.1 && npm cache clean --force
RUN python3 -m venv /opt/pipeline && /opt/pipeline/bin/pip install --no-cache-dir faster-whisper==1.2.1
COPY --from=build /out/library /usr/local/bin/library
COPY processing/pipeline.py processing/repair_narrations.py processing/entrypoint.sh /opt/margin/
RUN mkdir -p /home/worker/.codex /data/processing /data/model-cache && chown -R 65532:65532 /home/worker /data
ENV PATH="/opt/pipeline/bin:${PATH}" HOME=/home/worker CODEX_HOME=/home/worker/.codex HF_HOME=/data/model-cache
USER 65532:65532
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["sh", "/opt/margin/entrypoint.sh"]
