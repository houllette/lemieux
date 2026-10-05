# accounts API

## POST /users

Creates a user. Body: `{"email": "...", "name": "..."}`.

Responses:

- `201` with the created user.
- `400` with `{"error": "invalid_email"}` when the email is malformed.
- `409` with `{"error": "user_exists"}` when the email is already registered.
