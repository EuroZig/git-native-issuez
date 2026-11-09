package issuez

import (
	"container/list"
	"sync"
)

// Pool keeps a Repo open per repository for a host that serves many, so
// calls don't pay for opening one. Handles are opened on first use with
// the pool's options, shared by concurrent calls, and closed when more
// than maxIdle are idle (the least recently used first), when their
// repository moves (another path for the same key), and by Forget and
// Close. Safe for concurrent use.
type Pool[K comparable] struct {
	opts    []Option
	maxIdle int

	mu     sync.Mutex
	byKey  map[K]*pooled[K]
	lru    *list.List // idle handles, oldest at the front
	closed bool
}

type pooled[K comparable] struct {
	key  K
	path string
	repo *Repo
	refs int
	// Set while idle: its place in the LRU list.
	idle *list.Element
	// Dropped from the pool (a new path, Forget, Close): closes once idle.
	stale bool
}

// NewPool keeps up to maxIdle idle handles, opened with opts.
func NewPool[K comparable](maxIdle int, opts ...Option) *Pool[K] {
	return &Pool[K]{opts: opts, maxIdle: maxIdle, byKey: map[K]*pooled[K]{}, lru: list.New()}
}

// Do runs f with the handle of the repository key names, at path. The
// handle stays valid until f returns; don't keep it.
func (p *Pool[K]) Do(key K, path string, f func(*Repo) error) error {
	h, err := p.acquire(key, path)
	if err != nil {
		return err
	}
	defer p.release(h)
	return f(h.repo)
}

func (p *Pool[K]) acquire(key K, path string) (*pooled[K], error) {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return nil, &Error{Code: CodeInvalidArgument, Message: "pool is closed"}
	}
	if h := p.takeLocked(key, path); h != nil {
		p.mu.Unlock()
		return h, nil
	}
	p.mu.Unlock()

	// Open outside the lock: it runs git.
	r, err := Open(path, p.opts...)
	if err != nil {
		return nil, err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		r.Close()
		return nil, &Error{Code: CodeInvalidArgument, Message: "pool is closed"}
	}
	if h := p.takeLocked(key, path); h != nil {
		// Opened meanwhile by another call: use that one.
		r.Close()
		return h, nil
	}
	h := &pooled[K]{key: key, path: path, repo: r, refs: 1}
	p.byKey[key] = h
	return h, nil
}

// takeLocked is the open handle of key at path, with a reference taken;
// nil if there is none. A handle of key at another path is dropped.
func (p *Pool[K]) takeLocked(key K, path string) *pooled[K] {
	h, ok := p.byKey[key]
	if !ok {
		return nil
	}
	if h.path != path {
		p.dropLocked(h)
		return nil
	}
	h.refs++
	if h.idle != nil {
		p.lru.Remove(h.idle)
		h.idle = nil
	}
	return h
}

func (p *Pool[K]) release(h *pooled[K]) {
	p.mu.Lock()
	defer p.mu.Unlock()
	h.refs--
	if h.refs > 0 {
		return
	}
	if h.stale {
		h.repo.Close()
		return
	}
	h.idle = p.lru.PushBack(h)
	for p.lru.Len() > p.maxIdle {
		oldest := p.lru.Remove(p.lru.Front()).(*pooled[K])
		oldest.idle = nil
		delete(p.byKey, oldest.key)
		oldest.repo.Close()
	}
}

// dropLocked takes h out of the pool, closing it now if idle.
func (p *Pool[K]) dropLocked(h *pooled[K]) {
	delete(p.byKey, h.key)
	if h.idle != nil {
		p.lru.Remove(h.idle)
		h.idle = nil
	}
	if h.refs == 0 {
		h.repo.Close()
		return
	}
	h.stale = true
}

// Forget drops the handle of a repository that was deleted or moved;
// calls in flight keep theirs until they return.
func (p *Pool[K]) Forget(key K) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if h, ok := p.byKey[key]; ok {
		p.dropLocked(h)
	}
}

// Close closes every idle handle, and the busy ones as their calls
// return. Do fails after it.
func (p *Pool[K]) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.closed = true
	for _, h := range p.byKey {
		p.dropLocked(h)
	}
	return nil
}

// Len is the number of open handles, busy or idle.
func (p *Pool[K]) Len() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.byKey)
}
