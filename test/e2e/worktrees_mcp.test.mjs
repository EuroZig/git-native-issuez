// End-to-end tests for live updates across linked worktrees: one
// repository checked out three times (`git worktree add`), a `git-issue
// mcp` in each of two worktrees, as two coding agents working on their own
// copies at once, and the command line writing too. The worktrees share
// one set of refs, so every server hears of every write, whichever
// worktree it came from, and concurrent writes are all kept.
//
// Usage: node worktrees_mcp.test.mjs <path to git-issue>
//
// Normally invoked through `zig build e2e` or `zig build ci`.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { connect as connectTo, issuesUri, issueUri } from "./live_client.mjs";

const [exe] = process.argv.slice(2);
if (!exe) {
  console.error("usage: node worktrees_mcp.test.mjs <path to git-issue>");
  process.exit(2);
}
const gitIssue = resolve(exe);

const root = mkdtempSync(join(tmpdir(), "git-issue-worktrees-mcp-"));
const env = {
  PATH: process.env.PATH,
  HOME: root,
  GIT_CONFIG_NOSYSTEM: "1",
  GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_CEILING_DIRECTORIES: root,
  GIT_AUTHOR_NAME: "Ada",
  GIT_AUTHOR_EMAIL: "ada@example.invalid",
  GIT_COMMITTER_NAME: "Ada",
  GIT_COMMITTER_EMAIL: "ada@example.invalid",
};
/** The main worktree. */
const main = join(root, "main");
/** Alice's and Bob's linked worktrees, each on a branch of its own. */
const wtA = join(root, "wt-a");
const wtB = join(root, "wt-b");

function git(cwd, ...args) {
  return execFileSync("git", args, { cwd, env, encoding: "utf8" });
}

function cli(cwd, ...args) {
  return execFileSync(gitIssue, args, { cwd, env, encoding: "utf8" });
}

/** A client of its own `git-issue mcp`, started in worktree `cwd`. */
function connect(name, cwd) {
  return connectTo({ gitIssue, cwd, env, name });
}

/** The IDs in the issue list, sorted. */
async function ids(agent) {
  const list = await agent.read(issuesUri);
  assert.equal(list.issues.length, list.total, "the list is not cut short");
  return list.issues.map((i) => i.id).sort();
}

/** @type {Awaited<ReturnType<typeof connect>>} */
let alice;
/** @type {Awaited<ReturnType<typeof connect>>} */
let bob;

before(async () => {
  git(root, "init", "-q", main);
  git(main, "commit", "-q", "--allow-empty", "-m", "Initial");
  git(main, "worktree", "add", "-q", "-b", "agent-a", wtA);
  git(main, "worktree", "add", "-q", "-b", "agent-b", wtB);
  alice = await connect("alice", wtA);
  bob = await connect("bob", wtB);
  await alice.client.subscribeResource({ uri: issuesUri });
  await bob.client.subscribeResource({ uri: issuesUri });
});

after(async () => {
  await alice?.client.close();
  await bob?.client.close();
  rmSync(root, { recursive: true, force: true });
});

