# Linux for `zig build test-bindings` (test/linux/test-bindings.sh): Go at
# the binding's minimum version, its C toolchain for cgo and the ASan
# smoke test, git-lfs, and Zig 0.17.1.
FROM golang:1.26-trixie
RUN apt-get update \
 && apt-get install -y --no-install-recommends git-lfs xz-utils \
 && rm -rf /var/lib/apt/lists/*
ARG ZIG=0.17.1
RUN arch=$(uname -m) \
 && curl -fsSL "https://ziglang.org/download/$ZIG/zig-$arch-linux-$ZIG.tar.xz" | tar -xJ -C /opt \
 && ln -s "/opt/zig-$arch-linux-$ZIG/zig" /usr/local/bin/zig
