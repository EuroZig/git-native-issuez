# Go binding

`github.com/EuroZig/git-native-issuez/bindings/go/issuez` wraps the C API
(`issuez/include/issuez.h`) with cgo. Everything the library returns is
copied into plain Go values and the C memory is freed at once; only
`*issuez.Repo` holds C state. Calls take a `context.Context`, errors are
`*issuez.Error` (`errors.Is(err, issuez.ErrVersionMismatch)`), writes are
`issuez.Edit` values.

```go
repo, err := issuez.Open("/srv/git/ada/app.git", issuez.WithCommitter("Host", "noreply@example.com"))
w, err := repo.Update(ctx, id, new(issuez.Edit).SetState("closed"), actor, issuez.Reload(), issuez.ExpectTip(tip))
page, err := repo.Query(ctx, issuez.Query{Labels: []string{"bug"}, Order: issuez.SortUpdated})
```

See [the embedding guide](../../docs/embedding.md) for exact-tip reads,
text-version preconditions, external image storage, staged imports, and
how to handle a committed write whose reload fails.

## Archives

The package links `libissuez.a`. The module
[`github.com/EuroZig/git-native-issuez-go`](https://github.com/EuroZig/git-native-issuez-go)
is this package with the archives in it, written by each release: `go get` is
all it takes, and you import `github.com/EuroZig/git-native-issuez-go/issuez`.

The module here (tags `bindings/go/vX.Y.Z`) doesn't have them, for a project
that keeps its own: they come from the same
[release](https://github.com/EuroZig/git-native-issuez/releases), for
macOS (`aarch64`, `x86_64`) and Linux (`aarch64`, `x86_64` and `arm`, which
is ARMv6 and runs on ARMv7 too, with glibc or musl).

```sh
go get github.com/EuroZig/git-native-issuez/bindings/go@v0.5.0
gh release download v0.5.0 --repo EuroZig/git-native-issuez --pattern 'libissuez-*-x86_64-linux-gnu.tar.gz'
tar -xzf libissuez-0.5.0-x86_64-linux-gnu.tar.gz
export CGO_LDFLAGS="-L$PWD/libissuez-0.5.0-x86_64-linux-gnu/lib"
go build ./...
```

- Without it the build fails at the link, as `library 'issuez' not found` or
  `cannot find -lissuez`.
- Take the release of the module's version. Before 1.0, a library of
  another minor version is refused when you open a repository
  (`issuez.h is version 0.3, the library 0.4`).
- In a checkout, `zig build go-libs` installs this platform's in
  `zig-out/lib/go/<GOOS>_<GOARCH>[_musl]/`, `-Dgo-libs-all` every one, for
  `CGO_LDFLAGS` to name; `zig build test-go` builds this platform's and runs
  the tests. A project using a checkout points at it with a `replace`
  directive in its `go.mod`.

Cross-compiling needs a C compiler for the target; `zig cc` works:
`CC="zig cc -target aarch64-linux-musl" GOOS=linux GOARCH=arm64 go build`.

## Go versions

The `go` line is the oldest supported Go release (1.26 now), raised only
when a newer feature is needed or a release leaves support.
