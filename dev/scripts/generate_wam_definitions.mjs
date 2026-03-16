#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const projectRoot = path.resolve(import.meta.dirname, "..", "..");
const sourcePath = path.join(
  projectRoot,
  "dev",
  "reference",
  "Baileys-master",
  "src",
  "WAM",
  "constants.ts"
);
const outputPath = path.join(projectRoot, "priv", "wam", "definitions.json");

const source = fs.readFileSync(sourcePath, "utf8");
const sandbox = { globalThis: {} };

const executableSource = source
  .replace("export const WEB_EVENTS: Event[] = ", "globalThis.WEB_EVENTS = ")
  .replace("export const WEB_GLOBALS: Global[] = ", "globalThis.WEB_GLOBALS = ")
  .replace(/export const FLAG_BYTE =[\s\S]*$/, "");

vm.runInNewContext(executableSource, sandbox);

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(
  outputPath,
  JSON.stringify(
    {
      source: "dev/reference/Baileys-master/src/WAM/constants.ts",
      events: sandbox.globalThis.WEB_EVENTS,
      globals: sandbox.globalThis.WEB_GLOBALS,
    },
    null,
    2
  ) + "\n"
);
