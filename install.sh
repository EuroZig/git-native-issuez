#!/bin/sh
# Installs a git-native-issuez release: `git-issue` and its entry points
# into <prefix>/bin, completions, man pages and docs into <prefix>/share,
# and `update-git-native-issuez`, which updates it with the same options.
#
#   curl -fsSL https://raw.githubusercontent.com/EuroZig/git-native-issuez/main/install.sh | sh
#   sh install.sh --flavor minimal --prefix /usr/local
#
# Every archive is checked against the release's SHA256SUMS before
# anything is installed. Only the copy into a prefix you can't write to
# runs with sudo (or doas). Run with --help for the options.
set -eu

# Raised when the updater has to refuse older copies of this script.
installer_version=1

repo='EuroZig/git-native-issuez'
script_url="https://raw.githubusercontent.com/$repo/main/install.sh"
version=''
flavor='full'
prefix=''
from=''
force=0
allow_downgrade=0
# --no-verify does not persist: it has to be asked for on every run
no_verify=0

usage() {
    cat <<EOF
usage: install.sh [--version <x.y.z>] [--flavor full|minimal] [--prefix <dir>]
                  [--from <dir>] [--force] [--allow-downgrade] [--no-verify]

Installs git-native-issuez from its GitHub releases ($repo).

  --version <x.y.z>   The release (default: the latest)
  --flavor <name>     full, with the MCP server (default), or minimal, the CLI only
  --prefix <dir>      Where bin/ and share/ go (default: ~/.local). One you can't
                      write to is written with sudo (or doas)
  --from <dir>        Take the archive and SHA256SUMS from <dir> instead of
                      downloading them (for example zig-out/release)
  --force             Install even if this version and flavor are installed
  --allow-downgrade   Install an older version than the installed one
  --no-verify         Install without checking SHA256SUMS
  -h, --help          Show this help
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

# quotes a value for the generated updater
shquote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

while [ $# -gt 0 ]; do
    case "$1" in
    --version | --flavor | --prefix | --from)
        [ $# -ge 2 ] || die "$1 requires a value"
        case "$1" in
        --version) version=${2#v} ;;
        --flavor) flavor=$2 ;;
        --prefix) prefix=$2 ;;
        --from) from=$2 ;;
        esac
        shift 2
        ;;
    --force) force=1 && shift ;;
    --allow-downgrade) allow_downgrade=1 && shift ;;
    --no-verify) no_verify=1 && shift ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) die "unknown option '$1' (see --help)" ;;
    esac
done

case "$flavor" in
full | minimal) ;;
*) die "--flavor must be full or minimal, not '$flavor'" ;;
esac

# As root, HOME may be root's or the user's, depending on sudo's setup:
# either way ~/.local is the wrong place for root-owned files.
if [ "$(id -u)" -eq 0 ] && [ -z "$prefix" ]; then
    die "running as root: give --prefix (for example /usr/local)," \
        "or run as yourself; only the copy into the prefix needs sudo"
fi
if [ -z "$prefix" ]; then
    [ -n "${HOME:-}" ] || die "HOME is not set; give --prefix"
    prefix="$HOME/.local"
fi
case "$prefix" in
/*) ;;
*) prefix="$(pwd)/$prefix" ;;
esac

case "$(uname -s)" in
Linux) os=linux ;;
Darwin) os=macos ;;
MINGW* | MSYS* | CYGWIN* | Windows_NT)
    die "on Windows, unzip the x86_64-windows archive from" \
        "https://github.com/$repo/releases and add its bin folder to PATH"
    ;;
*) die "no release for $(uname -s); build from source with Zig 0.16.0 (see README.md)" ;;
esac
case "$(uname -m)" in
x86_64 | amd64) arch=x86_64 ;;
aarch64 | arm64) arch=aarch64 ;;
*) die "no release for $(uname -m); build from source with Zig 0.16.0 (see README.md)" ;;
esac

fetch() { # <url> <file>
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --https-only -O "$2" "$1"
    else
        die "curl or wget is needed to download the release"
    fi
}

latest() {
    url="https://github.com/$repo/releases/latest"
    if command -v curl >/dev/null 2>&1; then
        tag=$(curl -fsSLI --proto '=https' -o /dev/null -w '%{url_effective}' "$url")
    elif command -v wget >/dev/null 2>&1; then
        tag=$(wget -q --https-only --max-redirect=0 -S -O /dev/null "$url" 2>&1 |
            sed -n 's/^ *[Ll]ocation: *//p' | tr -d '\r' | tail -1) || true
    else
        die "curl or wget is needed to download the release"
    fi
    tag=${tag##*/tag/}
    case "$tag" in
    v[0-9]* | [0-9]*) echo "${tag#v}" ;;
    *) die "could not find the latest release of $repo; give --version" ;;
    esac
}

