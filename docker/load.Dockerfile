# Load generator: oha (Rust), the same release php-framework-bench used.
# It reports latency percentiles and status counts as JSON, and with -q plus
# --latency-correction it measures from the moment a request was DUE, not from
# when it was finally sent — the open-loop measurement the fixed-rate phase
# needs. curl and jq stay in the image for verify.sh; the image also hosts the
# cgroup sampler (bench/sampler.sh).
FROM debian:bookworm-slim
ARG OHA_VERSION=v1.15.0
ARG TARGET=oha-linux-arm64
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl jq \
 && curl -fsSL "https://github.com/hatoo/oha/releases/download/${OHA_VERSION}/${TARGET}" -o /usr/local/bin/oha \
 && chmod +x /usr/local/bin/oha \
 && rm -rf /var/lib/apt/lists/*
COPY bench/sampler.sh /usr/local/bin/sampler
ENTRYPOINT ["/bin/sh", "-c"]
