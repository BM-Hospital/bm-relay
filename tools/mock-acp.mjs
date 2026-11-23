#!/usr/bin/env node
// A pretend ACP agent, for trying the app without an account: it answers
// every prompt with a thought, a few tool calls (one asking for approval),
// an edit, and a Markdown answer streamed in chunks. A prompt saying
// "subagent" adds a Claude Code style subagent; "spawn", one run as a
// session of its own; "question", a question for the user.
//
//   Settings → Agents → Add:  node tools/mock-acp.mjs
import { createInterface } from 'node:readline';
import { writeFileSync, readFileSync, existsSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const send = (msg) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...msg }) + '\n');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sessions = new Map();
const waiting = new Map();
let nextId = 1000;
let cancelled = false;

const options = (s) => ({
  configOptions: [
    { id: 'model', name: 'Model', category: 'model', type: 'select', currentValue: s.model,
      options: [{ value: 'mock-fast', name: 'Mock Fast' }, { value: 'mock-smart', name: 'Mock Smart' }, { value: 'mock-long', name: 'Nemotron 3.5 Lightning (free)' }] },
    { id: 'mode', name: 'Mode', category: 'mode', type: 'select', currentValue: s.mode,
      options: [{ value: 'ask', name: 'Ask' }, { value: 'auto', name: 'Auto' }, { value: 'full-access', name: 'Full access' }] },
    { id: 'effort', name: 'Thinking', category: 'thought_level', type: 'select', currentValue: s.effort,
      options: [{ value: 'low', name: 'Low' }, { value: 'medium', name: 'Medium' }, { value: 'high', name: 'High' }] },
  ],
});

const update = (sessionId, u) => send({ method: 'session/update', params: { sessionId, update: u } });
const ask = (method, params) => {
  const id = nextId++;
  send({ id, method, params });
  return new Promise((r) => waiting.set(id, r));
};

async function stream(sessionId, kind, text) {
  for (let i = 0; i < text.length; i += 12) {
    if (cancelled) return;
    update(sessionId, { sessionUpdate: kind, content: { type: 'text', text: text.slice(i, i + 12) } });
    await sleep(15);
  }
}

