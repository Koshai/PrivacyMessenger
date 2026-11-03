# Friends API (Milestone B)

All endpoints require `Authorization: Bearer <session-token>`.

## Create request

`POST /friends/requests`

```json
{ "email": "friend@example.com" }
```

- `202` generic success (also used when the account does not exist or is blocked, to reduce enumeration)
- `400` invalid email / self-invite
- `409` already friends or pending
- `429` rate limited

## Lists (caller-private only)

- `GET /friends` → `{ "friends": [{ "user_id", "email", "since" }] }`
- `GET /friends/count` → `{ "count": N }`
- `GET /friends/requests/incoming` → `{ "requests": [...] }`
- `GET /friends/requests/outgoing` → `{ "requests": [...] }`
- `GET /friends/blocks` → `{ "blocked": [...] }`

There is **no** endpoint to read another user’s friends or friend count.

## Transitions

- `POST /friends/requests/{id}/accept` → `204`
- `POST /friends/requests/{id}/reject` → `204`
- `DELETE /friends/{userID}` → `204`
- `POST /friends/blocks` with `{ "user_id" }` → `204` (also clears relationships)
- `DELETE /friends/blocks/{userID}` → `204`
