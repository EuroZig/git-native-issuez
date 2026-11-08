package issuez_test

import (
	"context"
	"errors"
	"fmt"
	"log"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

// "Comment and close" as a web handler would do it.
func Example_commentAndClose() {
	ctx := context.Background()
	repo, err := issuez.Open("/srv/git/ada/app.git",
		issuez.WithCommitter("Host", "noreply@example.com"),
		issuez.WithExclusiveScopes("kind", "priority"),
	)
	if err != nil {
		log.Fatal(err)
	}
	defer repo.Close()

	id, err := repo.ResolveOne(ctx, issuez.KindIssue, "#12")
	if err != nil {
		log.Fatal(err)
	}
	shown, err := repo.Load(ctx, id) // what the page rendered
	if err != nil {
		log.Fatal(err)
	}

	edit := new(issuez.Edit).
		AddComment("Fixed in 1a2b3c4.").
		SetState("closed").
		SetFixedBy("1a2b3c4")

	ada := issuez.Actor{Name: "Ada", Email: "ada@example.com", UserID: "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d"}
	// The tip the user saw: a conflict if someone wrote in between.
	w, err := repo.Update(ctx, id, edit, ada, issuez.Reload(), issuez.ExpectTip(shown.Tip))

	var ie *issuez.Error
	errors.As(err, &ie)
	switch {
	case err == nil:
		for _, c := range w.Entry.Changes {
			fmt.Printf("%s: %q -> %q\n", c.Field, c.Old, c.New) // notifications
		}
		_ = w.Issue // refresh the cache row
	case errors.Is(err, issuez.ErrVersionMismatch):
		fmt.Println("changed meanwhile; now at", ie.CurrentTip)
	case ie != nil && len(ie.Problems) > 0:
		for _, p := range ie.Problems {
			fmt.Printf("%s (op %d): %s\n", p.Field, p.Op, p.Message) // highlight form fields
		}
	default:
		log.Fatal(err)
	}
}

// What a post-receive hook or cron does to keep a cache in sync.
func Example_syncCache() {
	ctx := context.Background()
	repo, _ := issuez.Open("/srv/git/ada/app.git")
	defer repo.Close()

	var stored []byte // loaded from the host's DB
	var old issuez.Snapshot
	_ = old.UnmarshalBinary(stored)

	now, _ := repo.Snapshot(ctx)
	var changed []string
	for _, d := range issuez.Diff(&old, now) {
		if d.Kind == issuez.KindIssue && d.Change != issuez.ChangeRemoved {
			changed = append(changed, d.ID)
		}
	}
	issues, skipped, _ := repo.LoadMany(ctx, changed)
	fmt.Println(len(issues), "to upsert,", len(skipped), "damaged")
	stored, _ = now.MarshalBinary()
}

func Example_query() {
	ctx := context.Background()
	repo, _ := issuez.Open("/srv/git/ada/app.git")
	defer repo.Close()

	page, _ := repo.Query(ctx, issuez.Query{
		Labels:    []string{"bug"},
		Assignees: []string{"ada@example.com"},
		Order:     issuez.SortUpdated,
		Limit:     50,
	})
	for _, i := range page.Issues {
		fmt.Println(i.Number, i.Title)
	}
}
