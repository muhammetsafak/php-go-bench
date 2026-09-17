# Go candidate. Static binary on the same Debian release the PHP images use.
FROM golang:1.27.1-trixie AS build
WORKDIR /src
COPY apps/go/go.mod apps/go/go.sum ./
RUN go mod download
COPY apps/go/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/server .

FROM debian:trixie-slim
COPY --from=build /out/server /usr/local/bin/server
# The container is pinned to a cpuset; say the core count explicitly rather
# than rely on the runtime reading it. The capacity run overrides this per core
# budget; unset means the four cores the 2026-09-16 run used.
ENV GOMAXPROCS=4
EXPOSE 80
ENTRYPOINT ["/usr/local/bin/server"]
