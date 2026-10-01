#!/usr/bin/env node
// Build-time patch for @ahpd/agent-acp 0.8.0.
//
// The stock plugin's `probe` always answers "no models", so a client such as the
// VS Code Agents window shows "No models available" until a session is open.
// Vibe only advertises its models after `session/new`, so we let the operator
// say which models to list up front via LUMI_PROBE_MODELS (JSON array of
// {"id","name"}), read at run time.
//
// Fails the build loudly if the plugin changed and the anchor is gone.
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

const root = process.argv[2];
if (!root) { console.error('usage: patch-ahpd-plugin.mjs <ahpd config dir>'); process.exit(2); }

const files = execFileSync('find', [root, '-path', '*@ahpd/agent-acp/dist/agent.js'], { encoding: 'utf8' })
  .split('\n').filter(Boolean);
if (files.length !== 1) { console.error(`expected exactly one agent.js under ${root}, found ${files.length}`); process.exit(1); }

const OLD = "probe: async () => ({ models: [], customizations: [], commands: [] }),";
const NEW = "probe: async () => ({ models: (() => { try { return JSON.parse(process.env.LUMI_PROBE_MODELS || '[]'); } catch { return []; } })(), customizations: [], commands: [] }), // patched: LumiEther";

let src = fs.readFileSync(files[0], 'utf8');
if (src.includes('// patched: LumiEther')) { console.log('plugin already patched'); process.exit(0); }
if (src.split(OLD).length !== 2) { console.error('probe anchor not found exactly once; plugin version changed?'); process.exit(1); }
fs.writeFileSync(files[0], src.replace(OLD, NEW));
console.log(`patched ${files[0]}`);
