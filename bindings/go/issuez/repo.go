package issuez

/*
#include <stdlib.h>
#include "issuez.h"
*/
import "C"

import (
	"context"
	"maps"
	"runtime"
	"runtime/cgo"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"
)

// Repo is an open repository. Safe for concurrent use; it keeps a pool of
// git sessions. Close it when done (a cleanup closes a forgotten one).
type Repo struct {
	mu      sync.RWMutex
	c       *C.issuez_repo
	cleanup runtime.Cleanup
	// SetLogger's function. Calls under way keep the handle they started
	// with, so it stays valid until Close, which waits for them. Allocated
	// apart: the handle must not keep a forgotten Repo from its cleanup.
	logMu     sync.Mutex
	logFn     *atomic.Pointer[func(LogEvent)]
	logHandle cgo.Handle
}

// Option configures Open. Each is one ISSUEZ_OPT_* op.
type Option func(*[]op)

func opt(o op) Option { return func(ops *[]op) { *ops = append(*ops, o) } }

// WithGit uses this git binary instead of "git" from PATH.
func WithGit(path string) Option {
	return opt(op{verb: VerbSet, target: C.ISSUEZ_OPT_GIT_PATH, str: path})
}

// WithEnv replaces the environment of git children ("KEY=value", like
// os/exec). LC_ALL and GIT_TERMINAL_PROMPT are always forced.
func WithEnv(env []string) Option {
	return func(ops *[]op) {
		*ops = append(*ops, op{verb: VerbClear, target: C.ISSUEZ_OPT_ENV})
		for _, kv := range env {
			k, v, _ := strings.Cut(kv, "=")
			*ops = append(*ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_ENV, name: k, str: v})
		}
	}
}

// WithEnvOverrides sets variables of git children's environment on top
// of the process's ("KEY=value"); later ones win. With WithEnv, on top
// of that one, whichever comes first.
func WithEnvOverrides(env ...string) Option {
	return func(ops *[]op) {
		for _, kv := range env {
			k, v, _ := strings.Cut(kv, "=")
			*ops = append(*ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_ENV, name: k, str: v})
		}
	}
}

// WithCommitter is the committer of every commit this repo writes.
func WithCommitter(name, email string) Option {
	return opt(op{verb: VerbSet, target: C.ISSUEZ_OPT_COMMITTER, person: Person{Name: name, Email: email}})
}

// WithDoneStates are the states besides "closed" that count as done, in
// place of git config issue.doneStates.
func WithDoneStates(states ...string) Option { return addAll(C.ISSUEZ_OPT_DONE_STATE, states) }

// WithWorkflowStates are the workflow states an open issue may be in, in
// place of git config issue.workflowStates.
func WithWorkflowStates(states ...string) Option { return addAll(C.ISSUEZ_OPT_WORKFLOW_STATE, states) }

// WithExclusiveScopes makes an issue carry at most one "scope/x" label per
// scope: adding one takes the others off, two in one write are refused.
func WithExclusiveScopes(scopes ...string) Option {
	return addAll(C.ISSUEZ_OPT_EXCLUSIVE_SCOPE, scopes)
}

// WithExtraPrefixes are the key prefixes Edit.SetExtra may write (default
// "X-Forgejo-").
func WithExtraPrefixes(prefixes ...string) Option { return addAll(C.ISSUEZ_OPT_EXTRA_PREFIX, prefixes) }

// WithPoolSize is how many git sessions run at once (default 4).
func WithPoolSize(n int) Option {
	return opt(op{verb: VerbSet, target: C.ISSUEZ_OPT_POOL_SIZE, num: int64(n)})
}

// WithCacheIssues keeps up to n issues loaded between queries (default
// 10000); 0 turns the cache off.
func WithCacheIssues(n int) Option {
	return opt(op{verb: VerbSet, target: C.ISSUEZ_OPT_CACHE_ISSUES, num: int64(n)})
}

