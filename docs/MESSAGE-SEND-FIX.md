# Message send correction

The native client supplied the same UUID twice: `Idempotency-Key` and deprecated JSON `nonce`. In Stoat 0.15.5, the header request guard inserts the value into a shared cache, then message creation consumes the body nonce against that same cache. This rejects the first send as `InvalidOperation`; the app displays the generic unconfirmed-delivery state. This is a source-confirmed protocol defect, not a completed live-message acceptance test.

Primary source for the deployed server version:

- [Header and legacy nonce share TOKEN_CACHE](https://github.com/stoatchat/stoatchat/blob/v0.15.5/crates/core/database/src/util/idempotency.rs).
- [Message creation consumes data.nonce and echoes the idempotency key](https://github.com/stoatchat/stoatchat/blob/v0.15.5/crates/core/database/src/models/messages/model.rs).
- [Deprecated body nonce and 64-character bound](https://github.com/stoatchat/stoatchat/blob/v0.15.5/crates/core/models/src/v0/messages.rs).

Both plain and rich-message sends now use only the stable header key. The returned nonce still reconciles the optimistic message and gateway event. The client enforces the server's 64-character key limit before issuing a request. Replies and attachment identifiers are unchanged.

A manual retry reuses the original key. If the server reports HTTP 409, the client reads the latest authorized history and reconciles an existing message with that key. When history cannot confirm it, the app reports the unresolved duplicate and never automatically posts again under a different key. This avoids duplicate messages after a lost response. Old pending sends from the broken build may have already consumed their keys without creating a message: refresh/check the conversation, then compose a new message if it is absent. Repeatedly retrying an old consumed key cannot safely repair it.

Tests cover header-only plain/rich payloads, response reconciliation, unresolved consumed keys and key length. Existing controller tests retain stable-key retry/gateway deduplication coverage.
