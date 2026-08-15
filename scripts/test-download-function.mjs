#!/usr/bin/env node
// Local proof that the public download page answers correctly.
//
//     node scripts/test-download-function.mjs
//
// The Edge Function source is executed in a Node `vm` context whose only
// runtime global is a `Deno.serve` stub. The stub captures the registered
// handler instead of listening, so the real handler is invoked and its real
// `Response` is inspected. Nothing is deployed, no port is opened, and `fetch`
// is deliberately absent from the context: if the page ever grew a network
// call, this proof would fail rather than silently reach out.
//
// Exit codes: 0 every check passed, 1 a check failed, 2 the proof could not run.

import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const SCRIPTS_DIR = dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = dirname(SCRIPTS_DIR);
const FUNCTION_SOURCE = join(REPOSITORY_ROOT, "supabase", "functions", "download", "index.ts");
const CONFIG_SOURCE = join(REPOSITORY_ROOT, "supabase", "config.toml");

// The two links the design of record fixes exactly. They are spelled out here
// rather than read from the page, so a page that rewrote a link fails.
const REPOSITORY_URL = "https://github.com/sch00l8686-source/hongs-hermes-setup";
const ARCHIVE_URL =
  "https://github.com/sch00l8686-source/hongs-hermes-setup/archive/refs/heads/main.zip";
const EXPECTED_URLS = [ARCHIVE_URL, REPOSITORY_URL].sort();

const results = [];

function check(name, passed, detail) {
  results.push({ name, passed, detail });
}

function loadHandler(source) {
  let captured = null;
  const context = vm.createContext({
    Deno: {
      serve(first, second) {
        captured = typeof first === "function" ? first : second;
        return { finished: Promise.resolve(), shutdown() {} };
      },
    },
    Response,
    Request,
    Headers,
    URL,
    TextEncoder,
    TextDecoder,
    console,
  });
  vm.runInContext(source, context, { filename: FUNCTION_SOURCE });
  if (typeof captured !== "function") {
    throw new Error("the function source registered no Deno.serve handler");
  }
  return captured;
}

function anchors(html) {
  return [...html.matchAll(/<a\b[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/g)].map((match) => ({
    href: match[1],
    text: match[2].replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim(),
  }));
}

function externalUrls(html) {
  return [...new Set([...html.matchAll(/https?:\/\/[^\s"'<>]+/g)].map((match) => match[0]))].sort();
}

let source;
let config;
try {
  source = await readFile(FUNCTION_SOURCE, "utf8");
  config = await readFile(CONFIG_SOURCE, "utf8");
} catch (error) {
  process.stderr.write(`test-download-function: cannot read the site source: ${error.message}\n`);
  process.exit(2);
}

let response;
let body;
try {
  const handler = loadHandler(source);
  response = await handler(new Request("https://download.invalid/download"));
  body = await response.text();
} catch (error) {
  process.stderr.write(`test-download-function: the handler did not answer: ${error.message}\n`);
  process.exit(2);
}

// --- response ------------------------------------------------------------
check("status-200", response.status === 200, `status ${response.status}, expected 200`);

const contentType = (response.headers.get("content-type") || "").toLowerCase();
check(
  "content-type-html",
  contentType.startsWith("text/html") && contentType.includes("charset=utf-8"),
  `content-type "${contentType}", expected text/html with charset=utf-8`,
);

// --- accessible, static markup -------------------------------------------
const markers = [
  ["doctype", /^<!doctype html>/i.test(body.trim())],
  ["html-lang", /<html lang="[a-z]{2}"/i.test(body)],
  ["charset", /<meta charset="utf-8">/i.test(body)],
  ["viewport", /<meta name="viewport"/i.test(body)],
  ["title", /<title>[^<]{5,}<\/title>/i.test(body)],
  ["single-h1", (body.match(/<h1\b/gi) || []).length === 1],
  ["main-landmark", /<main\b/i.test(body) && /<\/main>/i.test(body)],
];
const missingMarkers = markers.filter(([, present]) => !present).map(([name]) => name);
check(
  "accessible-markers",
  missingMarkers.length === 0,
  missingMarkers.length === 0
    ? `${markers.length} marker(s) present`
    : `missing marker(s): ${missingMarkers.join(", ")}`,
);

const links = anchors(body);
const undescriptive = links.filter(
  (link) => link.text.length < 10 || /^(click here|here|link|download)$/i.test(link.text),
);
check(
  "descriptive-link-text",
  undescriptive.length === 0,
  `${undescriptive.length} link(s) without descriptive text, expected 0`,
);

const clientCode = [
  ["script-element", /<script\b/i.test(body)],
  ["inline-handler", /\son[a-z]+\s*=/i.test(body)],
  ["external-stylesheet", /<link\b[^>]*rel="stylesheet"/i.test(body)],
  ["remote-image", /<img\b/i.test(body)],
].filter(([, present]) => present).map(([name]) => name);
check(
  "no-client-code-or-external-asset",
  clientCode.length === 0,
  clientCode.length === 0 ? "none present" : `present: ${clientCode.join(", ")}`,
);

// --- the two exact links --------------------------------------------------
const urls = externalUrls(body);
check(
  "exactly-two-links",
  urls.length === 2 && urls[0] === EXPECTED_URLS[0] && urls[1] === EXPECTED_URLS[1],
  `${urls.length} external URL(s), expected exactly the 2 approved ones`,
);
check(
  "repository-link",
  links.some((link) => link.href === REPOSITORY_URL),
  "the exact repository link is present as an anchor href",
);
check(
  "archive-link",
  links.some((link) => link.href === ARCHIVE_URL),
  "the exact main.zip archive link is present as an anchor href",
);

// --- the JWT-less declaration --------------------------------------------
check(
  "jwt-less-function",
  /\[functions\.download\][\s\S]*?verify_jwt\s*=\s*false/.test(config),
  "supabase/config.toml declares [functions.download] with verify_jwt = false",
);

const failed = results.filter((result) => !result.passed);
const width = Math.max(...results.map((result) => result.name.length));
for (const result of results) {
  process.stdout.write(
    `${result.passed ? "PASS" : "FAIL"} ${result.name.padEnd(width)}  ${result.detail}\n`,
  );
}
process.stdout.write(
  `test-download-function: ${failed.length === 0 ? "PASS" : "FAIL"} (${failed.length} check(s) failed)\n`,
);
process.exit(failed.length === 0 ? 0 : 1);
