// A client of its own `git-issue mcp`, recording resource updates, for the
// live-update tests (live_mcp.test.mjs, worktrees_mcp.test.mjs).

import assert from "node:assert/strict";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { ResourceUpdatedNotificationSchema } from "@modelcontextprotocol/sdk/types.js";

export const issuesUri = "git-issue://issues";
export const milestonesUri = "git-issue://milestones";
export const issueUri = (id) => `git-issue://issues/${id}`;

/** How long a notification may take: the watcher waits for quiet first. */
export const timeoutMs = 5000;
/** How long to wait to be sure one doesn't come. */
export const quietMs = 600;

/** Starts `gitIssue mcp` in `cwd` and connects to it as `name`. */
export async function connect({ gitIssue, cwd, env, name }) {
  const transport = new StdioClientTransport({
    command: gitIssue,
    args: ["mcp"],
    cwd,
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
    /** Waits for quiet, and forgets every update. */
    async drain() {
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
    /** The error text of a tool call that must fail. */
    async callFails(tool, args = {}) {
      const result = await client.callTool({ name: tool, arguments: args });
      assert.equal(result.isError, true, `${tool} succeeded: ${JSON.stringify(result.structuredContent)}`);
      return result.content?.[0]?.text ?? "";
    },
  };
}