// WithLocalTimeout bounds every local git command and request (default
// 120 s for a command, 60 s for a request); 0 keeps the default. Past it a
// call fails with CodeTimeout.
func WithLocalTimeout(d time.Duration) Option {
	return opt(op{verb: VerbSet, target: C.ISSUEZ_OPT_TIMEOUT_LOCAL_MS, num: d.Milliseconds()})
}

// WithNetworkTimeout bounds every fetch, push and LFS transfer (default
// 600 s for a fetch or push, 1800 s for a transfer); 0 keeps the default.
func WithNetworkTimeout(d time.Duration) Option {
	return opt(op{verb: VerbSet, target: C.ISSUEZ_OPT_TIMEOUT_NETWORK_MS, num: d.Milliseconds()})
}

// WithAttachmentStore with false leaves attachment bytes to the caller, a
// host that keeps them in its own LFS store: writes store none and need
// no git-lfs. The default stores them in the repository, as the CLI does.
func WithAttachmentStore(store bool) Option {
	return opt(op{verb: VerbSet, target: C.ISSUEZ_OPT_ATTACHMENT_STORE, num: b2i(store)})
}

// WithLimit sets a library limit by name ("max_labels", ...).
func WithLimit(name string, value uint64) Option {
	return opt(op{verb: VerbSet, target: C.ISSUEZ_OPT_LIMIT, name: name, num: int64(value)})
}

// WithRetries is how often a write runs again when another write raced
// it (default 8, at most 64): the limit "cas_retries". Past it a write
// fails with CodeContended.
func WithRetries(n int) Option { return WithLimit("cas_retries", uint64(n)) }

// Limit is the effective value of a limit by name ("max_attachment_bytes",
// ...; the names WithLimit takes), false for no such limit.
func (r *Repo) Limit(name string) (uint64, bool) {
	var v uint64
	var ok bool
	r.use(func(c *C.issuez_repo) error {
		var out C.uint64_t
		ok = bool(C.issuez_repo_limit(c, cStr(name), &out))
		v = uint64(out)
		return nil
	})
	return v, ok
}

func addAll(target uint32, vs []string) Option {
	return func(ops *[]op) {
		for _, v := range vs {
			*ops = append(*ops, op{verb: VerbAdd, target: target, str: v})
		}
	}
}

// Open opens a work tree, a directory in one, or a bare repo's git dir.
func Open(path string, opts ...Option) (*Repo, error) {
	if err := initOnce(); err != nil {
		return nil, err
	}
	var ops []op
	for _, o := range opts {
		o(&ops)
	}
	var pin runtime.Pinner
	defer pin.Unpin()
	cops, n := cOps(&pin, ops)
	var c *C.issuez_repo
	var cerr *C.issuez_error
	if C.issuez_repo_open(cStr(path), cops, n, &c, &cerr) != C.ISSUEZ_OK {
		return nil, takeError(context.Background(), cerr)
	}
	return wrapRepo(c), nil
}

func wrapRepo(c *C.issuez_repo) *Repo {
	r := &Repo{c: c}
	r.cleanup = runtime.AddCleanup(r, func(c *C.issuez_repo) { C.issuez_repo_close(c) }, c)
	return r
}

// Close releases the repo. Calls after Close fail with CodeInvalidArgument.
func (r *Repo) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.c != nil {
		r.cleanup.Stop()
		C.issuez_repo_set_logger(r.c, C.ISSUEZ_LOG_OFF, nil, nil)
		C.issuez_repo_close(r.c)
		r.c = nil
		r.logMu.Lock()
		defer r.logMu.Unlock()
		if r.logHandle != 0 {
			r.logHandle.Delete()
			r.logHandle = 0
		}
	}
	return nil
}

// use runs f with the C handle, holding a read lock so Close waits for
// calls in flight.
func (r *Repo) use(f func(*C.issuez_repo) error) error {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.c == nil {
		return &Error{Code: CodeInvalidArgument, Message: "repo is closed"}
	}
	return f(r.c)
}

// GitDir is the repository's git directory; "" after Close.
func (r *Repo) GitDir() string {
	var dir string
	r.use(func(c *C.issuez_repo) error { dir = goStr(C.issuez_repo_git_dir(c)); return nil })
	return dir
}

