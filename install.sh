#!/bin/sh
# Installs a git-native-issuez release into <prefix> (default ~/.local),
# checked against the release's SHA256SUMS, and update-git-native-issuez,
# which updates it with the same flavor and prefix.
# --uninstall removes all of it again; the issues in your repositories stay.
#
#   curl -fsSL https://raw.githubusercontent.com/EuroZig/git-native-issuez/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --flavor minimal --version 0.4.0 --prefix ~/opt
#   sh install.sh --from zig-out/release --version 0.4.0    # local archives
#   sh install.sh --uninstall --prefix ~/opt                 # or: update-git-native-issuez --uninstall
set -eu

# The updaters 0.1.0 and 0.2.0 installed refuse a script without this line.
installer_version=2

repo='EuroZig/git-native-issuez'
version='' flavor='full' prefix="${HOME:-}/.local" from=''
# --no-verify does not persist: it has to be asked for on every run
no_verify=0 uninstall=0

die() { echo "error: $*" >&2; exit 1; }
opts='--version x.y.z, --flavor full|minimal, --prefix dir, --from dir, --no-verify, --uninstall'

# Only our git-issue has __manpages, which tells it from upstream's. Entry
# points are the links to git-issue, and every git-issue man page is ours
# (whichever flavor wrote it) but upstream's import and export ones.
remove_all() {
    cd "$prefix" 2>/dev/null && [ -e bin/git-issue ] || die "nothing to uninstall: there is no $prefix/bin/git-issue"
    bin/git-issue __manpages "$tmp/man" >/dev/null 2>&1 ||
        die "$prefix/bin/git-issue isn't git-native-issuez's; nothing was removed"
    for f in bin/git-issue-*; do
        [ -L "$f" ] && [ "$(readlink "$f")" = git-issue ] || continue
        rm -f "$f" "share/bash-completion/completions/${f#bin/}" "share/fish/vendor_completions.d/${f#bin/}.fish"
    done
    for f in share/man/man1/git-issue.1 share/man/man1/git-issue-*.1; do
        case "$f" in */git-issue-import* | */git-issue-export*) ;; *) rm -f "$f" ;; esac
    done
    rm -rf share/doc/git-native-issuez
    rm -f share/bash-completion/completions/git-issue share/fish/vendor_completions.d/git-issue.fish \
        share/zsh/site-functions/_git-issue bin/update-git-native-issuez bin/git-issue
    echo "Uninstalled git-native-issuez from $prefix; the issues in your repositories stay"
}

# get <file>: a release file into $tmp, from --from or the release page
get() {
    if [ -n "$from" ]; then
        cp "$from/$1" "$tmp/"
    else
        curl -fsSL --proto '=https' -o "$tmp/$1" "https://github.com/$repo/releases/download/v$version/$1" ||
            die "could not download $1 for $version"
    fi
}

verify() {
    if [ "$no_verify" -eq 1 ]; then
        echo
        echo "########################################################################"
        echo "# WARNING: checksum verification is disabled.                          #"
        echo "# Nothing was checked; the download is trusted on TLS alone.           #"
        echo "########################################################################"
        echo
        return
    fi
    get SHA256SUMS
    command -v sha256sum >/dev/null || sha256sum() { shasum -a 256 "$@"; }
    (cd "$tmp" && grep "  $archive\$" SHA256SUMS | sha256sum -c - >/dev/null) ||
        die "$archive does not match SHA256SUMS; refusing to install it"
}

# write_updater <file>; it tells the flavor by mcp, which only full has
write_updater() {
    printf '%s\n' \
        '#!/bin/sh' \
        '# Updates git-native-issuez with the current install.sh, keeping the prefix' \
        '# and the flavor. Extra arguments go to install.sh.' \
        'set -eu' \
        'prefix=$(cd "$(dirname "$0")/.." && pwd)' \
        'flavor=minimal && "$prefix/bin/git-issue" mcp --help >/dev/null 2>&1 && flavor=full' \
        'curl -fsSL --proto =https https://raw.githubusercontent.com/EuroZig/git-native-issuez/main/install.sh |' \
        '    sh -s -- --flavor "$flavor" --prefix "$prefix" "$@"' \
        >"$1"
    chmod 755 "$1"
}

# Everything runs from here, on the last line: a download cut off midway
# is a syntax error, so curl | sh runs none of it.
main() {
    while [ $# -gt 0 ]; do
        case "$1" in
        --no-verify) no_verify=1 ;;
        --uninstall) uninstall=1 ;;
        --version | --flavor | --prefix | --from)
            [ $# -ge 2 ] || die "$1 requires a value ($opts)"
            eval "${1#--}=\$2" && shift ;;
        *) die "unknown option $1 ($opts)" ;;
        esac
        shift
    done
    version=${version#v}

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    [ "$uninstall" -eq 0 ] || { remove_all; exit; }

    case "$flavor" in full | minimal) ;; *) die "--flavor must be full or minimal" ;; esac
    case "$(uname -s)" in Linux) os=linux ;; Darwin) os=macos ;; *) die "no release for $(uname -s); see README.md" ;; esac
    case "$(uname -m)" in x86_64 | amd64) arch=x86_64 ;; aarch64 | arm64) arch=aarch64 ;; *) die "no release for $(uname -m); see README.md" ;; esac

    if [ -z "$version" ]; then
        [ -z "$from" ] || die "--from needs --version"
        tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest") ||
            die "could not find the latest release; give --version"
        version=${tag##*/v}
    fi
    archive="git-native-issuez-$version-$flavor-$arch-$os.tar.gz"

    get "$archive"
    verify

    # Unlink first: overwriting a running binary or script in place breaks it.
    updater="$prefix/bin/update-git-native-issuez"
    mkdir -p "$prefix" && rm -f "$prefix/bin/git-issue" "$updater"
    tar -xzf "$tmp/$archive" --strip-components=1 -C "$prefix"
    write_updater "$updater"

    echo "Installed $("$prefix/bin/git-issue" version) ($flavor) into $prefix"
    echo "update-git-native-issuez updates it with the same options"
    case ":$PATH:" in *":$prefix/bin:"*) ;; *) echo "Add $prefix/bin to PATH" ;; esac
}

main "$@"