# older, same or newer: how version $1 compares to version $2 (x.y.z)
version_cmp() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            if (x[i] + 0 < y[i] + 0) { print "older"; exit }
            if (x[i] + 0 > y[i] + 0) { print "newer"; exit }
        }
        print "same"
    }'
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/git-native-issuez.XXXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT TERM

if [ -z "$version" ]; then
    [ -z "$from" ] || die "--from needs --version"
    version=$(latest)
fi
name="git-native-issuez-$version-$flavor-$arch-$os"
archive="$name.tar.gz"

# What's installed there: its version, and its flavor (minimal has no mcp).
current=''
current_flavor=''
if [ -x "$prefix/bin/git-issue" ]; then
    current=$("$prefix/bin/git-issue" version 2>/dev/null | sed -n 's/^git-issue version //p') || true
    if "$prefix/bin/git-issue" mcp --help >/dev/null 2>&1; then
        current_flavor=full
    else
        current_flavor=minimal
    fi
fi
if [ -n "$current" ]; then
    case "$(version_cmp "$version" "$current")" in
    same)
        if [ "$flavor" = "$current_flavor" ] && [ "$force" -eq 0 ]; then
            echo "git-native-issuez $version ($flavor) is already installed in $prefix"
            echo "(--force installs it again)"
            exit 0
        fi
        ;;
    older)
        [ "$allow_downgrade" -eq 1 ] ||
            die "$version is older than the installed $current;" \
                "--allow-downgrade installs it anyway"
        ;;
    esac
fi

if [ -n "$from" ]; then
    [ -f "$from/$archive" ] || die "$from/$archive does not exist"
    cp "$from/$archive" "$tmp/"
    if [ "$no_verify" -eq 0 ]; then
        [ -f "$from/SHA256SUMS" ] || die "$from/SHA256SUMS does not exist"
        cp "$from/SHA256SUMS" "$tmp/"
    fi
else
    base="https://github.com/$repo/releases/download/v$version"
    echo "Downloading $archive"
    fetch "$base/$archive" "$tmp/$archive" ||
        die "could not download $base/$archive (is $version a release?)"
    if [ "$no_verify" -eq 0 ]; then
        fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" ||
            die "could not download $base/SHA256SUMS"
    fi
fi

if [ "$no_verify" -eq 1 ]; then
    echo
    echo "########################################################################"
    echo "# WARNING: checksum verification is disabled.                          #"
    echo "# Nothing was checked; the download is trusted on TLS alone.           #"
    echo "########################################################################"
    echo
else
    if command -v sha256sum >/dev/null 2>&1; then
        sum=$(sha256sum "$tmp/$archive")
    elif command -v shasum >/dev/null 2>&1; then
        sum=$(shasum -a 256 "$tmp/$archive")
    elif command -v openssl >/dev/null 2>&1; then
        sum=$(openssl dgst -sha256 -r "$tmp/$archive")
    else
        die "sha256sum, shasum or openssl is needed to check the download;" \
            "re-run with --no-verify to install without checking it"
    fi
    sum=${sum%% *}
    expected=$(awk -v f="$archive" '$2 == f || $2 == "*" f { print $1; exit }' "$tmp/SHA256SUMS")
    [ -n "$expected" ] || die "SHA256SUMS has no entry for $archive; refusing to install it"
    [ "$sum" = "$expected" ] ||
        die "$archive does not match SHA256SUMS ($sum, expected $expected); refusing to install it"
    echo "Checked $archive against SHA256SUMS"
fi

tar -xzf "$tmp/$archive" -C "$tmp"
root="$tmp/$name"
[ -x "$root/bin/git-issue" ] || die "$archive has no bin/git-issue"
installed=$("$root/bin/git-issue" version) ||
    die "the downloaded git-issue doesn't run on this machine"
(cd "$root" && find bin share ! -type d -print) >"$tmp/files"

# The nearest existing ancestor of every directory a file goes into has to
# be writable; moving a file into place needs its directory, not the file.
need_sudo=''
for d in $(sed 's|/[^/]*$||' "$tmp/files" | sort -u) .; do
    probe="$prefix/$d"
    while [ ! -e "$probe" ]; do
        parent=$(dirname "$probe")
        [ "$parent" != "$probe" ] || break
        probe=$parent
    done
    if [ ! -w "$probe" ]; then
        need_sudo=$probe
        break
    fi
