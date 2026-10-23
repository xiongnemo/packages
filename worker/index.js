// Serves the `site` branch of xiongnemo/packages, applying its _redirects the
// way Pages does. The branch is resolved to a commit at most once a minute and
// every file is then read at that commit, so one response's InRelease and
// Packages always come from the same build -- a mix of two builds would fail
// apt's hash check. Files at a commit never change, so they are cached hard.

const REPO = "xiongnemo/packages";
const BRANCH = "site";
const REF_TTL = 60;

const TYPES = {
  html: "text/html; charset=utf-8",
  json: "application/json",
  gz: "application/gzip",
  xml: "application/xml",
  asc: "text/plain; charset=utf-8",
  gpg: "application/pgp-keys",
  pub: "text/plain; charset=utf-8",
  repo: "text/plain; charset=utf-8",
};

// The branch is looked up at most once a minute. If GitHub does not answer --
// it returned errors for a few seconds on 2026-10-22, and every request got a
// 503 -- the last commit seen is served instead: a site a minute stale is
// still a consistent, signed site, and an error is not.
const FRESH_REF = new Request(`https://ref.internal/${REPO}/${BRANCH}`);
const LAST_REF = new Request(`https://ref.internal/${REPO}/${BRANCH}/last-known`);
const LAST_TTL = 7 * 24 * 3600;

async function lookupCommit() {
  let failure;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const res = await fetch(`https://github.com/${REPO}.git/info/refs?service=git-upload-pack`, {
        headers: { "User-Agent": "xiongnemo-packages-worker" },
      });
      if (!res.ok) throw new Error(`ref lookup: ${res.status}`);
      const match = (await res.text()).match(new RegExp(`([0-9a-f]{40}) refs/heads/${BRANCH}\\b`));
      if (!match) throw new Error(`no ${BRANCH} branch`);
      return match[1];
    } catch (err) {
      failure = err;
    }
  }
  throw failure;
}

async function siteCommit(ctx) {
  const cache = caches.default;
  const fresh = await cache.match(FRESH_REF);
  if (fresh) return fresh.text();
  try {
    const commit = await lookupCommit();
    const keep = (ttl) => new Response(commit, { headers: { "Cache-Control": `max-age=${ttl}` } });
    ctx.waitUntil(Promise.all([cache.put(FRESH_REF, keep(REF_TTL)), cache.put(LAST_REF, keep(LAST_TTL))]));
    return commit;
  } catch (err) {
    const last = await cache.match(LAST_REF);
    if (last) return last.text();
    throw err;
  }
}

function fileAt(commit, path) {
  return fetch(`https://raw.githubusercontent.com/${REPO}/${commit}/${path}`, {
    cf: { cacheEverything: true, cacheTtl: 86400 },
  });
}

const rulesByCommit = new Map();

async function rules(commit) {
  if (rulesByCommit.has(commit)) return rulesByCommit.get(commit);
  const res = await fileAt(commit, "_redirects");
  const statics = new Map();
  const dynamics = [];
  for (let line of (res.ok ? await res.text() : "").split("\n")) {
    line = line.trim();
    if (!line || line.startsWith("#")) continue;
    const [source, destination, code] = line.split(/\s+/);
    const status = Number(code || 302);
    if (source.includes(":") || source.includes("*")) {
      const names = [];
      const pattern = source
        .replace(/[.+?^${}()|[\]\\]/g, "\\$&")
        .replace(/\*/g, () => (names.push("splat"), "(.*)"))
        .replace(/:(\w+)/g, (_, name) => (names.push(name), "([^/]+)"));
      dynamics.push({ regex: new RegExp(`^${pattern}$`), names, destination, status });
    } else {
      statics.set(source, { destination, status });
    }
  }
  const parsed = { statics, dynamics };
  rulesByCommit.clear();
  rulesByCommit.set(commit, parsed);
  return parsed;
}

function resolve({ statics, dynamics }, path) {
  if (statics.has(path)) return statics.get(path);
  for (const rule of dynamics) {
    const match = rule.regex.exec(path);
    if (!match) continue;
    let destination = rule.destination;
    rule.names.forEach((name, i) => (destination = destination.replaceAll(`:${name}`, match[i + 1])));
    return { destination, status: rule.status };
  }
  return null;
}

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    const url = new URL(request.url);
    const path = decodeURIComponent(url.pathname);
    let commit;
    try {
      commit = await siteCommit(ctx);
    } catch (err) {
      return new Response(`site unavailable: ${err.message}\n`, { status: 503, headers: { "Retry-After": "60" } });
    }
    const redirect = resolve(await rules(commit), path);
    if (redirect) {
      return new Response(null, { status: redirect.status, headers: { Location: redirect.destination, "X-Site-Commit": commit } });
    }
    const file = path.endsWith("/") ? `${path}index.html` : path;
    if (file.includes("..") || file === "/_redirects") return new Response("not found\n", { status: 404 });
    const upstream = await fileAt(commit, file.slice(1));
    if (upstream.status === 404) return new Response("not found\n", { status: 404, headers: { "X-Site-Commit": commit } });
    // Anything else is GitHub failing, not the file missing: a 404 here would
    // tell apt the index has no such file, where a 502 tells it to try again.
    if (!upstream.ok) {
      return new Response(`upstream ${upstream.status}\n`, { status: 502, headers: { "Retry-After": "30", "X-Site-Commit": commit } });
    }
    const ext = file.includes(".") ? file.split(".").pop() : "";
    const headers = new Headers({
      "Content-Type": TYPES[ext] || "text/plain; charset=utf-8",
      "Cache-Control": `public, max-age=${REF_TTL}`,
      "X-Site-Commit": commit,
    });
    // No Content-Length from upstream: fetch may have decoded a compressed
    // transfer, and the length would then describe bytes this body is not.
    return new Response(request.method === "HEAD" ? null : upstream.body, { status: 200, headers });
  },
};
