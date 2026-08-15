// Public download page for the hongs-hermes-setup snapshot.
//
// The function answers every request with one static, self-contained HTML
// document. It reads no request body, no query string, no header, and no
// environment value; it touches no database, no Storage bucket, and no Auth
// session; it loads no external stylesheet, font, image, or analytics script;
// and it ships no client-side JavaScript. There is nothing here to configure
// and nothing here to keep secret.
//
// `supabase/config.toml` declares `verify_jwt = false` for this function, so
// the page is reachable without a JWT.
//
// The archive link always tracks the current `main` branch. That mutability is
// intentional and recorded in the design of record: the page offers the current
// setup, not a pinned release.

const REPOSITORY_URL = "https://github.com/sch00l8686-source/hongs-hermes-setup";
const ARCHIVE_URL =
  "https://github.com/sch00l8686-source/hongs-hermes-setup/archive/refs/heads/main.zip";

const PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>hongs-hermes-setup — download the global agent harness</title>
<meta name="description" content="Download the hongs-hermes-setup global agent harness: the Hermes constitution, the global Claude and Codex instruction files, and the managed skill set.">
<style>
:root { color-scheme: light dark; }
body {
  margin: 0;
  padding: 2rem 1.25rem;
  font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
  font-size: 1.0625rem;
  line-height: 1.6;
  color: #111418;
  background: #ffffff;
}
main { max-width: 42rem; margin: 0 auto; }
h1 { font-size: 1.75rem; line-height: 1.25; margin: 0 0 0.75rem; }
p { margin: 0 0 1rem; }
ul.links { list-style: none; margin: 1.5rem 0 0; padding: 0; }
ul.links li { margin: 0 0 0.75rem; }
a {
  display: inline-block;
  padding: 0.6rem 1rem;
  border: 2px solid #1b4b8f;
  border-radius: 0.4rem;
  color: #10305c;
  background: #eef3fb;
  text-decoration: underline;
  font-weight: 600;
}
a:hover { background: #dde7f7; }
a:focus-visible { outline: 3px solid #10305c; outline-offset: 3px; }
footer { margin-top: 2.5rem; font-size: 0.9375rem; }
@media (prefers-color-scheme: dark) {
  body { color: #f2f4f7; background: #10141a; }
  a { color: #eaf1fb; background: #1b3a5c; border-color: #7fb0f0; }
  a:hover { background: #244b7a; }
  a:focus-visible { outline-color: #eaf1fb; }
}
</style>
</head>
<body>
<main>
<h1>hongs-hermes-setup</h1>
<p>
The canonical, version-controlled source for a global agent harness: the Hermes
constitution, the global Claude and Codex instruction files, and the managed
skill set that carries the design, planning, and execution policy.
</p>
<p>
The snapshot is a single public commit. It contains policy and skill text,
provenance records, the installer, and its tests — no credentials, no runtime
state, and no machine-local paths.
</p>
<ul class="links">
<li><a href="${REPOSITORY_URL}">View the hongs-hermes-setup source repository on GitHub</a></li>
<li><a href="${ARCHIVE_URL}">Download the hongs-hermes-setup main branch as a ZIP archive</a></li>
</ul>
<footer>
<p>The ZIP archive always tracks the current state of the main branch.</p>
</footer>
</main>
</body>
</html>
`;

function handler() {
  // Built as an explicit `Headers` instance with canonically spelled names:
  // handed a lowercase plain object literal, the Supabase Edge Runtime served
  // this page as `text/plain` with `X-Content-Type-Options: nosniff`, so
  // browsers displayed the raw markup instead of rendering it.
  const headers = new Headers();
  headers.set("Content-Type", "text/html; charset=utf-8");
  headers.set("Cache-Control", "public, max-age=300");
  return new Response(PAGE, { status: 200, headers });
}

Deno.serve(handler);
