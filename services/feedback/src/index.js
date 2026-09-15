const BODY_LIMIT = 16 * 1024;
const UPSTREAM_LIMIT = 64 * 1024;
const TIMEOUT_MS = 8000;
const FIELDS = { title: 120, description: 2500, contact: 200, app_version: 100, os_version: 100,
  language: 100, timezone: 100 };

class Failure extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
    this.code = code;
  }
}

function response(status, code) {
  return new Response(JSON.stringify(status === 200 ? { ok: true } : { ok: false, error: code }), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...(status === 405 ? { Allow: "POST" } : {}),
      ...(status === 429 ? { "Retry-After": "60" } : {}),
    },
  });
}

async function boundedText(body, cap, signal, oversized) {
  if (!body) throw new Failure(400, "invalid_json");
  const reader = body.getReader();
  const buffer = new Uint8Array(cap);
  let size = 0;
  let complete = false;
  const cancel = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener("abort", cancel, { once: true });
  try {
    if (signal.aborted) throw new Failure(408, "request_timeout");
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!(value instanceof Uint8Array) || value.byteLength > cap - size) throw oversized;
      buffer.set(value, size);
      size += value.byteLength;
    }
    complete = true;
    return new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, size));
  } finally {
    signal.removeEventListener("abort", cancel);
    if (!complete) cancel();
    reader.releaseLock();
  }
}

function messageFrom(text, request, ip) {
  let data;
  try { data = JSON.parse(text); } catch { throw new Failure(400, "invalid_json"); }
  if (!data || Array.isArray(data) || typeof data !== "object" ||
      Object.keys(data).length !== 8 ||
      Object.keys(data).some((key) => key !== "source_info_consent" && !Object.hasOwn(FIELDS, key))) {
    throw new Failure(400, "invalid_fields");
  }
  if (data.source_info_consent !== true) throw new Failure(400, "invalid_fields");
  for (const [field, maximum] of Object.entries(FIELDS)) {
    const value = data[field];
    if (typeof value !== "string" || value.length > maximum) throw new Failure(400, "invalid_fields");
    for (const character of value) {
      const point = character.codePointAt(0);
      if (point >= 0xd800 && point <= 0xdfff) {
        throw new Failure(400, "invalid_fields");
      }
    }
  }
  // JSON.parse accepts duplicate names. A valid eight-field flat object has
  // exactly 33 tokens; quoted text (including escapes) is always one token.
  const tokens = text.match(/"(?:\\.|[^"\\])*"|true|false|null|[^\s]/g);
  if (tokens?.length !== 33) throw new Failure(400, "invalid_fields");
  if (!data.title.trim() || !data.description.trim()) throw new Failure(400, "invalid_fields");
  let message = `Revclip feedback\n\nTitle: ${data.title}\n\nDescription:\n${data.description}` +
    `\n\nContact: ${data.contact}\nApp version: ${data.app_version}\nOS version: ${data.os_version}` +
    `\nLanguage (client): ${data.language}\nTimezone (client): ${data.timezone}`;
  // Conservative UTF-16 ceiling also bounds Unicode code points. Never split
  // a surrogate pair or silently truncate a report to meet Telegram's ceiling.
  if (message.length > 4096) throw new Failure(400, "message_too_long");
  // Only access forwarding metadata after explicit consent and full validation.
  const cf = request.cf;
  const asn = Number.isSafeInteger(cf?.asn) && cf.asn >= 0 ? String(cf.asn) : undefined;
  message += "\n\nSource info (consent: true):";
  const diagnostics = [
    ["IP", ip, 45], ["Country", cf?.country, 8], ["Region", cf?.region, 40],
    ["City", cf?.city, 40], ["AS organization", cf?.asOrganization, 80], ["ASN", asn, 20],
  ];
  const ua = request.headers.get("User-Agent");
  if (ua) diagnostics.push(["User-Agent (client)", ua, 300]);
  for (const [label, value, maximum] of diagnostics) {
    const prefix = `\n${label}: `;
    const available = Math.min(maximum, 4096 - message.length - prefix.length);
    if (available < 1) throw new Failure(400, "message_too_long");
    message += prefix + diagnostic(value, available);
  }
  return message;
}

// Bound work and output, remove control/bidi line spoofing, and never split a
// Unicode surrogate pair. Only server diagnostics may be shortened.
function diagnostic(value, maximum) {
  const raw = typeof value === "string" && value ? value : "n/a";
  const shortened = raw.length > maximum;
  let result = raw.slice(0, shortened ? maximum - 1 : maximum);
  if (/[\uD800-\uDBFF]$/.test(result)) result = result.slice(0, -1);
  result = result.toWellFormed().replace(/[\u0000-\u001f\u007f-\u009f\u2028-\u202e\u2066-\u2069]/g, " ");
  return result + (shortened ? "…" : "");
}

