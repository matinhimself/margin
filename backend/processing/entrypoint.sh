#!/bin/sh
set -eu
echo "Waiting for the server Codex login before processing queued PDF and EPUB uploads."
until codex login status >/dev/null 2>&1; do sleep 15; done
exec library worker -db /data/library.sqlite -workdir /data/processing -pipeline /opt/margin/pipeline.py
