# Feedback relay deployment

## Scope and baseline

- Worker: `revclip-feedback`; public route: `POST /report`; `GET /health` is liveness only.
- Host: `revclip-feedback.sasuketorii-business.workers.dev`.
- Baseline checked: 2026-09-16; recheck before a later deployment or billing change.
- Existing account plan: Workers Paid, $5/month. No new plan or paid product is added.
- Dashboard usage at inspection: 52.29k requests, 429,808 CPU ms, $0 usage charges
  in the current September 10–October 10 period.
- Existing email budget alerts named “Workers budget alert $7” and “$9” were enabled.
- Worker did not exist before this change; the new relay is now deployed and delivery-verified.

## Live verification — 2026-09-16

The deployment owner confirmed the corrected Worker is active: the CLI returned
`{ok:true,status:sent}`, and a screenshot of the fixed Telegram group confirmed
receipt at 03:47 JST. This verifies one real end-to-end submission and receipt;
it does not establish sustained load capacity or worldwide rate-limit accuracy.
This delivery evidence was reported by the deployment owner; the documentation
update did not send another report or inspect secrets. No recipient identifiers,
private source addresses, tokens, or report contents are recorded here.

`GET /health` also returned 200 with the application User-Agent. The deployment
owner observed Cloudflare error 1010 with Python's default User-Agent; liveness
alone does not verify the report path or Telegram delivery.

### Runtime corrections verified

- `compatibility_date` is `2026-09-15`. The initial `2026-09-16` attempt was
  rejected as a future date while the Cloudflare API was still on September 15 UTC.
- Actual workerd reproduction identified `redirect: "error"` as the immediate
  pre-send `TypeError` behind `502 upstream_failed`. Detached native fetch and
  AbortSignal worked; fetch binding was not the cause.
- The corrected Worker uses `redirect: "manual"`. It does not follow Location;
  the strict HTTP-200 check rejects 3xx responses. The local workerd regression
  verified successful sending and 302 rejection with one intercepted attempt each.

The implementation is compatible with Workers Free limits, but this deployment
uses the account's existing Paid plan. Included quota is shared with other Workers;
additional cost is not unconditionally guaranteed to be zero.

## Cost and limits

| Scenario | Requests/month | CPU ceiling | Expected additional usage cost at the inspected baseline |
| --- | ---: | ---: | --- |
| 100 reports/day | 3,000 | 30,000 ms | $0, within included quota |
| Ten times that volume | 30,000 | 300,000 ms | $0, within included quota |
| Bot traffic / caller retry bug | Not globally capped | 10 ms/invocation | May exceed shared quota; rate limiting does not cap incoming request billing |

The included Paid quota is 10 million requests and 30 million CPU ms/month.
Overage is $0.30/million requests and $0.02/million CPU ms.
See [pricing](https://developers.cloudflare.com/workers/platform/pricing/).

Each IP is limited to one submission/minute, with a shared key limited to 20/minute
**per Cloudflare location**. These limits are not a strict worldwide counter and
do not authenticate an official Revclip client. The endpoint is public. See
[rate limiting](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/).

No KV, D1, R2, Durable Objects, Queues, cron, image conversion or AI binding is used.
There is one outbound Telegram request per accepted report and no automatic retry.
Request bodies are capped at 16 KiB, field lengths are bounded, and Telegram output
is capped at 4,096 UTF-16 code units. Outbound waits are bounded at eight seconds.

## Secrets and privacy

`TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are Worker Secrets. Neither value belongs
in source control, app resources, client requests, logs, or deployment reports.
The recipient is fixed server-side. The relay never accepts a client-selected
recipient, Telegram method or destination URL. See
[Cloudflare Secrets](https://developers.cloudflare.com/workers/configuration/secrets/)
and [Telegram sendMessage](https://core.telegram.org/bots/api#sendmessage).

The app sends the entered title, description, optional contact, generated language,
timezone and app/macOS versions, and explicit source-information consent. After
validating consent, the Worker adds the edge IP, approximate geography and network
information from Cloudflare, plus optional client-supplied User-Agent. Source
addresses and Cloudflare metadata cannot be selected through the JSON body.
The edge IP is processed for anti-abuse before consent validation. A required initially unchecked GUI
checkbox or explicit CLI consent flag gates sending. No automatic history, clipboard, template, log
or screenshot collection occurs. Telegram messages use plain text and disable link
previews. Error responses are generic; upstream payloads and exception strings are
not returned or logged. Traces are disabled; sampled invocation logs omit report
bodies. Treat Telegram group membership as access to submitted reports.

## Monitoring, stop and rollback

Monitor Worker request count, errors, CPU time and HTTP 429/5xx in Cloudflare.
Review unexpected submission bursts immediately. Budget emails are alerts, not a
hard spending cap. Set `FEEDBACK_DISABLED=true` to reject new reports, or disable
the Worker public route for an incoming-request flood. The initial configuration
defaults to disabled and cannot send before secrets and activation are configured.

Run Wrangler commands from `services/feedback` using the verified deployment account.
For an existing deployment, use `wrangler rollback` to select a previously verified
version. Earlier versions from this initial rollout did not establish working
delivery; do not select one merely because it exists. Disable the public route or
deploy the disabled configuration when no suitable verified version is available.
Preserve the app's error state
and entered text when the relay is unavailable.

## Validation

**23/23 tests passed**, including 22 Node contract tests and one real
Miniflare/workerd regression with all outbound traffic intercepted locally.
The runtime test is mandatory: from `services/feedback`, run `npm ci` then
`npm test` using Node 24. Miniflare is an exact, lockfile-pinned development
dependency; missing dependencies fail instead of skipping runtime acceptance.
The `5.20260915.0-alpha` pin supports the deployed compatibility date, which the
latest stable 4.x runtime could not load. It is not a production Worker dependency.

Local contract tests cover strict input validation, streaming size limits, missing
secrets, both rate limits, upstream errors, stalled requests, stalled responses,
timeouts, redaction, consent, bounded source metadata, and no retry. The workerd
test covers native fetch options and redirect rejection. These tests use synthetic
secrets and do not send Telegram messages. Separate live acceptance evidence is
recorded above; no claim of sustained-load or CPU-budget measurement is made.
