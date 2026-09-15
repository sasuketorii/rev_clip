import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createWorker } from "../src/index.js";

const input = { title: "Bug", description: "Steps to reproduce", contact: "", app_version: "1.0", os_version: "macOS",
  language: "ja-JP", timezone: "Asia/Tokyo", source_info_consent: true };
const secret = "123456:TEST_ONLY_FAKE_TOKEN_abcdefghijkl";
const chat = "-123456789";
const encoder = new TextEncoder();

function request(body = JSON.stringify(input), options = {}) {
  const headers = new Headers({ "Content-Type": "application/json", "CF-Connecting-IP": "192.0.2.7" });
  for (const [key, value] of Object.entries(options.headers || {})) {
    if (value === null) headers.delete(key); else headers.set(key, value);
  }
  const req = new Request(`https://feedback.example${options.path || "/report"}`, {
    method: options.method || "POST", headers,
    ...((options.method || "POST") === "POST" ? { body, duplex: "half" } : {}),
  });
  if (options.cf !== undefined) Object.defineProperty(req, "cf", { value: options.cf });
  return req;
}

function fixture({ upstream, timers, overrides = {} } = {}) {
  const calls = [];
  const rates = [];
  const env = {
    FEEDBACK_DISABLED: "false", TELEGRAM_BOT_TOKEN: secret, TELEGRAM_CHAT_ID: chat,
    REPORT_IP_LIMIT: { async limit(arg) { rates.push(["ip", arg]); return { success: true }; } },
    REPORT_GLOBAL_LIMIT: { async limit(arg) { rates.push(["global", arg]); return { success: true }; } },
    ...overrides,
  };
  const worker = createWorker({
    ...(timers ? { timers } : {}),
    fetchImpl: async (url, init) => {
      calls.push({ url, init });
      return upstream ? upstream(url, init) : Response.json({ ok: true, result: { message_id: 1 } });
    },
  });
  return { env, calls, rates, send: (req = request()) => worker.fetch(req, env) };
}

async function status(f, req, expected, code) {
  const result = await f.send(req);
  assert.equal(result.status, expected);
  assert.equal(result.headers.get("Cache-Control"), "no-store");
  const body = await result.json();
  assert.deepEqual(body, expected === 200 ? { ok: true } : { ok: false, error: code });
  return result;
}

test("fixed recipient, plain sendMessage, no redirects/retries, minimal success", async () => {
  const f = fixture();
  await status(f, request(), 200);
  assert.equal(f.calls.length, 1);
  const { url, init } = f.calls[0];
  assert.equal(url, `https://api.telegram.org/bot${secret}/sendMessage`);
  assert.equal(init.method, "POST");
  assert.equal(init.redirect, "manual");
  assert.ok(init.signal instanceof AbortSignal);
  const sent = JSON.parse(init.body);
  assert.deepEqual(Object.keys(sent).sort(), ["chat_id", "link_preview_options", "text"]);
  assert.equal(sent.chat_id, chat);
  assert.match(sent.text, /Steps to reproduce/);
  assert.deepEqual(sent.link_preview_options, { is_disabled: true });
  assert.deepEqual(f.rates, [["ip", { key: "report:ip:192.0.2.7" }], ["global", { key: "report:all" }]]);
});

test("GET health is liveness only and never reads secrets or invokes bindings", async () => {
  const worker = createWorker({ fetchImpl: () => { throw new Error("must not send"); } });
  const inaccessible = new Proxy({}, { get() { throw new Error("must not inspect environment"); } });
  const result = await worker.fetch(request(undefined, { path: "/health", method: "GET" }), inaccessible);
  assert.equal(result.status, 200);
  assert.deepEqual(await result.json(), { ok: true });
  assert.equal(result.headers.get("Cache-Control"), "no-store");
});

test("routing and media errors cause no outgoing messages", async () => {
  for (const [options, expected, code] of [
    [{ path: "/" }, 404, "not_found"],
    [{ path: "/report?chat_id=42" }, 404, "not_found"],
    [{ method: "GET" }, 405, "method_not_allowed"],
    [{ method: "OPTIONS" }, 405, "method_not_allowed"],
    [{ headers: { "Content-Type": "text/plain" } }, 415, "unsupported_media_type"],
    [{ headers: { "Content-Type": null } }, 415, "unsupported_media_type"],
    [{ headers: { "Content-Encoding": "gzip" } }, 415, "unsupported_media_type"],
    [{ headers: { "Content-Length": "garbage" } }, 400, "invalid_length"],
  ]) {
    const f = fixture();
    const result = await status(f, request(JSON.stringify(input), options), expected, code);
    assert.equal(f.calls.length, 0);
    if (expected === 405) assert.equal(result.headers.get("Allow"), "POST");
    assert.equal(result.headers.get("Access-Control-Allow-Origin"), null);
  }
});

