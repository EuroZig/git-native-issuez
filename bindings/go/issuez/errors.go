package issuez

/*
#include "issuez.h"
*/
import "C"

import (
	"context"
	"errors"
)

// Code is a stable error code (ISSUEZ_E_*).
type Code int

const (
	CodeABI             Code = C.ISSUEZ_E_ABI
	CodeInvalidArgument Code = C.ISSUEZ_E_INVALID_ARGUMENT
	CodeInvalidValue    Code = C.ISSUEZ_E_INVALID_VALUE
	CodeLimit           Code = C.ISSUEZ_E_LIMIT
	CodeNotFound        Code = C.ISSUEZ_E_NOT_FOUND
	CodeAmbiguous       Code = C.ISSUEZ_E_AMBIGUOUS
	CodeVersionMismatch Code = C.ISSUEZ_E_VERSION_MISMATCH
	CodeGuard           Code = C.ISSUEZ_E_GUARD
	CodeContended       Code = C.ISSUEZ_E_CONTENDED // past the retry budget (WithRetries): final
	CodePurged          Code = C.ISSUEZ_E_PURGED
	CodeCorrupt         Code = C.ISSUEZ_E_CORRUPT
	CodeRejected        Code = C.ISSUEZ_E_REJECTED
	CodeNotARepository  Code = C.ISSUEZ_E_NOT_A_REPOSITORY
	CodeGit             Code = C.ISSUEZ_E_GIT
	CodeGitVersion      Code = C.ISSUEZ_E_GIT_VERSION
	CodeTimeout         Code = C.ISSUEZ_E_TIMEOUT
	CodeCancelled       Code = C.ISSUEZ_E_CANCELLED
	CodeLFS             Code = C.ISSUEZ_E_LFS
	CodeUnsupported     Code = C.ISSUEZ_E_UNSUPPORTED
	CodeNoMem           Code = C.ISSUEZ_E_NOMEM
	CodeInternal        Code = C.ISSUEZ_E_INTERNAL
)

// String is the code's name: "VERSION_MISMATCH", ...
func (c Code) String() string { return C.GoString(C.issuez_code_name(C.issuez_code(c))) }

// Sentinels for errors.Is: errors.Is(err, issuez.ErrVersionMismatch).
var (
	ErrNotFound        = &Error{Code: CodeNotFound}
	ErrAmbiguous       = &Error{Code: CodeAmbiguous}
	ErrInvalidValue    = &Error{Code: CodeInvalidValue}
	ErrVersionMismatch = &Error{Code: CodeVersionMismatch}
	ErrGuard           = &Error{Code: CodeGuard}
	ErrPurged          = &Error{Code: CodePurged}
	ErrRejected        = &Error{Code: CodeRejected}
)

// Error is everything the library said about a failure.
type Error struct {
	Code    Code
	Message string
	// What it is about: an issue UUID, a ref, a field key.
	Subject   string
	GitStderr string
	// VersionMismatch: the issue's tip now.
	CurrentTip OID
	// InvalidValue and Guard: every problem, not just the first.
	Problems []Problem
	// A committed write whose subsequent reload failed. Do not retry the
	// mutation when this is non-nil, even for a context cancellation.
	Write *Write
	// context.Canceled or DeadlineExceeded when the context ended the call.
	cause error
}

// Error is "issuez: <subject>: <message>", without the subject when it
// has none.
func (e *Error) Error() string {
	if e.Subject != "" {
		return "issuez: " + e.Subject + ": " + e.Message
	}
	return "issuez: " + e.Message
}

// Is matches on the code, so the sentinels above work.
func (e *Error) Is(target error) bool {
	t, ok := target.(*Error)
	return ok && t.Code == e.Code
}

// Unwrap is context.Canceled or context.DeadlineExceeded when the
// call's context ended it, so errors.Is sees those too; nil otherwise.
func (e *Error) Unwrap() error { return e.cause }

// takeError copies and frees a C error; ctx is the call's, for the cause
// of a cancellation.
func takeError(ctx context.Context, c *C.issuez_error) error {
	if c == nil {
		return &Error{Code: CodeInternal, Message: "failed without details"}
	}
	defer C.issuez_error_free(c)
	e := &Error{
		Code:      Code(C.issuez_error_code(c)),
		Message:   goStr(C.issuez_error_message(c)),
		Subject:   goStr(C.issuez_error_subject(c)),
		GitStderr: goStr(C.issuez_error_git_stderr(c)),
		Problems:  goProblems(C.issuez_error_problems(c)),
	}
	var tip C.issuez_oid
	if C.issuez_error_current_tip(c, &tip) {
		e.CurrentTip = goOID(tip)
	}
	if w := C.issuez_error_write(c); w != nil {
		e.Write = goWrite(w)
	}
	if (e.Code == CodeCancelled || e.Code == CodeTimeout) && ctx.Err() != nil {
		e.cause = ctx.Err()
	}
	return e
}

// UserMessage is the library's message when err refused a write for a
// rule the user can act on: an invalid value, a limit, or a guard (a
// milestone with open issues, a blocker loop, ...). Hosts show it as it
// is; other errors are failures and stay in the logs.
func UserMessage(err error) (string, bool) {
	var e *Error
	if !errors.As(err, &e) {
		return "", false
	}
	switch e.Code {
	case CodeInvalidValue, CodeLimit, CodeGuard:
		return e.Message, true
	}
	return "", false
}

// IsCancelled reports a call ended by its context (or the library's
// deadline).
func IsCancelled(err error) bool {
	var e *Error
	return errors.As(err, &e) && (e.Code == CodeCancelled || e.Code == CodeTimeout)
}