async function prompt(id, { sessionId, prompt }) {
  const s = sessions.get(sessionId);
  cancelled = false;
  const said = prompt.filter((b) => b.type === 'text').map((b) => b.text).join('\n');
  if (!s.title) {
    s.title = said.split('\n')[0].slice(0, 40) || 'Images';
    update(sessionId, { sessionUpdate: 'session_info_update', title: s.title });
  }
  await stream(sessionId, 'agent_thought_chunk', 'Let me look at the folder before changing anything.');
  update(sessionId, { sessionUpdate: 'plan', entries: [
    { content: 'Read the project', status: 'completed', priority: 'high' },
    { content: 'Write the notes file', status: 'in_progress', priority: 'high' },
    { content: 'Say what changed', status: 'pending', priority: 'medium' },
  ] });
  if (/long command/i.test(said)) {
    // A command far wider than the transcript.
    const call = `long-${Date.now()}`;
    const command = "gh api users/someone --jq '{name,login,bio,company,location,blog,public_repos,followers,following,created_at,updated_at,hireable,twitter_username,email}' && gh repo list someone --limit 100 --json name,description,stargazerCount,updatedAt";
    update(sessionId, { sessionUpdate: 'tool_call', toolCallId: call, title: command, kind: 'execute', status: 'in_progress', rawInput: { command } });
    await sleep(2500);
    update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: call, status: 'completed' });
  }
  if (/slow/i.test(said)) {
    // A long call that ignores the cancel, as a stuck agent would.
    const call = `slow-${Date.now()}`;
    update(sessionId, { sessionUpdate: 'tool_call', toolCallId: call, title: 'sleep 60', kind: 'execute', status: 'in_progress', rawInput: { command: 'sleep 60' } });
    await sleep(60000);
  }
  for (const [n, path] of ['README.md', 'build.zig'].entries()) {
    if (cancelled) return send({ id, result: { stopReason: 'cancelled' } });
    const call = `read-${n}-${Date.now()}`;
    update(sessionId, { sessionUpdate: 'tool_call', toolCallId: call, title: `Read ${path}`, kind: 'read', status: 'in_progress', rawInput: { file_path: join(s.cwd, path) } });
    await sleep(120);
    update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: call, status: 'completed' });
  }
  const run = `run-${Date.now()}`;
  update(sessionId, { sessionUpdate: 'tool_call', toolCallId: run, title: 'git status', kind: 'execute', status: 'pending', rawInput: { command: 'git status --short' } });
  let denied = false;
  if (s.mode === 'ask') {
    const answer = await ask('session/request_permission', {
      sessionId,
      toolCall: { toolCallId: run, title: 'git status', kind: 'execute', status: 'pending', rawInput: { command: 'git status --short' } },
      options: [
        { optionId: 'once', name: 'Allow once', kind: 'allow_once' },
        { optionId: 'always', name: 'Always allow', kind: 'allow_always' },
        { optionId: 'no', name: 'Reject', kind: 'reject_once' },
      ],
    });
    const chosen = answer?.outcome?.optionId;
    if (!chosen || chosen === 'no') {
      denied = true;
      update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: run, status: 'failed', content: [{ type: 'content', content: { type: 'text', text: 'The user denied this command.' } }] });
      if (!chosen) return send({ id, result: { stopReason: 'cancelled' } });
    }
  }
  if (!denied) {
    update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: run, status: 'in_progress' });
    await sleep(200);
    update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: run, status: 'completed', content: [{ type: 'content', content: { type: 'text', text: ' M README.md\n?? notes.md\n' } }] });
  }
  if (cancelled) return send({ id, result: { stopReason: 'cancelled' } });

  const file = join(s.cwd, 'MOCK_NOTES.md');
  const old = existsSync(file) ? readFileSync(file, 'utf8') : '';
  const next = old + `- ${said.split('\n')[0]}\n`;
  const edit = `edit-${Date.now()}`;
  update(sessionId, { sessionUpdate: 'tool_call', toolCallId: edit, title: 'Edit MOCK_NOTES.md', kind: 'edit', status: 'in_progress',
    rawInput: { file_path: file, old_string: old, new_string: next },
    content: [{ type: 'diff', path: file, oldText: old, newText: next }] });
  writeFileSync(file, next);
  await sleep(100);
  update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: edit, status: 'completed' });
  update(sessionId, { sessionUpdate: 'usage_update', used: 12000 + said.length * 40, size: 200000 });
  update(sessionId, { sessionUpdate: 'plan', entries: [
    { content: 'Read the project', status: 'completed', priority: 'high' },
    { content: 'Write the notes file', status: 'completed', priority: 'high' },
    { content: 'Say what changed', status: 'completed', priority: 'medium' },
  ] });
  if (/subagent/i.test(said)) await subagent(sessionId, s);
  if (/spawn/i.test(said) && clientSubagents) await spawned(sessionId, s);
  await stream(sessionId, 'agent_message_chunk',
    `Done. I added your note to **MOCK_NOTES.md**:\n\n\`\`\`md\n- ${said.split('\n')[0]}\n\`\`\`\n\n| Step | Result |\n|---|---|\n| Read | 2 files |\n| Ran | \`git status\` |\n| Edited | 1 file |\n`);
  if (/picture/i.test(said)) {
    // A picture by its path, one sent as an image block, and some code.
    const logo = fileURLToPath(new URL('../src/design/logo.png', import.meta.url));
    await stream(sessionId, 'agent_message_chunk', `\n\nThe logo, from its file:\n\n![logo](${logo.replaceAll('\\', '/')})\n\nAnd as an image the agent sent:\n\n`);
    update(sessionId, { sessionUpdate: 'agent_message_chunk', content: { type: 'image', mimeType: 'image/png', data: readFileSync(logo).toString('base64') } });
    await stream(sessionId, 'agent_message_chunk', '\n\n```zig\nconst std = @import("std");\n\npub fn main() void {\n    std.debug.print("hello\\n", .{});\n}\n```\n');
  }
  if (/question/i.test(said)) {
    const q = `ask-${Date.now()}`;
    update(sessionId, { sessionUpdate: 'tool_call', toolCallId: q, title: 'Ask', kind: 'other', name: 'ask_user_question', status: 'completed',
      rawInput: { questions: [{ question: 'Which colour should the notes use?', options: [{ label: 'Red' }, { label: 'Blue' }] }] } });
  }
  send({ id, result: { stopReason: cancelled ? 'cancelled' : 'end_turn' } });
}

