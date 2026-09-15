# Revclip agent skill installation

The bundled installer copies the self-contained `revclip` skill into supported
agent configuration homes already present on this Mac. It does not start an
agent, launch Revclip, read credentials, or scan the home directory recursively.
Provider support was checked against official documentation on 2026-09-16.

## Native app commands

The distributed app includes the native executable `Contents/Helpers/revclip`.
Skill setup and CLI use do not require Python or a repository checkout. Set `APP`
to your app location; the example uses a relative placeholder:

```sh
APP='path/to/Revclip.app'
"$APP/Contents/Helpers/revclip" agent inspect --app Revclip
"$APP/Contents/Helpers/revclip" agent install --app Revclip
"$APP/Contents/Helpers/revclip" agent inspect --app Revclip
```

`--app` accepts `Revclip` (default) and `revclip-demo`. Use the explicit target
for subsequent CLI operations. Installation is local and does not need the app
running; template/settings/report operations require the selected app to be running.

The app packages skill resources under `Contents/Resources/AgentSupport` and the
native CLI under `Contents/Helpers/revclip`. Installation uses the leaf folder
`revclip`, containing `SKILL.md`, `scripts/revclip`, and `agents/openai.yaml`.
The installed CLI is native; no Python runtime is required. Files are copied,
not linked to a source checkout.

## Checking and updating from Agent Settings

Opening Agent Settings or pressing Recheck runs `agent inspect` and displays
installed status and pending updates from `installed` and `update_available`.
Inspection is read-only. It neither installs skills nor automatically overwrites
an older copy when the app is upgraded.

To install or update, copy the setup prompt and run it manually in your agent.
The prompt runs inspect, install, then inspect again. A managed, unedited copy
can be updated; unmanaged or locally changed copies remain conflicts and are
not overwritten. Follow the returned reload/new-session guidance afterward.

## Detection and destinations

`~` below means the user's home directory. An environment override replaces the
default detection base: a missing override directory is skipped, even if the
default directory exists. Empty overrides behave as unset. Overrides must be
absolute paths or start with `~/`; relative paths and `..` are rejected. No
other variables inside path strings are expanded.

The installer checks only these exact base directories. Their existence is a
detection hint, not proof of an installed agent version or working session.
Missing bases are never created. An existing base may receive a new `skills`
directory. Each destination below receives `revclip/SKILL.md`, its CLI, and
`revclip/agents/openai.yaml`.

| Provider ID | Default detection base | Selected skills root | Environment handling |
| --- | --- | --- | --- |
| `codex` | `~/.codex` | `~/.agents/skills` | If `CODEX_HOME` is set, require that base and select `$CODEX_HOME/skills` for isolated homes such as Orca. |
| `claude` | `~/.claude` | `~/.claude/skills` | `CLAUDE_CONFIG_DIR` replaces the base. |
| `cursor` | `~/.cursor` | `~/.cursor/skills` | No verified root override. |
| `antigravity2` | `~/.gemini/config` | `~/.gemini/config/skills` | No verified root override. |
| `antigravity-ide` | `~/.gemini/antigravity` | `~/.gemini/antigravity/skills` | No verified root override. |
| `antigravity-cli` | `~/.gemini/antigravity-cli` | Not installed | Official CLI docs describe flat Markdown; nested bundle discovery is unverified. |
| `gemini` | `~/.gemini` | `~/.gemini/skills` | `GEMINI_CLI_HOME` replaces the home parent: require `$GEMINI_CLI_HOME/.gemini`, install under its `skills`. |
| `grok` | `~/.grok` | `~/.grok/skills` | `GROK_HOME` replaces the base. Official Grok Build only. |
| `kimi` | `~/.kimi-code` | `~/.kimi-code/skills` | `KIMI_CODE_HOME` replaces the base. |
| `kimi-legacy` | `~/.kimi` | `~/.kimi/skills` | `KIMI_SHARE_DIR` does not relocate skill discovery. |
| `hermes` | `~/.hermes` | `~/.hermes/skills` | `HERMES_HOME` selects the profile base. |
| `deepseek-harness` | `~/.dsh` | `~/.dsh/skills` | Experimental, existing base only; `DSH_HOME` replaces the base. |

The catalog is `agents/AgentSupport/providers.json`. It includes source URLs and
reload guidance in every JSON result. Compatibility discovery through another
product's root is not used as evidence that a product is installed.

### Shared roots and configuration limits