export function createWorker({ fetchImpl = globalThis.fetch, timers = globalThis } = {}) {
  async function deadline(task, failure) {
    const controller = new AbortController();
    let timer;
    const expired = new Promise((_, reject) => {
      timer = timers.setTimeout(() => {
        reject(failure);
        controller.abort();
      }, TIMEOUT_MS);
    });
    try {
      return await Promise.race([task(controller.signal), expired]);
    } finally {
      timers.clearTimeout(timer);
    }
  }

  return {
    async fetch(request, env) {
      try {
        const url = new URL(request.url);
        if (url.pathname === "/health" && !url.search && request.method === "GET") return response(200);
        if (url.pathname !== "/report" || url.search) return response(404, "not_found");
        if (request.method !== "POST") return response(405, "method_not_allowed");
        // Missing or malformed flags stay disabled. This is an operational
        // switch, not client authentication; no client-supplied secret exists.
        if (env.FEEDBACK_DISABLED !== "false") return response(503, "unavailable");
        if (typeof env.TELEGRAM_BOT_TOKEN !== "string" ||
            !/^\d{1,20}:[A-Za-z0-9_-]{20,128}$/.test(env.TELEGRAM_BOT_TOKEN) ||
            typeof env.TELEGRAM_CHAT_ID !== "string" ||
            !/^-?[1-9]\d{0,19}$/.test(env.TELEGRAM_CHAT_ID) ||
            typeof env.REPORT_IP_LIMIT?.limit !== "function" ||
            typeof env.REPORT_GLOBAL_LIMIT?.limit !== "function") {
          return response(503, "unavailable");
        }
        if (!/^application\/json(?:\s*;\s*charset=utf-8)?\s*$/i.test(request.headers.get("Content-Type") || "")) {
          return response(415, "unsupported_media_type");
        }
        if (request.headers.has("Content-Encoding") && request.headers.get("Content-Encoding") !== "identity") {
          return response(415, "unsupported_media_type");
        }
        const declared = request.headers.get("Content-Length");
        if (declared !== null && !/^\d+$/.test(declared)) return response(400, "invalid_length");
        if (declared !== null && Number(declared) > BODY_LIMIT) return response(413, "body_too_large");
        // Cloudflare overwrites this header at the public edge. Do not use
        // X-Forwarded-For, payload fields, or caller-selected rate-limit keys.
        const ip = request.headers.get("CF-Connecting-IP");
        if (!ip || ip.length > 45 || !/^[0-9a-fA-F:.]+$/.test(ip)) return response(503, "unavailable");
        try {
          const allowed = await deadline(() => env.REPORT_IP_LIMIT.limit({ key: `report:ip:${ip}` }),
            new Failure(503, "unavailable"));
          if (allowed?.success === false) return response(429, "rate_limited");
          if (allowed?.success !== true) return response(503, "unavailable");
        } catch { return response(503, "unavailable"); }

        let message;
        try {
          const text = await deadline((signal) => boundedText(request.body, BODY_LIMIT, signal,
            new Failure(413, "body_too_large")), new Failure(408, "request_timeout"));
          message = messageFrom(text, request, ip);
        } catch (error) {
          return error instanceof Failure ? response(error.status, error.code) : response(400, "invalid_json");
        }

        try {
          const allowed = await deadline(() => env.REPORT_GLOBAL_LIMIT.limit({ key: "report:all" }),
            new Failure(503, "unavailable"));
          if (allowed?.success === false) return response(429, "rate_limited");
          if (allowed?.success !== true) return response(503, "unavailable");
        } catch { return response(503, "unavailable"); }

        try {
          await deadline(async (signal) => {
            const upstream = await fetchImpl(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              // workerd supports manual/follow, but rejects "error" before I/O.
              // Manual exposes 3xx to the strict HTTP-200 check below without
              // following Location or forwarding the report to another origin.
              redirect: "manual",
              signal,
              body: JSON.stringify({ chat_id: env.TELEGRAM_CHAT_ID, text: message,
                link_preview_options: { is_disabled: true } }),
            });
            if (upstream.status !== 200) {
              void upstream.body?.cancel().catch(() => {});
              throw new Failure(502, "upstream_failed");
            }
            const text = await boundedText(upstream.body, UPSTREAM_LIMIT, signal,
              new Failure(502, "upstream_failed"));
            const result = JSON.parse(text);
            if (result?.ok !== true) throw new Failure(502, "upstream_failed");
          }, new Failure(504, "upstream_timeout"));
        } catch (error) {
          return response(error instanceof Failure && error.status === 504 ? 504 : 502,
            error instanceof Failure && error.status === 504 ? "upstream_timeout" : "upstream_failed");
        }
        return response(200);
      } catch {
        // Never return or log an exception: fetch errors can contain the token
        // embedded in Telegram's URL, and upstream JSON can contain report data.
        return response(503, "unavailable");
      }
    },
  };
}

export default createWorker();
