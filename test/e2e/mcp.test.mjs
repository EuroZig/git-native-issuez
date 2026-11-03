// End-to-end tests for `git-issue mcp`, with the official MCP TypeScript SDK
// as the reference client: the real binary over stdio, on real git
// repositories. The SDK checks every tool result against the tool's
// outputSchema.
//
// Usage: node mcp.test.mjs <path to git-issue> <version>
//
// Normally invoked through `zig build e2e` or `zig build ci`.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { ErrorCode, McpError } from "@modelcontextprotocol/sdk/types.js";

const [exe, version] = process.argv.slice(2);
if (!exe || !version) {
  console.error("usage: node mcp.test.mjs <path to git-issue> <version>");
  process.exit(2);
}
// The build passes it relative to its own directory; servers start in others.
const gitIssue = resolve(exe);

const tools = [
  "list_issues",
  "show_issue",
  "search_issues",
  "list_milestones",
  "create_issue",
  "comment_issue",
  "edit_issue",
  "set_issue_state",
];
const readOnly = new Set(["list_issues", "show_issue", "search_issues", "list_milestones"]);

// git isolated from the user's and the system's config, with a fixed
// identity, and kept from finding a repository above the temporary one.
const root = mkdtempSync(join(tmpdir(), "git-issue-mcp-e2e-"));
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
const other = join(root, "other");
const outside = join(root, "outside");

function git(cwd, ...args) {
  return execFileSync("git", args, { cwd, env, encoding: "utf8" });
}

function cli(cwd, ...args) {
  return execFileSync(gitIssue, args, { cwd, env, encoding: "utf8" });
}

/** A client of `git-issue mcp` started in `cwd`. */
async function connect(cwd) {
  const transport = new StdioClientTransport({
    command: gitIssue,
    args: ["mcp"],
    cwd,
    env,
    stderr: "inherit",
  });
  const client = new Client({ name: "git-issue-e2e", version: "0.0.0" });
  await client.connect(transport);
  // Makes the SDK validate results against the output schemas.
  await client.listTools();
  return client;
}

/** `structuredContent` of a call that must succeed. */
async function ok(client, name, args = {}) {
  const result = await client.callTool({ name, arguments: args });
  assert.notEqual(result.isError, true, `${name} failed: ${result.content?.[0]?.text}`);
  return result.structuredContent;
}

/** The error text of a call that must fail as a tool error. */
async function failed(client, name, args = {}) {
  const result = await client.callTool({ name, arguments: args });
  assert.equal(result.isError, true, `${name} should have failed`);
  return result.content[0].text;
}

/** @type {Client} */
let client;

before(async () => {
  for (const dir of [repo, other]) git(root, "init", "-q", dir);
  mkdirSync(outside);
  client = await connect(repo);
});

after(async () => {
  await client?.close();
  rmSync(root, { recursive: true, force: true });
});

test("initialize", () => {
  assert.deepEqual(client.getServerVersion(), {
    name: "git-issue",
    title: "git-native-issuez",
    version,
  });
  assert.deepEqual(client.getServerCapabilities(), {
    logging: {},
    resources: { subscribe: true },
    tools: {},
  });
  assert.match(client.getInstructions() ?? "", /refs\/issues/);
  assert.match(client.getInstructions() ?? "", /expect_version/);
});

test("ping and logging/setLevel", async () => {
  assert.deepEqual(await client.ping(), {});
  assert.deepEqual(await client.setLoggingLevel("debug"), {});
});

test("tools/list", async () => {
  const listed = (await client.listTools()).tools;
  assert.deepEqual(
    listed.map((t) => t.name),
    tools,
  );
  for (const t of listed) {
    assert.equal(t.inputSchema.type, "object", t.name);
    assert.equal(t.inputSchema.properties.repo?.type, "string", `${t.name} takes repo`);
    assert.equal(t.outputSchema?.type, "object", `${t.name} has an output schema`);
    assert.equal(t.annotations?.readOnlyHint, readOnly.has(t.name), t.name);
    assert.equal(t.annotations?.openWorldHint, false, t.name);
    if (!readOnly.has(t.name)) assert.equal(t.annotations?.destructiveHint, false, t.name);
  }
  const required = Object.fromEntries(listed.map((t) => [t.name, t.inputSchema.required ?? []]));
  assert.deepEqual(required.show_issue, ["id"]);
  assert.deepEqual(required.create_issue, ["title"]);
  assert.deepEqual(required.comment_issue, ["id", "text"]);
  assert.deepEqual(required.set_issue_state, ["id", "state"]);
  assert.deepEqual(required.search_issues, ["text"]);
});

