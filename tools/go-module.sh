#!/bin/sh
# Writes a release's Go module into a checkout of its repository
# (EuroZig/git-native-issuez-go) and tests it: bindings/go with the module's
# own path and the release's libissuez archives in issuez/lib/, so that
# `go get` is all it takes. release.yml commits the result.
#
#   tools/go-module.sh VERSION ARCHIVES MODULE
#
# ARCHIVES has the release's libissuez-*.tar.gz. Fails, with the checkout in
# whatever state it got to, unless every platform is there and the tests pass.
# Needs Go and a C compiler for this machine.
set -eu

[ $# -eq 3 ] || { echo "usage: $0 VERSION ARCHIVES MODULE" >&2; exit 2; }
version=$1
archives=$(cd "$2" && pwd)
module=$(cd "$3" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)

old_path=github.com/EuroZig/git-native-issuez/bindings/go
new_path=github.com/EuroZig/git-native-issuez-go
main_repo=https://github.com/EuroZig/git-native-issuez

# Everything but .git goes, so that what bindings/go dropped goes here too.
find "$module" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -R "$root/bindings/go/." "$module/"
cp "$root/LICENSE" "$root/THIRD_PARTY_LICENSES" "$module/"

# <archive's platform> <directory in issuez/lib/>
while read -r platform dir; do
    name="libissuez-$version-$platform"
    mkdir -p "$module/issuez/lib/$dir"
    tar -xzf "$archives/$name.tar.gz" -O "$name/lib/libissuez.a" \
        > "$module/issuez/lib/$dir/libissuez.a"
done <<EOF
aarch64-macos darwin_arm64
x86_64-macos darwin_amd64
x86_64-linux-gnu linux_amd64
x86_64-linux-musl linux_amd64_musl
aarch64-linux-gnu linux_arm64
aarch64-linux-musl linux_arm64_musl
arm-linux-gnueabihf linux_arm
arm-linux-musleabihf linux_arm_musl
EOF

# Where the package finds them; the module here takes them from CGO_LDFLAGS.
cat > "$module/issuez/archives.go" <<'EOF'
package issuez

/*
#cgo darwin,arm64 LDFLAGS: -L${SRCDIR}/lib/darwin_arm64
#cgo darwin,amd64 LDFLAGS: -L${SRCDIR}/lib/darwin_amd64
#cgo linux,amd64,!musl LDFLAGS: -L${SRCDIR}/lib/linux_amd64
#cgo linux,amd64,musl LDFLAGS: -L${SRCDIR}/lib/linux_amd64_musl
#cgo linux,arm64,!musl LDFLAGS: -L${SRCDIR}/lib/linux_arm64
#cgo linux,arm64,musl LDFLAGS: -L${SRCDIR}/lib/linux_arm64_musl
#cgo linux,arm,!musl LDFLAGS: -L${SRCDIR}/lib/linux_arm
#cgo linux,arm,musl LDFLAGS: -L${SRCDIR}/lib/linux_arm_musl
*/
import "C"
EOF

find "$module" -type f \( -name '*.go' -o -name go.mod -o -name '*.md' \) \
    -exec perl -pi -e "s|\Q$old_path\E|$new_path|g" {} +
# The generators read docs/, which is in the main repository.
find "$module/issuez" -type f -name '*.go' -exec perl -ni -e 'print unless m{^//go:generate }' {} +

# The README, but for how to get the archives. The docs are in the main
# repository.
archives_section=$(mktemp)
trap 'rm -f "$archives_section"' EXIT
cat > "$archives_section" <<EOF
## Archives

This module has \`libissuez.a\` for macOS (arm64, amd64) and Linux (amd64, arm64
and arm, which is ARMv6 and runs on ARMv7 too, with glibc or musl), so \`go get\`
is all it takes. Builds need cgo and a C compiler, and Linux builds for musl
(Alpine) need \`-tags musl\`.

\`\`\`sh
go get $new_path/issuez@v$version
\`\`\`

Cross-compiling needs a C compiler for the target; \`zig cc\` works:
\`CC="zig cc -target aarch64-linux-musl" GOOS=linux GOARCH=arm64 go build -tags musl\`.

Each [release]($main_repo/releases) writes this repository, so changes and
issues go to [git-native-issuez]($main_repo), where the binding is
\`bindings/go\`.

EOF
awk -v section="$archives_section" '
    /^## Archives$/ { while ((getline line < section) > 0) print line; skip = 1; next }
    skip && /^## / { skip = 0 }
    !skip { print }
' "$root/bindings/go/README.md" > "$module/README.md"
perl -pi -e "s|\Q$old_path\E|$new_path|g; s|\]\(\.\./\.\./|]($main_repo/blob/v$version/|g" \
    "$module/README.md"

# As a user has it: no flags, in a module of its own.
unset CGO_LDFLAGS
export CGO_ENABLED=1 GOWORK=off
(cd "$module" && go vet ./... && go test -count=1 ./...)
consumer=$(mktemp -d)
trap 'rm -f "$archives_section"; rm -rf "$consumer"' EXIT
cat > "$consumer/main.go" <<EOF
package main

import (
	"fmt"

	"$new_path/issuez"
)

func main() { fmt.Println(issuez.Version()) }
EOF
got=$(
    cd "$consumer"
    go mod init consumer 2>/dev/null
    go mod edit -require="$new_path@v0.0.0" -replace="$new_path=$module"
    go run .
)
if [ "$got" != "$version" ]; then
    echo "$0: the module reports version '$got', not '$version'" >&2
    exit 1
fi
