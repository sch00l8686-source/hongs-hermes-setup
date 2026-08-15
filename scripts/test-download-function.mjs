#!/usr/bin/env node
// Local proof that the public download site answers correctly.
//
//     node scripts/test-download-function.mjs
//
// The site is two artifacts. The HTML page is the repository-root `index.html`
// served by GitHub Pages from the `main` branch; it is read from disk and
// inspected as bytes and as markup. The Supabase Edge Function is no longer an
// HTML host: Supabase states that HTML content is not supported and that a GET
// returning `text/html` is rewritten to `text/plain`
// (https://supabase.com/docs/guides/functions/development-tips), so the
// function is now a bare redirect to the Pages URL. Its source is executed in a
// Node `vm` context whose only runtime global is a `Deno.serve` stub. The stub
// captures the registered handler instead of listening, so the real handler is
// invoked and its real `Response` is inspected. Nothing is deployed, no port is
// opened, and `fetch` is deliberately absent from the context: if either
// artifact ever grew a network call, this proof would fail rather than silently
// reach out.
//
// Exit codes: 0 every check passed, 1 a check failed, 2 the proof could not run.

import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const SCRIPTS_DIR = dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = dirname(SCRIPTS_DIR);
const PAGE_SOURCE = join(REPOSITORY_ROOT, "index.html");
const FUNCTION_SOURCE = join(REPOSITORY_ROOT, "supabase", "functions", "download", "index.ts");
const CONFIG_SOURCE = join(REPOSITORY_ROOT, "supabase", "config.toml");

// The links and the redirect target the design of record fixes exactly. They
// are spelled out here rather than read from the artifacts, so an artifact that
// rewrote one of them fails.
const REPOSITORY_URL = "https://github.com/sch00l8686-source/hongs-hermes-setup";
const ARCHIVE_URL =
  "https://github.com/sch00l8686-source/hongs-hermes-setup/archive/refs/heads/main.zip";
const PAGES_URL = "https://sch00l8686-source.github.io/hongs-hermes-setup/";
const EXPECTED_URLS = [ARCHIVE_URL, REPOSITORY_URL].sort();

const EM_DASH = "—";
const REPLACEMENT_CHARACTER = "�";

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

function textContent(html) {
  return html
    .replace(/<style\b[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]*>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

let pageBytes;
let page;
let source;
let config;
try {
  pageBytes = await readFile(PAGE_SOURCE);
  source = await readFile(FUNCTION_SOURCE, "utf8");
  config = await readFile(CONFIG_SOURCE, "utf8");
} catch (error) {
  process.stderr.write(`test-download-function: cannot read the site source: ${error.message}\n`);
  process.exit(2);
}

// --- the page is well-formed UTF-8 ----------------------------------------
let decodeError = "";
try {
  page = new TextDecoder("utf-8", { fatal: true }).decode(pageBytes);
} catch (error) {
  decodeError = error.message;
  page = pageBytes.toString("utf8");
}
check("page-is-valid-utf8", decodeError === "", decodeError || "index.html decodes as strict UTF-8");
check(
  "page-em-dash-not-mojibake",
  page.includes(EM_DASH) && !page.includes(REPLACEMENT_CHARACTER),
  `${(page.match(/—/g) || []).length} em dash(es) U+2014, ` +
    `${(page.match(/�/g) || []).length} replacement character(s) U+FFFD, expected 0`,
);

// --- accessible, static markup --------------------------------------------
const markers = [
  ["doctype", /^<!doctype html>/i.test(page.trim())],
  ["html-lang", /<html lang="[a-z]{2}"/i.test(page)],
  ["charset", /<meta charset="utf-8">/i.test(page)],
  ["viewport", /<meta name="viewport"/i.test(page)],
  ["title", /<title>[^<]{5,}<\/title>/i.test(page)],
  ["single-h1", (page.match(/<h1\b/gi) || []).length === 1],
  ["main-landmark", /<main\b/i.test(page) && /<\/main>/i.test(page)],
];
const missingMarkers = markers.filter(([, present]) => !present).map(([name]) => name);
check(
  "accessible-markers",
  missingMarkers.length === 0,
  missingMarkers.length === 0
    ? `${markers.length} marker(s) present`
    : `missing marker(s): ${missingMarkers.join(", ")}`,
);

const prose = textContent(page);
check(
  "descriptive-page-text",
  prose.length >= 200 && /hongs-hermes-setup/.test(prose),
  `${prose.length} character(s) of visible text naming the project, expected at least 200`,
);

const links = anchors(page);
const undescriptive = links.filter(
  (link) => link.text.length < 10 || /^(click here|here|link|download)$/i.test(link.text),
);
check(
  "descriptive-link-text",
  links.length > 0 && undescriptive.length === 0,
  `${undescriptive.length} link(s) without descriptive text, expected 0`,
);

const clientCode = [
  ["script-element", /<script\b/i.test(page)],
  ["inline-handler", /\son[a-z]+\s*=/i.test(page)],
  ["external-stylesheet", /<link\b[^>]*rel="stylesheet"/i.test(page)],
  ["remote-image", /<img\b/i.test(page)],
].filter(([, present]) => present).map(([name]) => name);
check(
  "no-client-code-or-external-asset",
  clientCode.length === 0,
  clientCode.length === 0 ? "none present" : `present: ${clientCode.join(", ")}`,
);

// --- the two exact links --------------------------------------------------
// The page is static HTML now, so every href must be a literal: an unresolved
// template placeholder would ship to the browser verbatim.
check(
  "no-unresolved-interpolation",
  !/\$\{/.test(page),
  "no `${...}` template interpolation remains in index.html",
);

const urls = externalUrls(page);
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

// --- the Edge Function is a bare redirect ----------------------------------
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

check("status-302", response.status === 302, `status ${response.status}, expected 302`);
check(
  "location-is-the-pages-url",
  response.headers.get("location") === PAGES_URL,
  `location "${response.headers.get("location")}", expected "${PAGES_URL}"`,
);
check(
  "redirect-carries-no-html-body",
  body.trim() === "" && !/<[a-z!]/i.test(body),
  `${body.length} byte(s) of body, expected an empty non-HTML body`,
);

const cacheControl = (response.headers.get("cache-control") || "").toLowerCase();
check(
  "redirect-is-not-cached",
  cacheControl.includes("no-store"),
  `cache-control "${cacheControl}", expected a no-store directive`,
);

// --- no dead HTML left behind in the function ------------------------------
const deadHtml = [
  ["doctype", /<!doctype/i.test(source)],
  ["html-element", /<html\b/i.test(source)],
  ["style-element", /<style\b/i.test(source)],
  ["anchor-element", /<a\s[^>]*href=/i.test(source)],
].filter(([, present]) => present).map(([name]) => name);
check(
  "function-retains-no-dead-html",
  deadHtml.length === 0,
  deadHtml.length === 0 ? "none present" : `present: ${deadHtml.join(", ")}`,
);

// --- the JWT-less declaration ---------------------------------------------
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
