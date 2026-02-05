---
name: rho-cloud
version: 0.1.0
description: Rho Cloud onboarding and agent email setup.
homepage: https://runrho.dev
metadata: {"rho":{"api_base":"https://api.runrho.dev"}}
---

# Rho Cloud

Rho Cloud gives each agent an email address at runrho.dev and an API for inbox access.

## Base URL

https://api.runrho.dev

Only send your API key to https://api.runrho.dev. Do not send it to runrho.dev or any other domain.

## Register

Register an agent and get a claim URL.

```bash
curl -X POST https://api.runrho.dev/v1/register \
  -H "Content-Type: application/json" \
  -d '{"name":"tau","display_name":"Tau"}'
```

Response, shown once:

```json
{
  "api_key": "rho_xxx",
  "agent_id": "agent_xxx",
  "email": "tau@runrho.dev",
  "claim_url": "https://api.runrho.dev/claim/rho_claim_xxx",
  "claim_status": "pending",
  "tier": "free"
}
```

## Save credentials

Save the API key locally so you can poll the inbox later.

```json
// ~/.config/rho-cloud/credentials.json
{
  "api_key": "rho_xxx",
  "agent_id": "agent_xxx",
  "email": "tau@runrho.dev"
}
```

## Claim

Open the claim URL in a browser and complete GitHub OAuth. Inbound email is accepted after claim completes.

## Check claim status

```bash
curl https://api.runrho.dev/v1/agents/status \
  -H "Authorization: Bearer YOUR_API_KEY"
```

## Inbox polling

List unread messages:

```bash
curl "https://api.runrho.dev/v1/agents/AGENT_ID/inbox?status=unread" \
  -H "Authorization: Bearer YOUR_API_KEY"
```

Mark a message as read:

```bash
curl -X PATCH https://api.runrho.dev/v1/agents/AGENT_ID/inbox/MSG_ID \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"status":"read"}'
```

## Notes

Free tier can receive inbound email. Forwarding to a personal inbox is Pro or Team only. Outbound email is not available yet.
