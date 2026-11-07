# NativeLink's minimal image does not include a Python runtime. This demo
# worker image adds Python for trajectory_checker.py while keeping NativeLink
# itself pinned to the documented local RBE example version.
FROM ghcr.io/tracemachina/nativelink:v1.6.5 AS nativelink
FROM python:3.12-slim-bookworm

COPY --from=nativelink /nix/store/*-nativelink-*/bin/nativelink /usr/local/bin/nativelink
RUN ln -s /usr/local/bin/python3 /usr/bin/python3

ENTRYPOINT ["/usr/local/bin/nativelink"]
CMD ["/config"]