test("disabled is fail-closed for absent and nonliteral flags", async () => {
  for (const flag of [undefined, "true", "FALSE", "0", false]) {
    const f = fixture({ overrides: { FEEDBACK_DISABLED: flag } });
    await status(f, request(), 503, "unavailable");
    assert.equal(f.calls.length, 0);
    assert.equal(f.rates.length, 0);
  }
});

test("missing/malformed server secrets or limit bindings fail closed", async () => {
  for (const overrides of [
    { TELEGRAM_BOT_TOKEN: undefined }, { TELEGRAM_BOT_TOKEN: `${secret}/evil` },
    { TELEGRAM_CHAT_ID: undefined }, { TELEGRAM_CHAT_ID: "@arbitrary" },
    { REPORT_IP_LIMIT: undefined }, { REPORT_GLOBAL_LIMIT: undefined },
    { REPORT_IP_LIMIT: {} }, { REPORT_GLOBAL_LIMIT: { limit: "not callable" } },
  ]) {
    const f = fixture({ overrides });
    await status(f, request(), 503, "unavailable");
    assert.equal(f.calls.length, 0);
  }
});

test("only Cloudflare edge IP header determines the IP key", async () => {
  const f = fixture();
  await status(f, request(undefined, { headers: { "X-Forwarded-For": "attacker" } }), 200);
  assert.equal(f.rates[0][1].key, "report:ip:192.0.2.7");
  for (const ip of [null, "", "spoofed,192.0.2.1", "x".repeat(100)]) {
    const denied = fixture();
    await status(denied, request(undefined, { headers: { "CF-Connecting-IP": ip } }), 503, "unavailable");
    assert.equal(denied.calls.length, 0);
  }
});

test("exactly eight keys; reject unknown, missing, duplicate, nested and invalid JSON", async () => {
  const invalid = ["{", "null", "[]", JSON.stringify({ ...input, chat_id: "42" }),
    JSON.stringify({ ...input, title: 12 }), JSON.stringify({ ...input, title: {} }),
    JSON.stringify({ ...input, title: "  " }), JSON.stringify({ ...input, description: "\n" }),
    JSON.stringify({ title: "only" }),
    `{"title":"first",${JSON.stringify(input).slice(1)}`,
    JSON.stringify(input).replace('"title"', '"__proto__"'),
    JSON.stringify({ ...input, title: "\ud800" }), JSON.stringify({ ...input, title: "\udc00" }),
  ];
  for (const raw of invalid) {
    const f = fixture();
    const result = await f.send(request(raw));
    assert.equal(result.status, 400, raw);
    assert.equal(f.calls.length, 0);
  }
});

test("all field boundaries accepted, one over rejected", async () => {
  const maxima = { title: 120, description: 2500, contact: 200, app_version: 100, os_version: 100, language: 100, timezone: 100 };
  const maximumInput = Object.fromEntries(Object.entries(maxima).map(([key, limit]) => [key, "x".repeat(limit)]));
  maximumInput.source_info_consent = true;
  await status(fixture(), request(JSON.stringify(maximumInput)), 200);
  for (const [field, maximum] of Object.entries(maxima)) {
    const f = fixture();
    await status(f, request(JSON.stringify({ ...input, [field]: "x".repeat(maximum + 1) })), 400, "invalid_fields");
    assert.equal(f.calls.length, 0);
  }
});

test("Unicode, quoted punctuation and HTML stay plain; combined Telegram ceiling is enforced", async () => {
  const f = fixture();
  const text = { ...input, title: "🧪".repeat(60), description: '日本語 <b>text</b> "a:b", {} \\ 😀' };
  await status(f, request(JSON.stringify(text)), 200);
  assert.ok(JSON.parse(f.calls[0].init.body).text.includes(text.description));
  assert.ok(JSON.parse(f.calls[0].init.body).text.length <= 4096);
  const denied = fixture();
  await status(denied, request(JSON.stringify({ ...input, description: "😀".repeat(2500) })), 400, "invalid_fields");
  assert.equal(denied.calls.length, 0);
});

test("streamed 16 KiB cap without Content-Length and with understated header", async () => {
  for (const declared of [null, "1"]) {
    let cancelled = false;
    let count = 0;
    const stream = new ReadableStream({
      pull(controller) { count++; controller.enqueue(new Uint8Array(8192)); },
      cancel() { cancelled = true; },
    });
    const f = fixture();
    await status(f, request(stream, { headers: { "Content-Length": declared } }), 413, "body_too_large");
    assert.equal(f.calls.length, 0);
    assert.ok(cancelled);
    assert.ok(count <= 5);
  }
  const f = fixture();
  await status(f, request("{}", { headers: { "Content-Length": "16385" } }), 413, "body_too_large");
  assert.equal(f.rates.length, 0);
});