// ─── Resolve ───────────────────────────────────────────────────────────

// Kind is what a ref, a write or a finding is about.
type Kind uint32

const (
	KindIssue     Kind = C.ISSUEZ_KIND_ISSUE
	KindMilestone Kind = C.ISSUEZ_KIND_MILESTONE
	// In push verdicts: refs/attachments/<uuid> and refs/issuez-purged/<uuid>.
	KindAttachments Kind = C.ISSUEZ_KIND_ATTACHMENTS
	KindTombstone   Kind = C.ISSUEZ_KIND_TOMBSTONE
)

var refPrefixes = [...]string{"refs/issues/", "refs/milestones/", "refs/attachments/", "refs/issuez-purged/"}

// RefPrefixes are the ref namespaces the library keeps: issues,
// milestones, attachments and tombstones. Hosts route pushes to these
// refs to PushCheck, and mirror them with RefSpecs. The slice is the
// caller's.
func RefPrefixes() []string { return append([]string(nil), refPrefixes[:]...) }

// IsRef tells whether ref is in one of RefPrefixes.
func IsRef(ref string) bool {
	for _, p := range refPrefixes {
		if strings.HasPrefix(ref, p) {
			return true
		}
	}
	return false
}

// RefSpecs are forced refspecs of every namespace in RefPrefixes, for a
// mirror that copies them as they are ("+refs/issues/*:refs/issues/*",
// ...). Clones that merge use Sync instead.
func RefSpecs() []string {
	out := make([]string, 0, len(refPrefixes))
	for _, p := range refPrefixes {
		out = append(out, "+"+p+"*:"+p+"*")
	}
	return out
}

// Resolve turns user input ("a7f3", "#12", a UUID, a milestone name)
// into UUIDs: none, one or several.
func (r *Repo) Resolve(ctx context.Context, kind Kind, input string) ([]string, error) {
	return fetch(ctx, r, func(a cArgs, m **C.issuez_matches) C.issuez_code {
		return C.issuez_resolve(a.repo, C.issuez_kind(kind), cStr(input), a.tok, m, a.cerr)
	}, takeMatches)
}

// takeMatches copies and frees an owned list.
func takeMatches(m *C.issuez_matches) []string {
	defer C.issuez_matches_free(m)
	return goStrs(C.issuez_matches_len(m), func(i C.size_t) C.issuez_str { return C.issuez_matches_at(m, i) })
}

// ResolveOne is Resolve that wants exactly one: ErrNotFound or
// ErrAmbiguous otherwise.
func (r *Repo) ResolveOne(ctx context.Context, kind Kind, input string) (string, error) {
	buf := (*C.char)(C.malloc(C.ISSUEZ_UUID_BUFSIZE))
	defer C.free(unsafe.Pointer(buf))
	return fetch(ctx, r, func(a cArgs, _ *struct{}) C.issuez_code {
		return C.issuez_resolve_one(a.repo, C.issuez_kind(kind), cStr(input), a.tok, buf, a.cerr)
	}, func(struct{}) string { return C.GoString(buf) })
}

// DropAll deletes every ref of the library's (issues, milestones,
// attachments, tombstones, local state) in one transaction and returns how
// many: it undoes an import into a repository that had none, with no
// writes running. Not a purge: clones keep their copies and sync them
// back.
func (r *Repo) DropAll(ctx context.Context) (int, error) {
	return fetch(ctx, r, func(a cArgs, out *C.size_t) C.issuez_code {
		return C.issuez_repo_drop_all(a.repo, a.tok, out, a.cerr)
	}, func(out C.size_t) int { return int(out) })
}

// AdoptRefs creates in r every issue, milestone, attachment and tombstone
// ref that from has, in one transaction, and returns how many. An import
// written into a scratch repository whose git uses r's objects
// (WithEnvOverrides("GIT_OBJECT_DIRECTORY=<r's objects>")) lands at once
// or not at all: CodeContended when r has one of the refs, CodeCorrupt
// when a tip's object isn't in r's store, and nothing is taken.
func (r *Repo) AdoptRefs(ctx context.Context, from *Repo) (int, error) {
	var n int
	err := r.use(func(c *C.issuez_repo) error {
		return from.use(func(f *C.issuez_repo) error {
			out, err := invoke(ctx, c, func(a cArgs, out *C.size_t) C.issuez_code {
				return C.issuez_repo_adopt_refs(a.repo, f, a.tok, out, a.cerr)
			})
			n = int(out)
			return err
		})
	})
	return n, err
}

