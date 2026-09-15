import { test } from "node:test";
import assert from "node:assert/strict";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { readFile } from "node:fs/promises";

// Required runtime acceptance using the lockfile-pinned development dependency.
// Missing dependencies fail the suite; no environment-variable skip is allowed.
test("workerd native fetch sends once and rejects redirects without following", async () => {
  const source = await readFile(new URL("../src/index.js", import.meta.url), "utf8");
  const script = source.replace("export default createWorker();", `
    const worker = createWorker();
    export default { fetch(request, env) {
      const rate = { limit: async () => ({ success: true }) };
      return worker.fetch(request, {...env, REPORT_IP_LIMIT: rate, REPORT_GLOBAL_LIMIT: rate});
    }};
  `);
  let calls = 0;
  let upstreamStatus = 200;
  const options = {
    cf: false, modules: true, compatibilityDate: "2026-09-15", script,
    bindings: { FEEDBACK_DISABLED: "false", TELEGRAM_BOT_TOKEN: "123456:TEST_ONLY_FAKE_TOKEN_abcdefghijkl",
      TELEGRAM_CHAT_ID: "-123456789" },
    outboundService: async (request) => {
      calls++;
      assert.equal(new URL(request.url).hostname, "api.telegram.org");
      const body = await request.json();
      assert.equal(body.chat_id, "-123456789");
      assert.equal(body.text.includes("Runtime test"), true);
      return new Response(JSON.stringify({ ok: true }), {
        status: upstreamStatus, headers: { Location: "https://must-not-follow.invalid/" },
      });
    },
  };
  const mf = new Miniflare(convertV4MiniflareOptions(options));
  try {
    for (const status of [200, 302]) {
      upstreamStatus = status;
      const before = calls;
      const result = await mf.dispatchFetch("https://local.invalid/report", {
        method: "POST", headers: { "Content-Type": "application/json", "CF-Connecting-IP": "192.0.2.7" },
        body: JSON.stringify({ title: "Runtime test", description: "Synthetic local report", contact: "",
          app_version: "1", os_version: "test", language: "en", timezone: "UTC", source_info_consent: true }),
      });
      assert.equal(result.status, status === 200 ? 200 : 502);
      assert.deepEqual(await result.json(), status === 200 ? { ok: true } : { ok: false, error: "upstream_failed" });
      assert.equal(calls - before, 1);
    }
  } finally {
    await mf.dispose();
  }
});
