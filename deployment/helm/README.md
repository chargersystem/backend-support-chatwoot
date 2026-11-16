# Support AI setup on deploy

`script/setup_support_ai.rb` (`lib/chargersystem/support_ai_setup.rb`) brings an empty or existing
installation to the state the AI gateway needs, in this order:

1. account `CHATWOOT_ACCOUNT_NAME`;
2. first administrator `CHATWOOT_ADMIN_EMAIL` (SuperAdmin, confirmed; `CHATWOOT_ADMIN_PASSWORD` is used
   only when the user is created) and removal of the installation onboarding flag;
3. Telegram inbox for `TELEGRAM_BOT_TOKEN` named `TELEGRAM_INBOX_NAME`;
4. AgentBot `CHATWOOT_AGENT_BOT_NAME` with outgoing URL `GATEWAY_PUBLIC_URL/webhooks/chatwoot`,
   webhook secret `CHATWOOT_WEBHOOK_SECRET` and access token `CHATWOOT_BOT_TOKEN`;
5. the AgentBot assigned to the inbox;
6. label `ai-bot-active` and the four `AI:` automation rules (matched by the
   `[managed-by:cs-ai-gateway;key:…]` description; other rules are never touched);
7. Telegram webhook `FRONTEND_URL/webhooks/telegram/<token>`;
8. optional check that the ids equal `CHATWOOT_ACCOUNT_ID`, `CHATWOOT_INBOX_ID`, `CHATWOOT_BOT_ID`.

`--check` writes nothing and exits 2 when anything differs. `--apply` writes only what differs, so it runs
on every deploy. Output lists each step and the ids; secrets are never printed.

## Release wiring

Add `support-ai-setup-job.yaml` to the Chatwoot chart next to the migrations hook, with a higher
`hook-weight`. A failed Job fails the release.

## Secrets per environment

| Name | Used by | How |
| --- | --- | --- |
| `CHATWOOT_BOT_TOKEN` | setup Job, AI gateway | `openssl rand -hex 32`, same value in both |
| `CHATWOOT_WEBHOOK_SECRET` | setup Job, AI gateway | `openssl rand -hex 32`, same value in both |
| `TELEGRAM_BOT_TOKEN` | setup Job | from BotFather |
| `CHATWOOT_ADMIN_EMAIL`, `CHATWOOT_ADMIN_PASSWORD` | setup Job | first login; change the password after it |

On an empty database the records are created in order, so the ids are 1/1/1 and match the gateway
configuration. Rotating `CHATWOOT_BOT_TOKEN` or `CHATWOOT_WEBHOOK_SECRET`: update the secret, deploy
Chatwoot (the Job rewrites the values), then restart the gateway.

## Local

`docker-compose.local.yaml` service `ai-setup` runs the same script with `.env` (see `.env.example`).