// ResolveNumber is the UUID of the issue numbered n: ErrNotFound when
// there is none.
func (r *Repo) ResolveNumber(ctx context.Context, n uint64) (string, error) {
	return r.ResolveOne(ctx, KindIssue, "#"+strconv.FormatUint(n, 10))
}

// ─── Snapshot and diff ─────────────────────────────────────────────────

// RefKey names an issue or milestone ref.
type RefKey struct {
	Kind Kind
	ID   string
}

// Snapshot is every issue and milestone with its tip. Cheap to take.
type Snapshot struct {
	Tips map[RefKey]OID
}

// Snapshot takes the tips of every issue and milestone now.
func (r *Repo) Snapshot(ctx context.Context) (*Snapshot, error) {
	return fetch(ctx, r, func(a cArgs, s **C.issuez_snapshot) C.issuez_code {
		return C.issuez_snapshot_take(a.repo, a.tok, s, a.cerr)
	}, func(s *C.issuez_snapshot) *Snapshot {
		defer C.issuez_snapshot_free(s)
		return goSnapshot(s)
	})
}

func goSnapshot(s *C.issuez_snapshot) *Snapshot {
	n := C.issuez_snapshot_len(s)
	out := &Snapshot{Tips: make(map[RefKey]OID, int(n))}
	for i := C.size_t(0); i < n; i++ {
		var kind C.issuez_kind
		var id C.issuez_str
		var tip C.issuez_oid
		C.issuez_snapshot_at(s, i, &kind, &id, &tip)
		out.Tips[RefKey{Kind(kind), goStr(id)}] = goOID(tip)
	}
	return out
}

// MarshalBinary is the library's stable encoding, readable by every
// binding.
func (s *Snapshot) MarshalBinary() ([]byte, error) {
	keys := make([]RefKey, 0, len(s.Tips))
	for k := range s.Tips {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].Kind != keys[j].Kind {
			return keys[i].Kind < keys[j].Kind
		}
		return keys[i].ID < keys[j].ID
	})
	var b strings.Builder
	b.WriteString("issuez-snapshot 1\n")
	for _, k := range keys {
		kind := "i"
		if k.Kind == KindMilestone {
			kind = "m"
		} else if k.Kind != KindIssue {
			return nil, &Error{Code: CodeInvalidArgument, Message: "invalid snapshot kind"}
		}
		b.WriteString(kind + " " + k.ID + " " + s.Tips[k].String() + "\n")
	}
	data := []byte(b.String())
	// Keep the library's canonical UUID/OID validation and encoding contract.
	var checked Snapshot
	if err := checked.UnmarshalBinary(data); err != nil {
		return nil, err
	}
	if !maps.Equal(s.Tips, checked.Tips) {
		return nil, &Error{Code: CodeInvalidArgument, Message: "invalid snapshot keys"}
	}
	return data, nil
}

// UnmarshalBinary reads MarshalBinary's encoding, from any binding.
func (s *Snapshot) UnmarshalBinary(b []byte) error {
	if err := initOnce(); err != nil {
		return err
	}
	var c *C.issuez_snapshot
	var cerr *C.issuez_error
	var pin runtime.Pinner
	defer pin.Unpin()
	var in C.issuez_str
	if len(b) > 0 {
		pin.Pin(&b[0])
		in = C.issuez_str{ptr: (*C.char)(unsafe.Pointer(&b[0])), len: C.size_t(len(b))}
	}
	if C.issuez_snapshot_decode(in, &c, &cerr) != C.ISSUEZ_OK {
		return takeError(context.Background(), cerr)
	}
	defer C.issuez_snapshot_free(c)
	*s = *goSnapshot(c)
	return nil
}

