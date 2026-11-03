// End-to-end tests for live updates in `git-issue mcp`: two servers on one
// repository, each with an official MCP TypeScript SDK client, and the
// command line writing too. A client that subscribed to a resource hears
// of every change the others make, and reads it.
//
// Usage: node live_mcp.test.mjs <path to git-issue>
//
// Normally invoked through `zig build e2e` or `zig build ci`.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { ResourceUpdatedNotificationSchema } from "@modelcontextprotocol/sdk/types.js";

const [exe] = process.argv.slice(2);
if (!exe) {
  console.error("usage: node live_mcp.test.mjs <path to git-issue>");
  process.exit(2);
}
const gitIssue = resolve(exe);

const root = mkdtempSync(join(tmpdir(), "git-issue-live-mcp-"));
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
const repo = join(root, "repo");

const issuesUri = "git-issue://issues";
const milestonesUri = "git-issue://milestones";
const issueUri = (id) => `git-issue://issues/${id}`;

/** How long a notification may take: the watcher waits for quiet first. */
const timeoutMs = 5000;
/** How long to wait to be sure one doesn't come. */
const quietMs = 600;

function cli(...args) {
  return execFileSync(gitIssue, args, { cwd: repo, env, encoding: "utf8" });
}

/** A client of its own `git-issue mcp`, recording resource updates. */
async function connect(name) {
  const transport = new StdioClientTransport({
    command: gitIssue,
    args: ["mcp"],
    cwd: repo,
    env,
    stderr: "inherit",
  });
  const client = new Client({ name, version: "0.0.0" });
  /** @type {string[]} */
  const updates = [];
  /** @type {(() => void)[]} */
  const waiting = [];
  client.setNotificationHandler(ResourceUpdatedNotificationSchema, (n) => {
    updates.push(n.params.uri);
    for (const wake of waiting.splice(0)) wake();
  });
  await client.connect(transport);

  return {
    client,
    updates,
    /** Waits for an update of `uri`, and forgets every update up to it. */
    async updated(uri, why) {
      const deadline = Date.now() + timeoutMs;
      for (;;) {
        const at = updates.indexOf(uri);
        if (at >= 0) {
          updates.splice(0, at + 1);
          return;
        }
        const left = deadline - Date.now();
        if (left <= 0) assert.fail(`${name}: no update of ${uri} after ${why}; got [${updates}]`);
        await new Promise((wake) => {
          waiting.push(wake);
          setTimeout(wake, left);
        });
      }
    },
    /** Asserts that no update of `uri` comes for a while. */
    async notUpdated(uri, why) {
      await new Promise((r) => setTimeout(r, quietMs));
      assert.ok(!updates.includes(uri), `${name}: ${uri} updated after ${why}`);
    },
    clear() {
      updates.length = 0;
    },
    /** Waits for an update of `uri`, then for quiet, and forgets them all. */
    async settled(uri, why) {
      await this.updated(uri, why);
      await new Promise((r) => setTimeout(r, quietMs));
      updates.length = 0;
    },
    /** A resource's JSON. */
    async read(uri) {
      const { contents } = await client.readResource({ uri });
      assert.equal(contents.length, 1);
      assert.equal(contents[0].mimeType, "application/json");
      return JSON.parse(contents[0].text);
    },
    /** `structuredContent` of a tool call that must succeed. */
    async call(tool, args = {}) {
      const result = await client.callTool({ name: tool, arguments: args });
      assert.notEqual(result.isError, true, `${tool} failed: ${result.content?.[0]?.text}`);
      return result.structuredContent;
    },
  };
}

/** @type {Awaited<ReturnType<typeof connect>>} */
let alice;
/** @type {Awaited<ReturnType<typeof connect>>} */
let bob;

before(async () => {
  execFileSync("git", ["init", "-q", repo], { env });
  alice = await connect("alice");
  bob = await connect("bob");
});

after(async () => {
  await alice?.client.close();
  await bob?.client.close();
  rmSync(root, { recursive: true, force: true });
});

test("resources are listed", async () => {
  const { resources } = await bob.client.listResources();
  assert.deepEqual(
    resources.map((r) => r.uri),
    [issuesUri, milestonesUri],
  );
  const { resourceTemplates } = await bob.client.listResourceTemplates();
  assert.deepEqual(
    resourceTemplates.map((t) => t.uriTemplate),
    ["git-issue://issues/{id}"],
  );
});

test("an issue created by one server shows in the other's list", async () => {
  await bob.client.subscribeResource({ uri: issuesUri });
  assert.equal((await bob.read(issuesUri)).total, 0);

  const created = await alice.call("create_issue", { title: "Written by Alice's agent" });
  await bob.updated(issuesUri, "alice's create_issue");
  const list = await bob.read(issuesUri);
  assert.equal(list.total, 1);
  assert.equal(list.issues[0].id, created.id);
  assert.equal(list.issues[0].title, "Written by Alice's agent");
});

test("and the other way round", async () => {
  await alice.client.subscribeResource({ uri: issuesUri });
  alice.clear();
  await bob.call("create_issue", { title: "Written by Bob's agent" });
  await alice.updated(issuesUri, "bob's create_issue");
  assert.equal((await alice.read(issuesUri)).total, 2);
});

test("an issue's resource: its own changes only", async () => {
  const one = await alice.call("create_issue", { title: "Watched" });
  const two = await alice.call("create_issue", { title: "Not watched" });
  // Bob's server reports the creations a moment later: once they are
  // out, a later update of the issue can't be about its creation.
  await bob.settled(issuesUri, "alice's create_issue");
  await bob.client.subscribeResource({ uri: issueUri(one.short_id) });

  // The command line comments on it.
  cli("comment", one.id, "-m", "From the command line");
  await bob.updated(issueUri(one.short_id), "git issue comment");
  const detail = await bob.read(issueUri(one.short_id));
  assert.equal(detail.issue.id, one.id);
  assert.equal(detail.comments.at(-1).subject, "From the command line");

  // Another issue changing tells the list, not this one.
  bob.clear();
  await alice.call("edit_issue", { id: two.id, title: "Still not watched" });
  await bob.updated(issuesUri, "alice's edit of another issue");
  await bob.notUpdated(issueUri(one.short_id), "alice's edit of another issue");

  // Closing it from the other server.
  bob.clear();
  await alice.call("set_issue_state", { id: one.id, state: "closed" });
  await bob.updated(issueUri(one.short_id), "alice's set_issue_state");
  assert.equal((await bob.read(issueUri(one.short_id))).issue.state, "closed");
});

test("milestones change with the command line", async () => {
  await bob.client.subscribeResource({ uri: milestonesUri });
  bob.clear();
  cli("milestone", "create", "1.0");
  await bob.updated(milestonesUri, "git issue milestone create");
  const { milestones } = await bob.read(milestonesUri);
  assert.deepEqual(
    milestones.map((m) => m.name),
    ["1.0"],
  );
});

test("unsubscribed, nothing more comes", async () => {
  await bob.client.unsubscribeResource({ uri: issuesUri });
  await bob.client.unsubscribeResource({ uri: milestonesUri });
  bob.clear();
  await alice.call("create_issue", { title: "Bob doesn't hear of this" });
  await alice.updated(issuesUri, "its own create_issue");
  await bob.notUpdated(issuesUri, "unsubscribing");
});
