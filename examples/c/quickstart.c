/* Quickstart for the C API: create, comment on, close, list and show
 * issues in a git repository.
 *
 *   cc -I<dir of issuez.h> quickstart.c libissuez.a -lpthread -o quickstart
 *   ./quickstart <git repository>
 *
 * zig build example-c-quickstart runs it on a fresh repository. Every call
 * returns ISSUEZ_OK or an error code and fills *err, which the caller
 * frees. Every handle handed back through an out parameter is the
 * caller's, freed with its type's _free; strings and records read from a
 * handle live as long as it does.
 */
#include <issuez.h>

#include <stdio.h>
#include <string.h>

/* Prints the error, frees it, and says whether the call failed. */
static int failed(issuez_code rc, issuez_error *err, const char *what) {
    if (rc == ISSUEZ_OK)
        return 0;
    issuez_str m = issuez_error_message(err);
    fprintf(stderr, "%s: %s: %.*s\n", what, issuez_code_name(rc), (int)m.len, m.ptr);
    issuez_error_free(err);
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: quickstart <git repository>\n");
        return 2;
    }
    issuez_error *err = NULL;
    issuez_repo *repo = NULL;
    /* No options: the repository's git config, git from PATH. */
    if (failed(issuez_repo_open(issuez_str_c(argv[1]), NULL, 0, &repo, &err), err, "open"))
        return 1;
    /* Who writes: a host passes its user; the time NULL is now. */
    issuez_actor ada = {ISSUEZ_STR("Ada"), ISSUEZ_STR("ada@example.invalid"), {NULL, 0}, NULL, {0}};
    int status = 1;

    /* Create: a write is a list of ops, one per field. */
    issuez_op create[] = {
        issuez_set_title(ISSUEZ_STR("Login page crashes")),
        issuez_set_description(ISSUEZ_STR("Clicking \"Sign in\" with an empty password crashes.")),
        issuez_add_label(ISSUEZ_STR("bug")),
        issuez_add_label(ISSUEZ_STR("ui")),
    };
    issuez_write *w = NULL;
    if (failed(issuez_issue_create(repo, create, ISSUEZ_COUNT(create), &ada, NULL, &w, &err),
               err, "create"))
        goto done;
    /* The ID is borrowed from the receipt: copy it before freeing that. */
    char id_buf[64];
    issuez_str got = issuez_write_id(w);
    snprintf(id_buf, sizeof id_buf, "%.*s", (int)got.len, got.ptr);
    issuez_write_free(w);
    issuez_str id = issuez_str_c(id_buf);
    printf("created %.7s\n", id_buf);

    /* Comment, edit and close: every later write is issuez_issue_update. */
    issuez_op comment[] = {issuez_set_comment(ISSUEZ_STR("Reproduced on 1.4.2."))};
    issuez_op edit[] = {
        issuez_add_label(ISSUEZ_STR("regression")),
        issuez_remove_label(ISSUEZ_STR("ui")),
    };
    issuez_op close_it[] = {issuez_set_state(ISSUEZ_STR("closed"))};
    struct {
        const issuez_op *ops;
        size_t n;
        const char *what;
    } writes[] = {
        {comment, ISSUEZ_COUNT(comment), "comment"},
        {edit, ISSUEZ_COUNT(edit), "edit"},
        {close_it, ISSUEZ_COUNT(close_it), "close"},
    };
    for (size_t k = 0; k < ISSUEZ_COUNT(writes); k++) {
        if (failed(issuez_issue_update(repo, id, writes[k].ops, writes[k].n, &ada, NULL, &w, &err),
                   err, writes[k].what))
            goto done;
        issuez_write_free(w);
    }

    /* List: a query of ops; none is every open issue, so ask for any. */
    issuez_op query[] = {issuez_q_done(-1)};
    issuez_issue_list *list = NULL;
    if (failed(issuez_query_run(repo, query, ISSUEZ_COUNT(query), NULL, &list, &err), err,
               "query"))
        goto done;
    printf("\nID       STATE   TITLE\n");
    for (size_t k = 0; k < issuez_issue_list_len(list); k++) {
        const issuez_issue *i = issuez_issue_list_at(list, k);
        issuez_str iid = issuez_issue_id(i), state = issuez_issue_state_name(i);
        issuez_str title = issuez_issue_title(i);
        printf("%.7s  %-6.*s  %.*s\n", iid.ptr, (int)state.len, state.ptr, (int)title.len,
               title.ptr);
    }
    issuez_issue_list_free(list);

    /* Show one issue with its comments. */
    issuez_issue *issue = NULL;
    if (failed(issuez_issue_load(repo, id, NULL, &issue, &err), err, "load"))
        goto done;
    issuez_str title = issuez_issue_title(issue);
    printf("\n%.*s\n", (int)title.len, title.ptr);
    for (size_t k = 0; k < issuez_issue_comment_count(issue); k++) {
        const issuez_comment *c = issuez_issue_comment_at(issue, k);
        printf("--- %.*s: %.*s\n", (int)c->author->email.len, c->author->email.ptr,
               (int)c->text.len, c->text.ptr);
    }
    issuez_issue_free(issue);
    status = 0;

done:
    issuez_repo_close(repo);
    return status;
}