// ChangeKind is what happened to a ref between two snapshots.
type ChangeKind uint32

const (
	ChangeCreated ChangeKind = C.ISSUEZ_CHANGE_CREATED
	ChangeUpdated ChangeKind = C.ISSUEZ_CHANGE_UPDATED
	ChangeRemoved ChangeKind = C.ISSUEZ_CHANGE_REMOVED
)

// DiffEntry is one ref that changed between two snapshots.
type DiffEntry struct {
	RefKey
	Change         ChangeKind
	OldTip, NewTip OID
}

// Diff says what changed from prev (nil: nothing) to next. Pure Go: same
// rules as issuez_diff_new.
func Diff(prev, next *Snapshot) []DiffEntry {
	var out []DiffEntry
	var oldTips map[RefKey]OID
	if prev != nil {
		oldTips = prev.Tips
	}
	for k, nt := range next.Tips {
		ot, ok := oldTips[k]
		switch {
		case !ok:
			out = append(out, DiffEntry{RefKey: k, Change: ChangeCreated, NewTip: nt})
		case ot != nt:
			out = append(out, DiffEntry{RefKey: k, Change: ChangeUpdated, OldTip: ot, NewTip: nt})
		}
	}
	for k, ot := range oldTips {
		if _, ok := next.Tips[k]; !ok {
			out = append(out, DiffEntry{RefKey: k, Change: ChangeRemoved, OldTip: ot})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Kind != out[j].Kind {
			return out[i].Kind < out[j].Kind
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// Settings is what WriteSettings writes to git config: a nil list leaves
// its key alone, an empty one unsets it (the defaults then).
type Settings struct {
	DoneStates, WorkflowStates []string
}

// WriteSettings writes issue.doneStates and issue.workflowStates, what a
// settings page saves; every state is checked first (CodeInvalidValue).
// Handles opened afterwards see them.
func (r *Repo) WriteSettings(ctx context.Context, s Settings) error {
	var ops []op
	for _, k := range []struct {
		target uint32
		states []string
	}{{C.ISSUEZ_OPT_DONE_STATE, s.DoneStates}, {C.ISSUEZ_OPT_WORKFLOW_STATE, s.WorkflowStates}} {
		switch {
		case k.states == nil:
		case len(k.states) == 0:
			ops = append(ops, op{verb: VerbClear, target: k.target})
		default:
			for _, st := range k.states {
				ops = append(ops, op{verb: VerbAdd, target: k.target, str: st})
			}
		}
	}
	var pin runtime.Pinner
	defer pin.Unpin()
	cops, n := cOps(&pin, ops)
	_, err := fetch(ctx, r, func(a cArgs, _ *struct{}) C.issuez_code {
		return C.issuez_settings_write(a.repo, cops, n, a.tok, a.cerr)
	}, func(struct{}) struct{} { return struct{}{} })
	return err
}

// Import stages ordinary writes on Repo, with the target's policy and objects.
// Defer Close to discard its private refs, whether committed or aborted.
// Do not write concurrently with Commit or Close.
type Import struct{ *Repo }

// BeginImport creates a private staging repo. Nothing becomes visible on the
// target until Commit succeeds. Closing the target does not invalidate staging.
func (r *Repo) BeginImport(ctx context.Context) (*Import, error) {
	return fetch(ctx, r, func(a cArgs, out **C.issuez_repo) C.issuez_code {
		return C.issuez_repo_begin_import(a.repo, a.tok, out, a.cerr)
	}, func(out *C.issuez_repo) *Import { return &Import{Repo: wrapRepo(out)} })
}

// Commit publishes all staged refs atomically, then closes the staging repo.
// On failure no refs are published; Close aborts, or Commit may be retried.
func (i *Import) Commit(ctx context.Context) (int, error) {
	n, err := fetch(ctx, i.Repo, func(a cArgs, out *C.size_t) C.issuez_code {
		return C.issuez_repo_commit_import(a.repo, a.tok, out, a.cerr)
	}, func(out C.size_t) int { return int(out) })
	if err == nil {
		err = i.Close()
	}
	return n, err
}
