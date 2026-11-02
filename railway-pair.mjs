// Password-gated page that mints a one-time T3 Code pairing link, so nobody has
// to dig a token out of the deploy logs or open a shell. nginx routes
// /railway-pair here; everything else goes straight to the T3 server, whose own
// session auth protects the API, WebSocket and terminals.
import { createServer } from "node:http";
import { execFile } from "node:child_process";
import { timingSafeEqual, createHash } from "node:crypto";

const password = process.env.T3_SETUP_PASSWORD;
if (!password) throw new Error("T3_SETUP_PASSWORD is required");
const digest = (s) => createHash("sha256").update(s).digest();
const want = digest(password);

const run = (cmd, args) =>
  new Promise((resolve, reject) =>
    execFile(cmd, args, { timeout: 30000 }, (err, out) => (err ? reject(err) : resolve(out))),
  );
const esc = (s) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

createServer(async (req, res) => {
  const auth = req.headers.authorization ?? "";
  const given = auth.startsWith("Basic ")
    ? Buffer.from(auth.slice(6), "base64").toString().replace(/^[^:]*:/, "")
    : "";
  if (!timingSafeEqual(digest(given), want)) {
    res.writeHead(401, { "WWW-Authenticate": 'Basic realm="T3 Code pairing", charset="UTF-8"' });
    return res.end("Password required: T3_SETUP_PASSWORD from the service's Variables tab.\n");
  }
  try {
    const proto = (req.headers["x-forwarded-proto"] ?? "http").split(",")[0].trim();
    const base = `${proto}://${req.headers.host}`;
    const issued = JSON.parse(
      await run("t3", ["auth", "pairing", "create", "--json", "--ttl", "15m", "--label", "Railway pairing page"]),
    );
    const token = issued.credential ?? issued.token;
    if (!token) throw new Error("no credential in t3 output");
    const link = `${base}/pair#token=${encodeURIComponent(token)}`;
    const qr = await run("qrencode", ["-t", "SVG", "-m", "2", "-s", "6", "-o", "-", link]);
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "Referrer-Policy": "no-referrer" });
    res.end(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pair with T3 Code</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem;color:#111;background:#fff}
a.btn{display:inline-block;padding:.7rem 1.2rem;background:#111;color:#fff;border-radius:.5rem;text-decoration:none}
code{word-break:break-all;background:#f2f2f2;padding:.2rem .4rem;border-radius:.3rem}svg{width:16rem;height:auto}
@media(prefers-color-scheme:dark){body{background:#111;color:#eee}a.btn{background:#eee;color:#111}code{background:#222}}</style>
<h1>Pair a device with T3 Code</h1>
<p>This one-time link is valid for 15 minutes and works for <b>one</b> device. Reload the page for another.</p>
<p><a class="btn" href="${esc(link)}">Pair this browser</a></p>
<p><b>Phone (T3 Code app):</b> Settings &rarr; Environments &rarr; Add, then scan:</p>
${qr}
<p><b>Desktop app or app.t3.codes:</b> Settings &rarr; Connections &rarr; Add environment, paste:</p>
<p><code>${esc(link)}</code></p>
<p>Treat this link like a password.</p>`);
  } catch (err) {
    console.error("railway-pair:", err.message);
    res.writeHead(500, { "Content-Type": "text/plain" });
    res.end("Could not create a pairing link; see the deploy logs.\n");
  }
}).listen(3774, "127.0.0.1");
