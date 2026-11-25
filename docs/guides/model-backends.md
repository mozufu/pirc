# Model backends

[User guides](README.md) · [All documentation](../README.md)

- **Models (gateway)**: model backends and their credentials live only on the gateway, which also **runs every model request**. Agents stay on their nodes and send requests over the node link (via a private, token-protected Unix socket from agent to node); the gateway resolves the backend, calls the model, and streams the reply back. Nodes and agents receive only a secret-free model catalog: no API key, OAuth token, endpoint URL or header. Because credentials are resolved per request, a changed key, a token refresh, a new login or a logout reaches running sessions on their next request; a settings change cancels requests in flight. Backends come from two sources:
  - **Web Settings → Model backends** (`$PIRC_STATE_DIR/backends/settings.json`, mode 0600, written atomically): every subscription login built into the pinned [pi-ai](https://github.com/earendil-works/pi/tree/main/packages/ai) version (`@mariozechner/pi-ai@0.73.1`: **Anthropic Claude Pro/Max**, **GitHub Copilot**, **ChatGPT Plus/Pro (Codex)**), API-key or keyless custom endpoints (`openai-completions`, `openai-responses`, `anthropic-messages`, legacy `openai-chat`), and the default model. See [Subscription logins](./model-backends.md#subscription-logins).
  - **`models.json`** (`PIRC_MODELS_FILE`, default `$PIRC_CONFIG_DIR/models.json`, i.e. `~/.config/.pirc/models.json`): `providers` and `defaultModel`, read-only in the web UI. Reference API keys with `apiKeyEnv`, `apiKeyFile`, or `apiKeyCommand` (resolved on the gateway). A file backend wins over a web backend with the same ID; the web default model wins over the file default. Send the gateway `SIGHUP` to reload the file. An invalid file is fatal at startup, and on reload it is logged and ignored.

  Endpoints must be reachable from the gateway (a model server that only listens on a node's `localhost` is not). Nodes have no provider settings of their own; `providers` and `defaultModel` in a node's `config.json` are ignored with a warning.

## Built-in provider model lists

The model metadata was refreshed on **2026-10-20** from the published,
integrity-checked `@earendil-works/pi-ai@1.3.0` data files. OpenCode Zen and
Go use their separately pinned official live metadata. All existing provider IDs
are retained; only chat models using a transport pirc implements are included.
This metadata refresh does **not** replace the pinned OAuth/login implementation
or certify account access to every model. Existing configured models and defaults
are preserved. Choose **Discover** or edit the backend to adopt a new model.

| Provider catalog        | Models |
| ----------------------- | -----: |
| `anthropic`             |     17 |
| `cerebras`              |      2 |
| `cloudflare-ai-gateway` |     57 |
| `cloudflare-workers-ai` |     18 |
| `deepseek`              |      2 |
| `fireworks`             |     22 |
| `github-copilot`        |     36 |
| `groq`                  |      7 |
| `huggingface`           |     78 |
| `kimi-coding`           |      4 |
| `minimax`               |      3 |
| `minimax-cn`            |      3 |
| `moonshotai`            |      4 |
| `moonshotai-cn`         |      4 |
| `openai`                |     44 |
| `openai-codex`          |      9 |
| `opencode`              |     72 |
| `opencode-go`           |     34 |
| `openrouter`            |    396 |
| `vercel-ai-gateway`     |    301 |
| `xai`                   |      4 |
| `xiaomi`                |      6 |
| `xiaomi-token-plan-ams` |      4 |
| `xiaomi-token-plan-cn`  |      4 |
| `xiaomi-token-plan-sgp` |      4 |
| `zai`                   |      7 |

Ollama and LM Studio expose models installed on the user's server, so their
presets discover that server rather than shipping a fixed model list. Custom
endpoints keep the models/API/base URL the user configured.

Known models on the official OpenRouter and Fireworks endpoints also retain their
per-model API routing (Chat Completions or Anthropic Messages). Custom proxies are
never redirected to an official service.

Maintainers can regenerate the data with:

```sh
bun scripts/model-catalog.ts --refresh-providers --refresh-opencode
bun scripts/model-catalog.ts --check
```

The refresh downloads public package data without installing or executing package
code. Review `scripts/catalog/providers.json`, `scripts/catalog/opencode.json` and
the generated Rust catalog together; unsupported APIs are recorded in the pins.

## OpenCode Zen and Go

**Settings → Model backends** includes separate **OpenCode Zen** and **OpenCode Go** presets. The gateway ships a dated catalog and lists models from OpenCode's official endpoint when you choose **Discover**. Updating the gateway refreshes the built-in choices for both Web and Android; existing saved model selections are retained. Edit the backend and select the new models you want to use.

On the preset's official endpoint, known models use their cataloged Chat Completions, Responses or Anthropic Messages API automatically. The legacy official `/zen/v1` and `/zen/go/v1` base URLs also use current routes when saved again. A custom proxy base URL keeps the API and endpoint you configured; it must support those selected models itself.

The built-in list includes live model IDs with verified OpenCode metadata and a supported wire API. Models needing Google's or Mistral's native API, and IDs lacking OpenCode metadata, are omitted. Input capabilities are limited to the text and image formats pirc supports. Catalog presence does not establish account access; real model calls are not exercised by automated tests.

## Subscription logins

Open **Settings → Model backends** and choose **Log in**. The gateway runs the login flow (ported from pi-ai) as a time-limited task (10 minutes) and shows its steps in the browser: the authorization link and instructions, device codes, questions (such as a GitHub Enterprise domain), and progress. Nothing needs a CLI on a node.

- **Claude Pro/Max** and **ChatGPT/Codex** use fixed `localhost` redirect URLs. When your browser is not on the gateway machine, the final redirect page fails to load; copy that complete `http://localhost:…` URL from the address bar and paste it into the login card. It must carry the state from this login. Do not expose a callback port.
- **GitHub Copilot** uses a device code. pi-ai's login also **enables the policy for every GitHub Copilot model it knows** on your account, so the UI requires explicit consent first. Some models may still need enabling in Copilot itself.
- Tokens are refreshed on the gateway shortly before they expire, once for concurrent requests. **Log out** deletes the gateway's saved credentials and blocks new requests; it does not revoke the account upstream or recall content already sent.
- pi-ai's model catalog is not proof that your plan includes a model, and a built-in login is not a statement about each service's terms for third-party clients: check them yourself. Real logins and paid calls are not part of the automated tests.

Implementation references: [observational memory](../architecture/observational-memory.md) and [model backends and authentication](../architecture/backend-auth.md).