test("every tool, start to finish, and the CLI sees the same issues", async () => {
  // A milestone made on the command line.
  cli(repo, "milestone", "create", "v1.0", "--due", "2026-12-01");
  const { milestones } = await ok(client, "list_milestones");
  assert.deepEqual(
    milestones.map((m) => [m.name, m.status, m.due, m.progress]),
    [["v1.0", "open", "2026-12-01", { closed: 0, total: 0 }]],
  );

  const parent = await ok(client, "create_issue", {
    title: "Release 1.0",
    labels: ["release"],
    priority: "high",
    milestone: "v1.0",
  });
  assert.match(parent.id, /^[0-9a-f-]{36}$/);
  assert.equal(parent.short_id, parent.id.slice(0, 7));
  const child = await ok(client, "create_issue", {
    title: "Write the changelog",
    description: "Every change since 0.1.",
    parent: parent.short_id,
    estimate: "1h30m",
    workflow: "ready",
  });

  // Closing the parent waits for its sub-issue.
  assert.equal(
    await failed(client, "set_issue_state", { id: parent.id, state: "closed" }),
    "the issue has open sub-issues; close them first",
  );

  const listed = await ok(client, "list_issues");
  assert.equal(listed.total, 2);
  // Both were created in the same second, so newest first doesn't order them.
  const byId = new Map(listed.issues.map((i) => [i.id, i]));
  const c = byId.get(child.id);
  const p = byId.get(parent.id);
  assert.ok(c && p, "both are listed");
  assert.equal(c.parent, parent.id);
  assert.equal(c.estimate_minutes, 90);
  assert.equal(c.workflow, "ready");
  assert.equal(c.effective_milestone_id, milestones[0].id, "inherited from the parent");
  assert.deepEqual(p.labels, ["release"]);
  assert.equal(p.milestone_id, milestones[0].id);
  assert.deepEqual(p.progress, { closed: 0, total: 1 });

  const commented = await ok(client, "comment_issue", {
    id: child.id.slice(0, 8),
    text: "Started.\n\nDraft in the wiki.",
    expect_version: child.version,
  });
  // The version moved on, so a write against the old one is refused.
  assert.equal(
    await failed(client, "comment_issue", {
      id: child.id,
      text: "Too late.",
      expect_version: child.version,
    }),
    "the issue changed since expect_version; read it again",
  );

  const edited = await ok(client, "edit_issue", {
    id: child.id,
    title: "Write the changelog for 1.0",
    add_labels: ["docs"],
    assignee: "ada@example.invalid",
    expect_version: commented.version,
  });
  assert.deepEqual(edited.changes.sort(), ["assignee", "labels", "title"]);

  const shown = await ok(client, "show_issue", { id: child.short_id });
  assert.equal(shown.issue.title, "Write the changelog for 1.0");
  assert.equal(shown.issue.version, edited.version);
  assert.equal(shown.description, "Every change since 0.1.");
  // Every commit is listed, the edit included, like `git issue show`;
  // `kind` tells them apart.
  assert.deepEqual(
    shown.comments.map((m) => [m.kind, m.subject, m.text]),
    [
      ["comment", "Started.", "Draft in the wiki."],
      ["update", "Update title, labels, assignee", ""],
    ],
  );

  const found = await ok(client, "search_issues", { text: "WIKI", ignore_case: true });
  assert.equal(found.total, 1);
  assert.equal(found.results[0].issue.id, child.id);
  assert.match(found.results[0].matches.join("\n"), /Draft in the wiki/);

  // The CLI reads what the server wrote, and the server what the CLI wrote.
  assert.match(cli(repo, "show", child.short_id), /Draft in the wiki/);
  cli(repo, "create", "From the command line");
  assert.equal((await ok(client, "list_issues")).total, 3);

  const closed = await ok(client, "set_issue_state", {
    id: child.id,
    state: "closed",
    reason: "completed",
    fixed_by: "1a2b3c4",
  });
  assert.equal(closed.state, "closed");
  await ok(client, "set_issue_state", { id: parent.id, state: "closed", release: "1.0" });

  const open = await ok(client, "list_issues");
  assert.deepEqual(
    open.issues.map((i) => i.title),
    ["From the command line"],
  );
  const all = await ok(client, "list_issues", { state: "all", label: "docs" });
  assert.equal(all.total, 1);
  assert.equal(all.issues[0].done, true);
  assert.deepEqual(
    (await ok(client, "list_milestones")).milestones[0].progress,
    { closed: 1, total: 1 },
  );
});

test("tool errors are results", async () => {
  assert.equal(await failed(client, "show_issue", { id: "ffffffff" }), "no issue 'ffffffff'");
  assert.equal(await failed(client, "search_issues", { text: "" }), "text must not be empty");
  assert.equal(
    await failed(client, "set_issue_state", { id: "ffffffff", state: "not a state" }),
    "state must be letters, digits, '-' and '_', not 'not a state'",
  );
  assert.match(
    await failed(client, "create_issue", { description: "no title" }),
    /^Invalid arguments for tool 'create_issue'/,
  );
});

test("an unknown tool is a protocol error", async () => {
  await assert.rejects(client.callTool({ name: "delete_everything", arguments: {} }), (err) => {
    assert.ok(err instanceof McpError);
    assert.equal(err.code, ErrorCode.InvalidParams);
    assert.match(err.message, /Unknown tool: delete_everything/);
    return true;
  });
});

test("repo names another repository", async () => {
  const created = await ok(client, "create_issue", { repo: other, title: "In the other one" });
  const there = await ok(client, "list_issues", { repo: other });
  assert.deepEqual(
    there.issues.map((i) => i.id),
    [created.id],
  );
  assert.match(cli(other, "ls"), /In the other one/);
  assert.equal(
    (await ok(client, "search_issues", { text: "In the other one" })).total,
    0,
    "not in the server's repository",
  );

  const missing = join(root, "missing");
  assert.equal(
    await failed(client, "list_issues", { repo: missing }),
    `not a git repository: ${missing}`,
  );
  assert.equal(
    await failed(client, "list_issues", { repo: "other" }),
    "repo must be an absolute path, not 'other'",
  );
});

test("outside a repository, the server starts and each call says so", async () => {
  const away = await connect(outside);
  try {
    assert.equal(
      await failed(away, "list_issues"),
      "not a git repository: .; give repo, the repository's absolute path",
    );
    assert.equal((await ok(away, "list_issues", { repo, state: "all" })).total, 3);
  } finally {
    await away.close();
  }
});