Several agents also discover `~/.agents/skills` and other compatibility roots.
Codex uses the shared canonical root unless `CODEX_HOME` selects an isolated
legacy-compatible root. Other targets use their product-specific primary root.
Duplicate discovery of the same skill name is possible; all copies installed by
this tool have identical bytes. The installer does not remove or modify other
copies to change precedence.

Hermes `skills.external_dirs`, Grok `[skills] paths` and compatibility toggles,
Kimi `extra_skill_dirs` / `--skills-dir`, and DeepSeek filesystem-provider settings
can change what a running agent discovers. Those configuration contents are not
read or changed. `DSH_AGENTS_HOME` relocates DeepSeek's shared compatibility root,
not the selected product-specific `$DSH_HOME/skills` root. `GEMINI_CLI_HOME` also
relocates Gemini's shared `.agents` root, which this installer does not write.

DeepSeek **models** are not an install target. DeepSeek Harness (`dsh`) is a
separate official agent in developer preview, with configurable skill providers.
Its detected directory alone does not guarantee its filesystem provider is enabled.

## JSON contract and exit status

Both commands emit one JSON object to stdout:

```json
{
  "schema_version": 1,
  "command": "inspect",
  "app": "Revclip",
  "skill": "revclip",
  "ok": true,
  "source_error": null,
  "providers": [
    {
      "id": "claude",
      "name": "Claude Code",
      "detected": false,
      "path": "<resolved skill destination>",
      "state": "missing",
      "action": "skipped",
      "experimental": false,
      "sources": ["https://code.claude.com/docs/en/skills"],
      "reload": "Restart if the skills root was absent at startup.",
      "reason": "configuration base absent"
    }
  ]
}
```

Runtime `path` is the resolved destination for the UI; it can be `null` when an
override is invalid. The displayed example uses a placeholder, not a filesystem
path. A provider reports:

- `detected`: its exact configuration base exists and could be opened without
  following symlinks. Ownership checks may still reject it.
- `state`: `missing`, `installed`, `conflict`, or `unsupported`.
- `action`: `skipped`, `none` (inspection), `installed`, `updated`, `unchanged`,
  or `failed`.
- `update_available`: whether a valid managed copy differs from the bundle;
  `null` if the bundle cannot be read. Present for supported, inspected targets.
- `reason`: skip or failure details when applicable.

`installed` means the on-disk management record and content hashes agree. It
does not mean an agent loaded the skill. After a failed update with successful
rollback, state may be `installed` while action is `failed`: the old copy remains.
Likewise a cleanup failure after publication is reported as a failure even if the
new skill is installed. Inspect again to determine whether an update is pending.

Exit `0` means no target failed; missing products and unsupported Antigravity CLI
are normal skips. Exit `1` means at least one conflict/failure, or an invalid
source bundle during installation. Other targets still run. Inspection can report
`source_error` without failing when destination inspection itself succeeded.
Invalid command-line arguments exit `2`. A fatal catalog error
emits `schema_version`, `ok: false`, and `error` with exit `1`.

## Managed updates and safety

The hidden `.revclip-managed.json` records the installer identity, schema version,
SHA-256 digest, and mode for all three files. The existing tree must match its record
exactly, including the permitted file layout. An unchanged install leaves file
bytes and timestamps untouched. Updates replace only a validated managed leaf.
Previously managed two-file copies can be upgraded to include `agents/openai.yaml`.
Missing metadata in a three-file managed copy is a conflict, not a legacy copy.

Unmanaged folders, missing/malformed manifests, duplicate manifest keys, edited
files, unexpected files, hard-linked files, symlinks in any traversed component,
and unsafe configuration directory ownership/permissions are refused. There is
no force flag. Credential files elsewhere in configuration homes are not opened.
Each file read is capped at 8 MiB; directory enumeration is limited to the fixed
bundle layout. Unrelated siblings are preserved.

Each target uses a private sibling stage and exclusive installer lock. Files are
written and flushed before publication. Updates rename the old leaf to a backup,
publish the staged directory by rename, verify readback, and remove the backup.
Publication failures restore the old leaf. The backup/publish pair has a brief
interval where the destination name is absent; this is not a multi-target or
power-loss transaction. Completed targets stay installed if another target fails.

Ordinary staging failures clean up the private stage. A crash, cleanup error, or
failed rollback may leave a `.revclip-stage-*`, `.revclip-backup-*`, or
`.revclip-install.lock` directory. The installer never automatically clears an
existing lock or adopts unknown recovery directories. Inspect these manually
before recovery. It serializes cooperating installer processes; it is not a
security boundary against another process running as the same user.