// A subagent as Claude Code's adapter reports one: its Task call, then
// its own steps and words stamped with that call's id.
async function subagent(sessionId, s) {
  const task = `task-${Date.now()}`;
  const meta = { claudeCode: { parentToolUseId: task } };
  update(sessionId, { sessionUpdate: 'tool_call', toolCallId: task, title: 'Find the sidebar code', kind: 'think', status: 'in_progress',
    _meta: { claudeCode: { toolName: 'Agent' } },
    rawInput: { subagent_type: 'Explore', description: 'Find the sidebar code', prompt: 'Find where the sidebar is drawn and report the file.' } });
  await sleep(100);
  update(sessionId, { sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: 'Searching for the sidebar.' }, _meta: meta });
  for (const [n, path] of ['src/views/shell.zig', 'src/views/root.zig', 'src/design/tokens.zig'].entries()) {
    const call = `sub-${n}-${Date.now()}`;
    update(sessionId, { sessionUpdate: 'tool_call', toolCallId: call, title: `Read ${path}`, kind: 'read', status: 'in_progress', rawInput: { file_path: join(s.cwd, path) }, _meta: meta });
    await sleep(150);
    update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: call, status: 'completed', _meta: meta });
  }
  const grep = `sub-grep-${Date.now()}`;
  update(sessionId, { sessionUpdate: 'tool_call', toolCallId: grep, title: 'grep sidebar', kind: 'search', status: 'completed', rawInput: { pattern: 'fn sidebar' }, _meta: meta });
  update(sessionId, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'The sidebar is drawn in shell.zig.' }, _meta: meta });
  await sleep(100);
  update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: task, status: 'completed',
    content: [{ type: 'content', content: { type: 'text', text: 'The sidebar is drawn by `sidebar` in src/views/shell.zig.' } }] });
}

// A subagent run as a session of its own (ACP's subagents, as Codex's
// adapter runs them when the client says it shows them).
async function spawned(sessionId, s) {
  const child = `child-${Date.now()}`;
  update(sessionId, { sessionUpdate: 'subagent_update', sessionId: child, title: 'Reviewer', description: 'Review the notes file', state: { state: 'running' } });
  update(sessionId, { sessionUpdate: 'session_message', messageId: `${child}:prompt`, senderSessionId: sessionId, recipientSessionId: child,
    content: [{ type: 'text', text: 'Check MOCK_NOTES.md for typos.' }] });
  const call = `child-read-${Date.now()}`;
  update(child, { sessionUpdate: 'tool_call', toolCallId: call, title: 'Read MOCK_NOTES.md', kind: 'read', status: 'in_progress', rawInput: { file_path: join(s.cwd, 'MOCK_NOTES.md') } });
  await sleep(150);
  update(child, { sessionUpdate: 'tool_call_update', toolCallId: call, status: 'completed' });
  update(child, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'No typos found.' } });
  update(child, { sessionUpdate: 'session_info_update', title: 'Not the parent session' });
  update(sessionId, { sessionUpdate: 'subagent_update', sessionId: child, state: { state: 'idle' } });
  update(sessionId, { sessionUpdate: 'session_message', messageId: `${child}:reply`, senderSessionId: child, recipientSessionId: sessionId,
    content: [{ type: 'text', text: 'The notes read fine: no typos.' }] });
}

let clientSubagents = false;
const deleted = new Set();

