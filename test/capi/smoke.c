/* What only a C compiler can check: the header compiles as C11 with every
 * warning an error, its macros work, and a round trip through the library
 * runs clean under ASan and UBSan. Every function is tested from Zig
 * (test/capi_zig).
 *
 *   smoke <empty work dir>
 */
#include <issuez.h>

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond);               \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

/* Fails the test with the error's details, and frees it. */
static int ok(issuez_code rc, issuez_error *err, const char *what) {
    if (rc == ISSUEZ_OK)
        return 1;
    issuez_str m = issuez_error_message(err);
    fprintf(stderr, "%s: %s: %.*s\n", what, issuez_code_name(rc), (int)m.len, m.ptr ? m.ptr : "");
    issuez_error_free(err);
    failures++;
    return 0;
}

static int str_is(issuez_str s, const char *want) {
    return s.len == strlen(want) && memcmp(s.ptr, want, s.len) == 0 && s.ptr[s.len] == 0;
}

static void sh(const char *fmt, const char *dir) {
    char cmd[4096];
    snprintf(cmd, sizeof cmd, fmt, dir, dir, dir);
    if (system(cmd) != 0) {
        fprintf(stderr, "failed: %s\n", cmd);
        exit(1);
    }
}

int main(int argc, char **argv) {
    if (argc != 2)
        return 2;
    const char *dir = argv[1];
    /* The library writes to pipes; a host must not die of SIGPIPE. */
    signal(SIGPIPE, SIG_IGN);
    sh("mkdir -p %s && git init -q %s && git -C %s config user.email t@example.com", dir);
    sh("git -C %s config user.name Tester%.0s%.0s", dir);

    /* The macros, as C sees them. */
    issuez_op zero = ISSUEZ_OP_INIT;
    CHECK(zero.verb == 0 && zero.target == 0 && zero.str.ptr == NULL && zero.reserved[1] == 0);
    issuez_str lit = ISSUEZ_STR("literal");
    CHECK(lit.len == 7);
    issuez_op ops[] = {issuez_set_title(ISSUEZ_STR("From C")), issuez_add_label(ISSUEZ_STR("c"))};
    CHECK(ISSUEZ_COUNT(ops) == 2);

    issuez_error *err = NULL;
    if (!ok(issuez_init(ISSUEZ_ABI_VERSION, &err), err, "init"))
        return 1;
    issuez_repo *repo = NULL;
    if (!ok(issuez_repo_open(issuez_str_c(dir), NULL, 0, &repo, &err), err, "open"))
        return 1;

    /* Create, load, read back: one round trip, every handle freed. */
    issuez_actor ada = {ISSUEZ_STR("Ada"), ISSUEZ_STR("ada@example.com"), {NULL, 0}, NULL, {0}};
    issuez_write *w = NULL;
    if (ok(issuez_issue_create(repo, ops, ISSUEZ_COUNT(ops), &ada, NULL, &w, &err), err, "create")) {
        issuez_issue *issue = NULL;
        if (ok(issuez_write_load_issue(w, NULL, &issue, &err), err, "load")) {
            const issuez_issue_info *info = issuez_issue_info_of(issue);
            CHECK(str_is(info->title, "From C"));
            CHECK(issuez_issue_label_count(issue) == 1);
            CHECK(str_is(issuez_issue_label_at(issue, 0), "c"));
            CHECK(info->state == ISSUEZ_STATE_OPEN);
            issuez_issue_free(issue);
        }
        issuez_write_free(w);
    }
    issuez_issue_list *list = NULL;
    if (ok(issuez_query_run(repo, NULL, 0, NULL, &list, &err), err, "query")) {
        CHECK(issuez_issue_list_len(list) == 1);
        issuez_issue_list_free(list);
    }

    issuez_repo_close(repo);
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("C smoke test passed\n");
    return 0;
}