test("exactly 16 KiB valid JSON accepted, 16 KiB plus one rejected", async () => {
  const text = JSON.stringify(input);
  const exact = text + " ".repeat(16384 - encoder.encode(text).length);
  await status(fixture(), request(exact), 200);
  await status(fixture(), request(exact + " "), 413, "body_too_large");
});

test("invalid UTF-8 and stream failures are redacted", async () => {
  await status(fixture(), request(new Uint8Array([0xff, 0xfe])), 400, "invalid_json");
  const stream = new ReadableStream({ pull(controller) { controller.error(new Error(secret)); } });
  await status(fixture(), request(stream), 400, "invalid_json");
});

test("each limiter denies or errors without an upstream send", async () => {
  for (const binding of ["REPORT_IP_LIMIT", "REPORT_GLOBAL_LIMIT"]) {
    for (const reply of [false, undefined, "true", 1, "error"]) {
      const f = fixture({ overrides: { [binding]: { async limit() {
        if (reply === "error") throw new Error(`${secret} ${chat}`);
        return { success: reply };
      } } } });
      const result = await status(f, request(), reply === false ? 429 : 503,
        reply === false ? "rate_limited" : "unavailable");
      assert.equal(f.calls.length, 0);
      if (reply === false) assert.equal(result.headers.get("Retry-After"), "60");
    }
  }
});

test("upstream must be HTTP 200 with boolean ok true; response data never leaks", async () => {
  for (const [code, body] of [[201, { ok: true }], [429, { ok: false }], [500, { ok: true }],
    [200, { ok: false }], [200, { ok: "true" }], [200, null], [200, {}]]) {
    const f = fixture({ upstream: () => Response.json(body, { status: code }) });
    await status(f, request(), 502, "upstream_failed");
    assert.equal(f.calls.length, 1);
  }
  for (const upstream of [
    () => new Response(secret),
    () => new Response(secret, { status: 302, headers: { Location: "https://attacker.example" } }),
    () => { throw new Error(`https://api.telegram.org/bot${secret}/sendMessage ${chat}`); },
    () => new Response(" ".repeat(65537)),
  ]) {
    const f = fixture({ upstream });
    await status(f, request(), 502, "upstream_failed");
    assert.equal(f.calls.length, 1);
  }
});

function fastDeadline(number) {
  let count = 0;
  return {
    setTimeout(callback, delay) {
      assert.equal(delay, 8000);
      return setTimeout(callback, ++count === number ? 1 : 10000);
    },
    clearTimeout,
  };
}

test("8s upstream timeout aborts fetch, returns redacted 504 and never retries", { timeout: 2000 }, async () => {
  let aborted = false;
  const f = fixture({ timers: fastDeadline(4), upstream: (_, { signal }) => new Promise((_, reject) => {
    signal.addEventListener("abort", () => { aborted = true; reject(new Error(secret)); });
  }) });
  await status(f, request(), 504, "upstream_timeout");
  assert.equal(aborted, true);
  assert.equal(f.calls.length, 1);
});

test("upstream timeout also covers a stalled response body", { timeout: 2000 }, async () => {
  let cancelled = false;
  const f = fixture({ timers: fastDeadline(4), upstream: () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(encoder.encode('{"ok":')); },
    cancel() { cancelled = true; },
  })) });
  await status(f, request(), 504, "upstream_timeout");
  assert.equal(cancelled, true);
  assert.equal(f.calls.length, 1);
});

test("stalled request and limit bindings are bounded without sending", { timeout: 2000 }, async () => {
  const stream = new ReadableStream({ start() {} });
  const slowBody = fixture({ timers: fastDeadline(2) });
  await status(slowBody, request(stream), 408, "request_timeout");
  assert.equal(slowBody.calls.length, 0);
  const slowLimit = fixture({ timers: fastDeadline(1), overrides: {
    REPORT_IP_LIMIT: { limit: () => new Promise(() => {}) },
  } });
  await status(slowLimit, request(), 503, "unavailable");
  assert.equal(slowLimit.calls.length, 0);
});

test("Wrangler uses native rates, defaults disabled, and defines no secrets or storage", async () => {
  const config = JSON.parse(await readFile(new URL("../wrangler.json", import.meta.url)));
  assert.equal(config.name, "revclip-feedback");
  assert.equal(config.compatibility_date, "2026-09-15");
  assert.equal(config.workers_dev, true);
  assert.deepEqual(config.limits, { cpu_ms: 10 });
  assert.equal(config.observability.enabled, true);
  assert.equal(config.observability.head_sampling_rate, 0.1);
  assert.equal(config.observability.logs.invocation_logs, true);
  assert.equal(config.observability.traces.enabled, false);
  assert.deepEqual(config.vars, { FEEDBACK_DISABLED: "true" });
  assert.deepEqual(config.ratelimits.map((item) => [item.name, item.simple]), [
    ["REPORT_IP_LIMIT", { limit: 1, period: 60 }],
    ["REPORT_GLOBAL_LIMIT", { limit: 20, period: 60 }],
  ]);
  assert.equal(new Set(config.ratelimits.map((item) => item.namespace_id)).size, 2);
  for (const key of ["unsafe", "kv_namespaces", "d1_databases", "durable_objects", "r2_buckets", "queues"]) {
    assert.equal(Object.hasOwn(config, key), false);
  }
  const source = await readFile(new URL("../src/index.js", import.meta.url), "utf8");
  assert.doesNotMatch(source, /console\s*\./);
});