const rl = createInterface({ input: process.stdin });
rl.on('line', async (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);
  if (msg.id !== undefined && !msg.method) {
    waiting.get(msg.id)?.(msg.result);
    waiting.delete(msg.id);
    return;
  }
  const { id, method, params } = msg;
  if (process.env.MOCK_LOG) appendFileSync(process.env.MOCK_LOG, `${method}\n`);
  switch (method) {
    case 'initialize':
      clientSubagents = !!params?.clientCapabilities?.subagents;
      return send({ id, result: { protocolVersion: 1, agentInfo: { name: 'mock', title: 'Mock agent', version: '0.0.1' },
        agentCapabilities: { loadSession: true, sessionCapabilities: { list: {}, delete: {} }, promptCapabilities: { image: true }, mcpCapabilities: { http: true } } } });
    case 'session/new': {
      const sessionId = `mock-${Date.now()}`;
      const s = { cwd: params.cwd, model: 'mock-fast', mode: 'ask', effort: 'medium', title: '' };
      sessions.set(sessionId, s);
      update(sessionId, { sessionUpdate: 'available_commands_update', availableCommands: [{ name: 'review', description: 'Review the changes' }] });
      return send({ id, result: { sessionId, ...options(s) } });
    }
    case 'session/list': {
      const now = Date.now();
      if (!params.cwd) {
        // Every folder's (Settings → Storage), two pages.
        const day = 86400e3;
        const all = [
          ['old-web-1', 'D:\\work\\web', 100], ['old-web-2', 'D:\\work\\web', 40], ['old-web-3', 'D:\\work\\web', 2],
          ['old-api-1', 'D:\\work\\api', 60], ['old-api-2', 'D:\\work\\api', 1],
        ].map(([sessionId, cwd, age]) => ({ sessionId, cwd, title: sessionId, updatedAt: new Date(now - age * day).toISOString() }))
          .filter((x) => !deleted.has(x.sessionId));
        const page = params.cursor === 'p2' ? all.slice(3) : all.slice(0, 3);
        return send({ id, result: { sessions: page, ...(params.cursor === 'p2' ? {} : { nextCursor: 'p2' }) } });
      }
      // Sessions of this folder as a CLI would have left them.
      const sessions = [
        { sessionId: 'cli-auth-refactor', cwd: params.cwd, title: 'Refactor the auth middleware (from the CLI)', updatedAt: new Date(now - 3 * 3600e3).toISOString() },
        { sessionId: 'cli-flaky-test', cwd: params.cwd, title: 'Fix the flaky date test (from the CLI)', updatedAt: new Date(now - 2 * 86400e3).toISOString() },
        { sessionId: 'a0', cwd: params.cwd, title: 'Fix the login form', updatedAt: new Date(now).toISOString() },
      ];
      return send({ id, result: { sessions: sessions.filter((x) => !deleted.has(x.sessionId)) } });
    }
    case 'session/delete':
      deleted.add(params.sessionId);
      return send({ id, result: {} });
    case 'session/load': {
      const s = { cwd: params.cwd, model: 'mock-fast', mode: 'ask', effort: 'medium', title: 'Loaded' };
      sessions.set(params.sessionId, s);
      update(params.sessionId, { sessionUpdate: 'user_message_chunk', content: { type: 'text', text: 'An earlier prompt' } });
      update(params.sessionId, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'An earlier answer.' } });
      return send({ id, result: options(s) });
    }
    case 'session/set_config_option': {
      const s = sessions.get(params.sessionId);
      if (params.configId === 'model') s.model = params.value;
      if (params.configId === 'mode') s.mode = params.value;
      if (params.configId === 'effort') s.effort = params.value;
      return send({ id, result: options(s) });
    }
    case 'session/prompt':
      return prompt(id, params);
    case 'session/cancel':
      cancelled = true;
      for (const [rid, r] of waiting) { r({ outcome: { outcome: 'cancelled' } }); waiting.delete(rid); }
      return;
    default:
      if (id !== undefined) send({ id, error: { code: -32601, message: `Method not found: ${method}` } });
  }
});