test("an issue created in one worktree shows in the other", async () => {
  const created = await alice.call("create_issue", { title: "Found by Alice's agent" });
  await bob.updated(issuesUri, "alice's create_issue in wt-a");
  assert.deepEqual(await ids(bob), [created.id]);
  // And in the main worktree, from the command line.
  assert.match(cli(main, "ls"), /Found by Alice's agent/);
  await alice.settled(issuesUri, "its own create_issue");
});

test("concurrent creates in both worktrees are all kept", async () => {
  const before = await ids(alice);
  const n = 5;
  const created = await Promise.all(
    Array.from({ length: n }, (_, i) => [
      alice.call("create_issue", { title: `Alice's issue ${i}` }),
      bob.call("create_issue", { title: `Bob's issue ${i}` }),
    ]).flat(),
  );
  const want = [...before, ...created.map((c) => c.id)].sort();
  assert.equal(new Set(want).size, before.length + 2 * n, "every create made a new issue");

  // Both hear of the burst, and both end up with every issue.
  await alice.settled(issuesUri, "the concurrent creates");
  await bob.settled(issuesUri, "the concurrent creates");
  assert.deepEqual(await ids(alice), want);
  assert.deepEqual(await ids(bob), want);
});

test("concurrent comments on one issue are all kept", async () => {
  const issue = await alice.call("create_issue", { title: "Discussed by both" });
  await alice.settled(issuesUri, "its own create_issue");
  await bob.settled(issuesUri, "alice's create_issue");
  const uri = issueUri(issue.short_id);
  await alice.client.subscribeResource({ uri });
  await bob.client.subscribeResource({ uri });

  const n = 3;
  await Promise.all(
    Array.from({ length: n }, (_, i) => [
      alice.call("comment_issue", { id: issue.id, text: `Alice ${i}` }),
      bob.call("comment_issue", { id: issue.id, text: `Bob ${i}` }),
    ]).flat(),
  );
  await alice.updated(uri, "the concurrent comments");
  await bob.updated(uri, "the concurrent comments");
  await alice.drain();
  bob.clear();

  const want = Array.from({ length: n }, (_, i) => [`Alice ${i}`, `Bob ${i}`]).flat().sort();
  for (const agent of [alice, bob]) {
    const detail = await agent.read(uri);
    assert.deepEqual(detail.comments.map((c) => c.subject).sort(), want);
  }
  // The two servers agree on the issue's version.
  assert.equal((await alice.read(uri)).issue.version, (await bob.read(uri)).issue.version);
  await alice.client.unsubscribeResource({ uri });
  await bob.client.unsubscribeResource({ uri });
});

test("expect_version: of two concurrent edits one wins, the other reads again", async () => {
  const issue = await alice.call("create_issue", { title: "Contested" });
  await bob.settled(issuesUri, "alice's create_issue");
  const uri = issueUri(issue.short_id);
  await bob.client.subscribeResource({ uri });
  const version = (await bob.read(uri)).issue.version;
  assert.equal(version, issue.version);

  const results = await Promise.all([
    alice.client.callTool({
      name: "edit_issue",
      arguments: { id: issue.id, title: "Alice's title", expect_version: version },
    }),
    bob.client.callTool({
      name: "edit_issue",
      arguments: { id: issue.id, title: "Bob's title", expect_version: version },
    }),
  ]);
  const won = results.filter((r) => r.isError !== true);
  const lost = results.filter((r) => r.isError === true);
  assert.equal(won.length, 1, `exactly one edit wins: ${JSON.stringify(results)}`);
  assert.match(lost[0].content[0].text, /changed since expect_version/);
  const winner = won[0] === results[0] ? "Alice's title" : "Bob's title";

  // Bob hears of the winning edit (his own or Alice's) and sees it.
  await bob.updated(uri, "the winning edit");
  const now = (await bob.read(uri)).issue;
  assert.equal(now.title, winner);
  assert.notEqual(now.version, version);

  // The stale version still fails; the new one works.
  await bob.callFails("edit_issue", { id: issue.id, title: "Stale", expect_version: version });
  await bob.call("edit_issue", { id: issue.id, title: "Agreed title", expect_version: now.version });
  assert.equal((await alice.call("show_issue", { id: issue.id })).issue.title, "Agreed title");
  await bob.client.unsubscribeResource({ uri });
  await alice.drain();
  bob.clear();
});

test("the command line in a subdirectory of one worktree", async () => {
  const issue = await bob.call("create_issue", { title: "Commented from a subdirectory" });
  await alice.settled(issuesUri, "bob's create_issue");
  await bob.settled(issuesUri, "its own create_issue");
  const uri = issueUri(issue.short_id);
  await alice.client.subscribeResource({ uri });

  const sub = join(wtB, "src", "deep");
  mkdirSync(sub, { recursive: true });
  cli(sub, "comment", issue.id, "-m", "From wt-b/src/deep");
  await alice.updated(uri, "git issue comment in wt-b/src/deep");
  assert.equal((await alice.read(uri)).comments.at(-1).subject, "From wt-b/src/deep");
  await alice.client.unsubscribeResource({ uri });
  // The list hears of every change too.
  await bob.updated(issuesUri, "the comment");
  await alice.drain();
  bob.clear();
});

test("packing the refs changes nothing, and writes after it are heard", async () => {
  git(wtA, "pack-refs", "--all");
  await alice.notUpdated(issuesUri, "git pack-refs in wt-a");
  await bob.notUpdated(issuesUri, "git pack-refs in wt-a");
  assert.equal((await alice.read(issuesUri)).total, (await bob.read(issuesUri)).total);

  const created = await bob.call("create_issue", { title: "After pack-refs" });
  await alice.updated(issuesUri, "bob's create_issue after pack-refs");
  assert.ok((await ids(alice)).includes(created.id));
  await bob.updated(issuesUri, "its own create_issue");
  await alice.drain();
  bob.clear();
});

test("a worktree added later, and one server writing to another worktree", async () => {
  const wtC = join(root, "wt-c");
  git(main, "worktree", "add", "-q", "-b", "agent-c", wtC);
  const carol = await connect("carol", wtC);
  try {
    await carol.client.subscribeResource({ uri: issuesUri });
    const fromCarol = await carol.call("create_issue", { title: "From wt-c" });
    await alice.updated(issuesUri, "carol's create_issue in wt-c");
    await bob.updated(issuesUri, "carol's create_issue in wt-c");
    assert.ok((await ids(bob)).includes(fromCarol.id));

    // Alice's server, told to use Carol's worktree: the same issues.
    const viaRepo = await alice.call("create_issue", { title: "Into wt-c by path", repo: wtC });
    await carol.updated(issuesUri, "alice's create_issue with repo wt-c");
    await bob.updated(issuesUri, "alice's create_issue with repo wt-c");
    assert.deepEqual(await ids(carol), await ids(bob));
    assert.ok((await ids(alice)).includes(viaRepo.id));
  } finally {
    await carol.client.close();
  }

  // Removing a worktree leaves the others watching.
  git(main, "worktree", "remove", wtC);
  await alice.drain();
  bob.clear();
  const last = await bob.call("create_issue", { title: "After wt-c is gone" });
  await alice.updated(issuesUri, "bob's create_issue after removing wt-c");
  assert.ok((await ids(alice)).includes(last.id));
});