done
SUDO=''
if [ -n "$need_sudo" ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO=sudo
    elif command -v doas >/dev/null 2>&1; then
        SUDO=doas
    else
        die "$need_sudo is not writable, and there is no sudo or doas;" \
            "give another --prefix"
    fi
    # sudo asks on the terminal, also when this script comes through a pipe
    (: </dev/tty) 2>/dev/null ||
        die "$need_sudo is not writable, and there is no terminal to ask" \
            "for $SUDO's password; give another --prefix or run it in one"
    echo "$need_sudo is not writable: $SUDO will ask for your password to install into $prefix"
fi

# update-git-native-issuez runs the current install.sh with these options.
cat >"$tmp/updater" <<EOF
#!/bin/sh
# Generated by git-native-issuez's install.sh: updates git-native-issuez
# in $prefix by running the current install.sh with the options it was
# installed with. Extra arguments go to install.sh (--version, --force, ...).
set -eu
installer_version=$installer_version
url=$(shquote "$script_url")
tmp=\$(mktemp -d "\${TMPDIR:-/tmp}/git-native-issuez-update.XXXXXXXXX")
trap 'rm -rf "\$tmp"' EXIT
if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 -o "\$tmp/install.sh" "\$url"
else
    wget -q --https-only -O "\$tmp/install.sh" "\$url"
fi
fetched=\$(sed -n 's/^installer_version=\([0-9][0-9]*\)\$/\1/p' "\$tmp/install.sh" | head -1)
if [ -z "\$fetched" ] || [ "\$fetched" -lt "\$installer_version" ]; then
    echo "error: \$url is older than the install.sh git-native-issuez was" >&2
    echo "installed with (\${fetched:-no version} < \$installer_version); refusing to run it" >&2
    exit 1
fi
sh "\$tmp/install.sh" --flavor $(shquote "$flavor") --prefix $(shquote "$prefix") "\$@"
EOF
chmod 755 "$tmp/updater"

# The copy, the only part that runs with sudo: one sh, so sudo or doas asks
# once. Each file is staged next to its target and moved over it, so a
# failed copy never leaves a broken one and a running git-issue can be
# replaced. The binary goes first, so the entry points never point at a
# missing one; the updater last.
copy_script='
set -eu
prefix=$1 root=$2 files=$3 updater=$4
put() {
    dst="$prefix/$2"
    staged="$dst.new.$$"
    mkdir -p "$(dirname "$dst")"
    rm -f "$staged"
    if [ -L "$1" ]; then
        ln -s "$(readlink "$1")" "$staged"
    elif [ -x "$1" ]; then
        cp "$1" "$staged" && chmod 755 "$staged"
    else
        cp "$1" "$staged" && chmod 644 "$staged"
    fi || { rm -f "$staged"; echo "error: could not write $dst" >&2; exit 1; }
    mv -f "$staged" "$dst" || { rm -f "$staged"; echo "error: could not write $dst" >&2; exit 1; }
}
put "$root/bin/git-issue" bin/git-issue
while IFS= read -r f; do
    [ "$f" = bin/git-issue ] || put "$root/$f" "$f"
done <"$files"
put "$updater" bin/update-git-native-issuez
'
$SUDO sh -c "$copy_script" sh "$prefix" "$root" "$tmp/files" "$tmp/updater" ||
    die "could not install into $prefix"

if [ -n "$current" ] && [ "$current" != "$version" ]; then
    echo "Updated git-native-issuez from $current to $version ($flavor) in $prefix"
else
    echo "Installed $installed ($flavor) into $prefix"
fi
echo "update-git-native-issuez updates it with the same options"

bin="$prefix/bin"
case ":${PATH:-}:" in
*":$bin:"*) ;;
*)
    echo
    echo "$bin is not on PATH. Add it, for example in ~/.profile:"
    echo "  export PATH=\"$bin:\$PATH\""
    ;;
esac
found=$(command -v git-issue 2>/dev/null || true)
if [ -n "$found" ] && [ "$found" != "$bin/git-issue" ]; then
    echo
    echo "Note: PATH finds another git-issue first: $found"
fi
if [ "$flavor" = full ]; then
    echo
    echo "For Claude Code, register the MCP server with: git issue mcp install"
fi
