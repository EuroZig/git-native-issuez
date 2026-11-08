package issuez

import (
	"context"
	"iter"
)

// All yields every issue q matches, page after page (Query.Limit issues
// each) from q.After; an error is yielded once and ends it. Matches too
// damaged to read (Page.Skipped) aren't yielded.
//
//	for issue, err := range repo.All(ctx, issuez.Query{Labels: []string{"bug"}}) {
//		if err != nil {
//			return err
//		}
//		fmt.Println(issue.Title)
//	}
func (r *Repo) All(ctx context.Context, q Query) iter.Seq2[*Issue, error] {
	return func(yield func(*Issue, error) bool) {
		for {
			page, err := r.Query(ctx, q)
			if err != nil {
				yield(nil, err)
				return
			}
			for _, i := range page.Issues {
				if !yield(i, nil) {
					return
				}
			}
			if page.Next == "" {
				return
			}
			q.After = page.Next
		}
	}
}