// ─── Problems ──────────────────────────────────────────────────────────

// ProblemKind is what is wrong, the rule a Problem breaks.
type ProblemKind uint32

const (
	ProblemEmpty              ProblemKind = C.ISSUEZ_PROBLEM_EMPTY
	ProblemNewline            ProblemKind = C.ISSUEZ_PROBLEM_NEWLINE
	ProblemTooLong            ProblemKind = C.ISSUEZ_PROBLEM_TOO_LONG
	ProblemTooMany            ProblemKind = C.ISSUEZ_PROBLEM_TOO_MANY
	ProblemBadFormat          ProblemKind = C.ISSUEZ_PROBLEM_BAD_FORMAT
	ProblemUnknownWorkflow    ProblemKind = C.ISSUEZ_PROBLEM_UNKNOWN_WORKFLOW_STATE
	ProblemReadOnlyField      ProblemKind = C.ISSUEZ_PROBLEM_READ_ONLY_FIELD
	ProblemIncompatible       ProblemKind = C.ISSUEZ_PROBLEM_INCOMPATIBLE
	ProblemCycle              ProblemKind = C.ISSUEZ_PROBLEM_CYCLE
	ProblemMissingTarget      ProblemKind = C.ISSUEZ_PROBLEM_MISSING_TARGET
	ProblemOpenChildren       ProblemKind = C.ISSUEZ_PROBLEM_OPEN_CHILDREN
	ProblemClosedAncestor     ProblemKind = C.ISSUEZ_PROBLEM_CLOSED_ANCESTOR
	ProblemMilestoneClosed    ProblemKind = C.ISSUEZ_PROBLEM_MILESTONE_CLOSED
	ProblemDuplicateNumber    ProblemKind = C.ISSUEZ_PROBLEM_DUPLICATE_NUMBER
	ProblemConflict           ProblemKind = C.ISSUEZ_PROBLEM_CONFLICT
	ProblemTrailerBody        ProblemKind = C.ISSUEZ_PROBLEM_TRAILER_BODY
	ProblemUnknownTarget      ProblemKind = C.ISSUEZ_PROBLEM_UNKNOWN_TARGET
	ProblemBadVerb            ProblemKind = C.ISSUEZ_PROBLEM_BAD_VERB
	ProblemMissingValue       ProblemKind = C.ISSUEZ_PROBLEM_MISSING_VALUE
	ProblemSelfReference      ProblemKind = C.ISSUEZ_PROBLEM_SELF_REFERENCE
	ProblemTooDeep            ProblemKind = C.ISSUEZ_PROBLEM_TOO_DEEP
	ProblemDeletedTarget      ProblemKind = C.ISSUEZ_PROBLEM_DELETED_TARGET
	ProblemMilestoneOpenWork  ProblemKind = C.ISSUEZ_PROBLEM_MILESTONE_OPEN_WORK
	ProblemInvalidStoredValue ProblemKind = C.ISSUEZ_PROBLEM_INVALID_STORED_VALUE
	ProblemPendingEvent       ProblemKind = C.ISSUEZ_PROBLEM_PENDING_EVENT
	// Push check.
	ProblemInvalidHistory    ProblemKind = C.ISSUEZ_PROBLEM_INVALID_HISTORY
	ProblemUnsupportedFormat ProblemKind = C.ISSUEZ_PROBLEM_UNSUPPORTED_FORMAT
	ProblemNonFastForward    ProblemKind = C.ISSUEZ_PROBLEM_NON_FAST_FORWARD
	ProblemRefDeleted        ProblemKind = C.ISSUEZ_PROBLEM_REF_DELETED
	ProblemLocalRef          ProblemKind = C.ISSUEZ_PROBLEM_LOCAL_REF
	ProblemBadRefName        ProblemKind = C.ISSUEZ_PROBLEM_BAD_REF_NAME
	ProblemAuthorMismatch    ProblemKind = C.ISSUEZ_PROBLEM_AUTHOR_MISMATCH
	ProblemPurged            ProblemKind = C.ISSUEZ_PROBLEM_PURGED
	ProblemPurgeNotAllowed   ProblemKind = C.ISSUEZ_PROBLEM_PURGE_NOT_ALLOWED
	ProblemNotAPurge         ProblemKind = C.ISSUEZ_PROBLEM_NOT_A_PURGE
	ProblemNotDerived        ProblemKind = C.ISSUEZ_PROBLEM_NOT_DERIVED
)

// Problem is one thing wrong with a value, a write or stored data.
type Problem struct {
	Kind    ProblemKind
	Field   Field
	Key     string // trailer key, for FieldExtra
	Value   string
	Subject string // the other issue or milestone involved
	Message string
	// Index of the op that caused it (Edit/Query order), -1 if none.
	Op int
}

func goProblems(p *C.issuez_problems) []Problem {
	if p == nil {
		return nil
	}
	n := C.issuez_problems_len(p)
	if n == 0 {
		return nil
	}
	out := make([]Problem, n)
	for i := range out {
		c := C.issuez_problems_at(p, C.size_t(i))
		out[i] = Problem{
			Kind:    ProblemKind(c.kind),
			Field:   Field(c.field),
			Key:     goStr(c.key),
			Value:   goStr(c.value),
			Subject: goStr(c.subject),
			Message: goStr(c.message),
			Op:      int(c.op_index),
		}
	}
	return out
}

// takeProblems copies and frees an owned list.
func takeProblems(p *C.issuez_problems) []Problem {
	defer C.issuez_problems_free(p)
	return goProblems(p)
}