## Reload and official sources

- **Codex:** begin a new session. [Official skills documentation](https://developers.openai.com/codex/skills/).
- **Claude Code:** existing roots watch `SKILL.md` changes; restart if the root was
  absent at startup or when using a mode without watching. [Skills](https://code.claude.com/docs/en/skills),
  [configuration root](https://code.claude.com/docs/en/claude-directory).
- **Cursor:** startup discovery is documented; restart for reliable refresh.
  [Skills reference](https://prod.cursor.com/docs/skills).
- **Antigravity 2.0:** new conversation; live reload is not guaranteed.
  [2.0 skills](https://antigravity.google/docs/skills).
- **Antigravity IDE:** restart application and start a conversation.
  [IDE skills](https://antigravity.google/docs/ide/skills/),
  [Google restart guidance](https://codelabs.developers.google.com/io26/keynote/agent-first-workflows).
- **Antigravity CLI:** excluded from bundle installation.
  [Flat Markdown CLI documentation](https://antigravity.google/docs/cli/plugins/).
- **Gemini CLI:** `/skills reload` or `/skills refresh`.
  [Skills management](https://geminicli.com/docs/cli/using-agent-skills/),
  [environment semantics](https://geminicli.com/docs/reference/configuration/).
- **Grok Build:** disk changes reload within seconds.
  [Official guide](https://github.com/xai-org/grok-build/blob/482711333c7195dc16a272777f86086d615e2afb/crates/codegen/xai-grok-pager/docs/user-guide/08-skills.md),
  [settings](https://docs.x.ai/build/settings).
- **Kimi Code:** current versions watch user roots; restart older versions.
  [Current roots](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/skills.html),
  [watcher change](https://github.com/MoonshotAI/kimi-code/commit/fb0353a8ba5ceb7e8ae4e27f3260b3c8c8d80784).
- **Python Kimi CLI:** restart for startup discovery.
  [Legacy roots](https://moonshotai.github.io/kimi-cli/en/customization/skills.html),
  [KIMI_SHARE_DIR limitation](https://moonshotai.github.io/kimi-cli/en/configuration/data-locations.html).
- **Hermes:** new session or `/reset`.
  [Skills](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills),
  [profile isolation](https://hermes-agent.nousresearch.com/docs/user-guide/profiles),
  [reload guidance](https://hermes-agent.nousresearch.com/docs/guides/work-with-skills).
- **DeepSeek Harness:** default provider watches for next-step refresh.
  [Official developer preview](https://www.deepseek.com/harness/en/),
  [filesystem-provider contract](https://github.com/deepseek-ai/deepseek-harness/blob/0d1f50007f9bca3f52b06e1c3074fa14d5fb0720/packages/skill/skill-filesystem/README.md).

## Native validation status

Local validation recorded 77 CLI tests (40 Python compatibility + 37 native
CLI/installer integration tests) passing in 5.9 seconds, 225 XCTest tests
passing in 24.8 seconds, and 23 Worker tests passing with zero skips. Native Universal Debug compilation passed for arm64 and x86_64; this is
not runtime acceptance on both architectures.

The reporter accepted the Finder file-copy image fix on their Mac. The final
XCTest run includes a passing UI AX (accessibility) text-area reachability test.
Local validation and verification of public distribution artifacts are separate.
These results do not establish public CI or release acceptance. See
[Releases](https://github.com/sasuketorii/rev_clip/releases) for published versions.
A single warm Demo performance run is documented in [performance notes](PERFORMANCE.md);
it does not establish completion of all performance work.

## Developer compatibility tools and tests

The source files `agents/AgentSupport/install.py` and `scripts/revclip` are Python
compatibility/developer tools, not the app runtime or the user installation path.
The following command exercises the Python installer only; its results do not
prove native installer acceptance. Validate the native executable separately in
isolated temporary homes before release.


```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p test_agent_install.py -v
```

Tests use temporary homes, explicit environment maps, and synthetic bundles.
They cover product and environment roots, missing-base skips, inspection without
writes, both app names, identical installs, managed updates, conflict preservation,
symlink refusal, malformed manifests, interrupted staging, publication rollback,
and partial target failure. They do not install into the real user home, start
agents, or build the application.
Metadata tests cover managed hash/readback, edited-file refusal, legacy upgrades,
partial staging cleanup, and inspecting/installing the actual source bundle in a
temporary home.
