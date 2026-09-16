# Reference target that runs no application code. Pinned to the same four cores
# a candidate gets, it shows what the load generator, the Docker network and
# the host can carry at that moment — the ceiling no candidate can exceed.
FROM nginx:1.31.6-alpine
COPY docker/probe-nginx.conf /etc/nginx/nginx.conf
