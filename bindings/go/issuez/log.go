package issuez

/*
#include "issuez.h"
#include <stdint.h>
void issuez_go_set_logger(issuez_log_level level, int on);
void issuez_go_set_repo_logger(issuez_repo *repo, issuez_log_level level, uintptr_t h);
*/
import "C"

import (
	"runtime/cgo"
	"sync/atomic"
	"time"
	"unsafe"
	"weak"
)

// LogLevel is how much the library tells the logger.
type LogLevel uint32

const (
	LogOff   LogLevel = C.ISSUEZ_LOG_OFF
	LogError LogLevel = C.ISSUEZ_LOG_ERROR
	LogWarn  LogLevel = C.ISSUEZ_LOG_WARN
	LogInfo  LogLevel = C.ISSUEZ_LOG_INFO
	// One event per git request, with its duration.
	LogDebug LogLevel = C.ISSUEZ_LOG_DEBUG
	LogTrace LogLevel = C.ISSUEZ_LOG_TRACE
)

// LogEvent is one thing the library reports.
type LogEvent struct {
	Level LogLevel
	// "git.fetch", "issue.update", ...
	Operation string
	Message   string
	RepoPath  string
	// The issue, milestone or ref it is about, if any.
	Subject string
	// Negative when the step isn't timed.
	Duration time.Duration
	// The retry, 0 for the first attempt.
	Attempt int
}

var logger atomic.Pointer[func(LogEvent)]

// SetDefaultLogger sends the library's events at level and above to fn,
// for every repo without a logger of its own (Repo.SetLogger). fn runs on
// library threads, possibly several at once, and must not call back into
// the library. A nil fn or LogOff stops it.
func SetDefaultLogger(level LogLevel, fn func(LogEvent)) {
	if fn == nil || level == LogOff {
		C.issuez_go_set_logger(C.ISSUEZ_LOG_OFF, 0)
		logger.Store(nil)
		return
	}
	logger.Store(&fn)
	C.issuez_go_set_logger(C.issuez_log_level(level), 1)
}

func deliverLog(event unsafe.Pointer) {
	if fn := logger.Load(); fn != nil {
		(*fn)(goLogEvent(event))
	}
}

func deliverRepoLog(h uintptr, event unsafe.Pointer) {
	if w, ok := cgo.Handle(h).Value().(weak.Pointer[atomic.Pointer[func(LogEvent)]]); ok {
		if r := w.Value(); r != nil {
			if fn := r.Load(); fn != nil {
				(*fn)(goLogEvent(event))
			}
		}
	}
}

// SetLogger sends this repo's events at level and above to fn, in place
// of the default logger, while its calls run: a host serving many
// repositories tells them apart. A nil fn or LogOff goes back to the
// default one. A call already under way may still reach the old fn, or
// lose an event. The rules of SetDefaultLogger hold.
func (r *Repo) SetLogger(level LogLevel, fn func(LogEvent)) {
	r.use(func(c *C.issuez_repo) error {
		r.logMu.Lock()
		defer r.logMu.Unlock()
		if fn == nil || level == LogOff {
			C.issuez_go_set_repo_logger(c, C.ISSUEZ_LOG_OFF, 0)
			if r.logFn != nil {
				r.logFn.Store(nil)
			}
			return nil
		}
		if r.logFn == nil {
			r.logFn = new(atomic.Pointer[func(LogEvent)])
			*r.logHandle = cgo.NewHandle(weak.Make(r.logFn))
		}
		r.logFn.Store(&fn)
		C.issuez_go_set_repo_logger(c, C.issuez_log_level(level), C.uintptr_t(*r.logHandle))
		return nil
	})
}

func goLogEvent(event unsafe.Pointer) LogEvent {
	e := (*C.issuez_log_event)(event)
	return LogEvent{
		Level:     LogLevel(e.level),
		Operation: goStr(e.operation),
		Message:   goStr(e.message),
		RepoPath:  goStr(e.repo_path),
		Subject:   goStr(e.subject),
		Duration:  time.Duration(e.duration_ns),
		Attempt:   int(e.attempt),
	}
}
