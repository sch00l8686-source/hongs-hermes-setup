// Public download endpoint for the hongs-hermes-setup snapshot.
//
// This function serves no page. Supabase states that HTML content is not
// supported on Edge Functions and that a GET request returning `text/html` is
// rewritten to `text/plain`:
// https://supabase.com/docs/guides/functions/development-tips
//
// The page therefore lives on GitHub Pages, served from the `main` branch of
// the public repository, and this function is a bare 302 redirect to that one
// fixed URL. It reads no request body, no query string, no header, and no
// environment value, and emits no body at all.
//
// `supabase/config.toml` declares `verify_jwt = false` for this function, so
// the redirect is a public endpoint reachable without a JWT.

const PAGE_URL = "https://sch00l8686-source.github.io/hongs-hermes-setup/";

function handler() {
  // `no-store` keeps the redirect target changeable: a cached permanent
  // redirect would be pinned in browsers with no way to correct it.
  const headers = new Headers();
  headers.set("Location", PAGE_URL);
  headers.set("Cache-Control", "no-store");
  return new Response(null, { status: 302, headers });
}

Deno.serve(handler);
