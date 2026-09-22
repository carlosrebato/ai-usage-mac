#!/usr/bin/env node

// Optional Claude Code status-line adapter for AI Usage on macOS. Claude Code
// sends usage metadata on stdin; this script stores only the numeric limits in
// an atomically replaced local file. It never reads or writes credentials.

import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { homedir } from "node:os";

const outputPath =
  process.env.AI_USAGE_CLAUDE_STATUSLINE_PATH ??
  `${homedir()}/.claude/ai-usage-rate-limits.json`;

function percent(value) {
  const number = typeof value === "string" ? Number(value) : value;
  if (typeof number !== "number" || !Number.isFinite(number)) return null;
  return Math.max(0, Math.min(100, Math.round(number)));
}

function resetISO(value) {
  const number = typeof value === "string" ? Number(value) : value;
  return typeof number === "number" && Number.isFinite(number) && number > 0
    ? new Date(number * 1000).toISOString()
    : null;
}

async function readStdin() {
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  return input;
}

async function main() {
  const input = await readStdin();
  if (!input.trim()) return;

  const raw = JSON.parse(input);
  const fiveHour = raw?.rate_limits?.five_hour ?? {};
  const sevenDay = raw?.rate_limits?.seven_day ?? {};
  const sessionPercent = percent(fiveHour?.used_percentage);
  const weekPercent = percent(sevenDay?.used_percentage);

  if (sessionPercent == null && weekPercent == null) return;

  const payload = {
    sessionPercent,
    weekPercent,
    resetAt: resetISO(fiveHour?.resets_at),
    weekResetAt: resetISO(sevenDay?.resets_at),
    lastUpdated: new Date().toISOString(),
  };

  await mkdir(dirname(outputPath), { recursive: true });
  const temporaryPath = `${outputPath}.${process.pid}.tmp`;
  await writeFile(temporaryPath, `${JSON.stringify(payload)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  await rename(temporaryPath, outputPath);

  const summary = [];
  if (sessionPercent != null) summary.push(`5h ${sessionPercent}%`);
  if (weekPercent != null) summary.push(`7d ${weekPercent}%`);
  if (summary.length) console.log(`Claude ${summary.join(" | ")}`);
}

main().catch(() => {
  // A status-line helper must never interfere with Claude Code.
  process.exitCode = 0;
});