test("consent must be literal true before any forwarding metadata is accessed", async () => {
  for (const consent of [undefined, false, null, 0, 1, "true", [], {}]) {
    const f = fixture();
    const req = request(JSON.stringify({ ...input, source_info_consent: consent }));
    Object.defineProperty(req, "cf", { get() { throw new Error("must not read source"); } });
    await status(f, req, 400, "invalid_fields");
    assert.equal(f.calls.length, 0);
    assert.deepEqual(f.rates, [["ip", { key: "report:ip:192.0.2.7" }]]);
  }
  const duplicate = `{"source_info_consent":false,${JSON.stringify(input).slice(1)}`;
  await status(fixture(), request(duplicate), 400, "invalid_fields");
});

test("forward edge metadata after consent, ignore spoofed source headers, reject body source", async () => {
  const f = fixture();
  await status(f, request(undefined, {
    cf: { country: "JP", region: "Tokyo", city: "Shibuya", asOrganization: "Example ISP", asn: 64500 },
    headers: { "User-Agent": "Revclip/1.0", "CF-IPCountry": "SPOOF", "X-Forwarded-For": "SPOOF" },
  }), 200);
  const text = JSON.parse(f.calls[0].init.body).text;
  for (const value of ["IP: 192.0.2.7", "Country: JP", "Region: Tokyo", "City: Shibuya",
    "AS organization: Example ISP", "ASN: 64500", "Language (client): ja-JP",
    "Timezone (client): Asia/Tokyo", "User-Agent (client): Revclip/1.0", "consent: true"]) {
    assert.ok(text.includes(value), value);
  }
  assert.doesNotMatch(text, /SPOOF/);
  for (const key of ["ip", "country", "region", "city", "asOrganization", "asn", "cf", "user_agent"]) {
    const denied = fixture();
    await status(denied, request(JSON.stringify({ ...input, [key]: "spoof" })), 400, "invalid_fields");
    assert.equal(denied.calls.length, 0);
  }
});

test("missing or nonprimitive CF metadata is safe and optional UA is absent", async () => {
  for (const cf of [undefined, null, {}, { country: {}, city: [], region: 2, asOrganization: {}, asn: "64500" }]) {
    const f = fixture();
    await status(f, request(undefined, { cf }), 200);
    const text = JSON.parse(f.calls[0].init.body).text;
    assert.match(text, /Country: n\/a/);
    assert.match(text, /ASN: n\/a/);
    assert.doesNotMatch(text, /User-Agent|\[object Object\]/);
  }
});

test("UTF16 maxima preserve description; bounded diagnostics keep worst case within 4096", async () => {
  const maximum = { title: "t".repeat(120), description: "😀".repeat(1250), contact: "c".repeat(200),
    app_version: "a".repeat(100), os_version: "o".repeat(100), language: "l".repeat(100),
    timezone: "z".repeat(100), source_info_consent: true };
  const f = fixture();
  await status(f, request(JSON.stringify(maximum), {
    cf: { country: "J".repeat(5000), region: "😀".repeat(5000), city: "\nFake: x".repeat(1000),
      asOrganization: "\ud800".repeat(5000), asn: Number.MAX_SAFE_INTEGER },
    headers: { "User-Agent": "u".repeat(5000), "CF-Connecting-IP": "a".repeat(45) },
  }), 200);
  const text = JSON.parse(f.calls[0].init.body).text;
  assert.ok(text.length <= 4096, text.length);
  assert.ok(text.includes(maximum.description));
  assert.ok(text.isWellFormed());
  assert.doesNotMatch(text, /\nFake:/);
  const caps = { IP: 45, Country: 8, Region: 40, City: 40, "AS organization": 80, ASN: 20, "User-Agent (client)": 300 };
  for (const [label, cap] of Object.entries(caps)) {
    const line = text.split("\n").find((line) => line.startsWith(`${label}: `));
    assert.ok(line.slice(label.length + 2).length <= cap, label);
  }
  const denied = fixture();
  await status(denied, request(JSON.stringify({ ...maximum, description: maximum.description + "x" })), 400, "invalid_fields");
  assert.equal(denied.calls.length, 0);
});
