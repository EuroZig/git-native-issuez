#!/bin/sh
# `zig build test-bindings` on Linux, in a container (needs docker): the
# working tree as it is, without caches or build output. Caches live in docker volumes between runs.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
image=git-native-issuez-linux:1
docker build -q -t "$image" "$root/test/linux" >/dev/null
# COPYFILE_DISABLE: no AppleDouble files from macOS tar.
COPYFILE_DISABLE=1 tar -C "$root" \
    --exclude=./.git --exclude=./.zig-cache --exclude=./zig-out -cf - . |
    docker run --rm -i \
        --cap-add SYS_PTRACE \
        -v git-native-issuez-zig:/root/.cache/zig \
        -v git-native-issuez-go:/root/.cache/go-build \
        -v git-native-issuez-gomod:/go/pkg/mod \
        "$image" sh -c 'mkdir /src && tar --warning=no-unknown-keyword -C /src -xf - && cd /src && zig build test-bindings "$@"' sh "$@"
