# PenChecks Orders Integration

This Salesforce DX project receives signed status events from Orders and gives CX an Account-level view of its orders. Orders remains the system of record. Salesforce stores the fields that keep the list usable, filterable and reportable during an upstream outage.

## What is in the repository

| Path | Purpose |
| --- | --- |
| `force-app` | The integration: Apex REST endpoint, event processing, order projection, snapshot import, objects, permission sets and the `Orders_API` Named Credential. |
| `scripts` | Post-deploy setup, the event simulator and the page import. |

## Endpoint exposure

**Choice: authenticated Apex REST** at `POST /services/apexrest/orders/v1/events`.

- Only a caller with a Salesforce OAuth token reaches Apex. Salesforce checks the identity, API access, Apex REST access and class access first.
- The caller is a dedicated integration identity whose permission set is the whole contract, because the code runs every query and write in user mode.
- HMAC still authenticates the exact body bytes, so a leaked token alone cannot forge an event.
- No unauthenticated guest surface exists for the integration.

This assumes Orders can obtain a token with the OAuth client credentials flow. If Orders can only send static headers, the fallback is a public Site endpoint with HMAC as the only gate, a guest profile limited to the one class, and the writes moved into a narrowly scoped system-context service.

## Prerequisites

- A personal, free Salesforce Developer Edition and a current Salesforce CLI.
- An administrator to deploy and run the setup scripts.

| Permission set | Assign to | Grants |
| --- | --- | --- |
| **Orders Integration** | The dedicated integration identity | API Enabled and Apex REST Services; Account Read, Create and View All (no Edit); order and receipt create/edit; access to `OrdersWebhook`. No callout access. |
| **Orders Operations** | People who run the snapshot import | Account Read and View All, order create/edit, and the `Orders_API` principal. |
| **Orders CX Read Access** | CX agents | Read-only Account and order fields. No receipts. |

View All on Account lets the integration tell an absent Account from a private one it cannot see. Without it, a hidden linked Account would look absent, the provisional insert would collide with the unique external ID, and every retry would fail until Orders suspends the subscription. In an org with a narrower account boundary, replace that grant with explicit sharing of every linked Account and verify it with the integration user.

## Deploy and configure

Use an org reserved for this exercise. If it is already authenticated, use its alias and skip the first command.

```bash
sf org login web --alias penchecks-dev
sf project deploy start --target-org penchecks-dev --wait 15
sf org assign permset --name Orders_Integration --name Orders_Operations --name Orders_CX --target-org penchecks-dev
sf apex run --file scripts/setup-demo.apex --target-org penchecks-dev
sf apex run --file scripts/setup-callouts.apex --target-org penchecks-dev
```

The demo admin receives all three permission sets so one user can run every part of the demo.

- `setup-demo.apex` links the fixture Account and sets the default **Orders Settings** record with the exercise signing key and subscription ID. It refuses to overwrite a different key or subscription. The key is public fixture data. In production, keep the secret in restricted storage and rotate it by accepting the current and the previous secret during a changeover.
- `setup-callouts.apex` stores the bearer token for the `Orders_API_Auth` External Credential. The mock accepts any non-empty token. For a real Orders environment, enter the issued token in **Setup → Named Credentials → External Credentials → Orders API Auth → Principals**.

One step stays manual, because shipping the standard Account layout would overwrite yours. In **Setup → Object Manager → Account → Page Layouts**, edit the layout assigned to your demo user and add **External Orders** from **Related Lists**. Set its columns to **External Order Name**, **Order Status**, **Source Updated At**, **Orders Amount** and **Orders Currency**.

### Where the callouts go

No Orders service is hosted for the exercise, so `Orders_API` points at a public mock: `https://penchecks-orders-mock.jpblabs.workers.dev/v1`. It serves the spec endpoints with the spec's sample data plus one order still in `created`, requires `Authorization: Bearer <any non-empty token>` like the spec, returns `404` for unknown IDs, and returns `429` with `Retry-After: 30` for account `acct_ratelimited`. To use another mock or a real Orders environment, change the URL of the `Orders_API` Named Credential and the token.

## Run the demo

```bash
# The spec's sample sequence plus three extra cases, signed and sent to the deployed handler
sf apex run --file scripts/simulate-events.apex --target-org penchecks-dev

# Snapshot import of acct_8f3c2a from the mock: adds amounts and the order still in created
sf apex run --file scripts/import-orders-page.apex --target-org penchecks-dev

# The project's Apex tests
sf apex run test --target-org penchecks-dev --class-names OrdersWebhookTest --class-names OrdersPageImportTest \
  --result-format human --wait 10
```

The Apex script signs each body with the configured secret, builds a `RestContext` and calls the deployed handler. It asserts every response and the final state, so a failed run stops with the event that broke it. Set its `runId` to a suffix such as `-run-02` to repeat the sequence with fresh records.

| Delivery or record | Expected result |
| --- | --- |
| `ord_77d1e9` / `OR-261001-017-2231` | `sent` |
| `ord_52ab10` / `OR-260922-017-1187` | `cleared` |
| Second delivery of `evt_001` | `200 Duplicate`; one stored receipt |
| `evt_late`: new event ID with an earlier stage for `ord_77d1e9` | `200 IgnoredStale`; status remains `sent` |
| `evt_unsupported`: correctly signed `order.cancelled` | `200 Unsupported`; one receipt with reason `UnsupportedEventType` |
| `evt_tampered`: altered request body | `403 InvalidSignature`; no receipt |
| Page import after the events | Amounts and `USD` on both orders, statuses unchanged, and `OR-261014-017-3310` added in `created` |

A fresh run stores four receipts for the five spec deliveries and two for the late and unsupported events. A rerun keeps the receipts and order states.

To send a real HTTP delivery, which also exercises OAuth, Apex REST access and routing, post the spec's `evt_004` with curl. After the Apex run it returns `200 Duplicate`; on a fresh org it returns `200 Applied`. On CLI versions without `sf org auth show-access-token`, the token is in `sf org display --json`.

```bash
INSTANCE_URL=$(sf org display --target-org penchecks-dev --json | jq -r .result.instanceUrl)
ACCESS_TOKEN=$(sf org auth show-access-token --target-org penchecks-dev --json | jq -r .result.accessToken)
BODY='{"subscriptionId":"sub_a1b2c3d4e5f67890abcdef12","event":{"id":"evt_004","type":"order.sent","occurredAt":"2026-10-12T14:03:11Z","version":"1.0"},"data":{"orderId":"ord_77d1e9","orderFriendlyId":"OR-261001-017-2231","accountId":"acct_8f3c2a","accountFriendlyId":"AC-260914-017-2231"}}'
SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac 'orders-takehome-2026' -hex | sed 's/^.* //')
curl -s -X POST "$INSTANCE_URL/services/apexrest/orders/v1/events" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
  -H "Orders-Signature: $SIG" --data-binary "$BODY"
```

## How it works

1. **Transport and message authentication.** `OrdersWebhook` receives a raw `Blob`, validates the 64-character hexadecimal signature, and calls `Crypto.verifyHMac` before decoding JSON. OAuth authenticates the Salesforce caller and HMAC authenticates the exact message bytes.
2. **Claim and process.** `OrdersEventService` validates the `1.0` envelope and the configured subscription, then claims a valid delivery by inserting a receipt with a unique `event.id`. The sender repeats IDs unchanged on redelivery. A valid signature on an unsupported type or version still produces a durable receipt. When a signed body has no usable ID or comes from another subscription, a SHA-256 digest of its bytes deduplicates it without reserving an ID in the configured stream.
3. **Project the order.** `OrdersProjection` locks the linked Account before reading and writing its orders, which gives two requests for a new order a common row to queue on. Unique Account and order external IDs guard the first-insert race. A missing Account gets a provisional name equal to its friendly ID. The integration never renames linked Accounts and refuses to reparent orders.
4. **Commit or roll back.** The receipt and the order write share a transaction. A temporary failure rolls both back so redelivery can try again. An Account/order mismatch rolls back the business work and commits one `Conflict` receipt with identifiers, the outcome and a stable reason.
5. **Resolve independent clocks.** Status rank wins because the source contract is monotonic. At the same rank, the newer source timestamp wins. Amount and currency come only from snapshots and keep their own timestamp, so an older snapshot cannot undo `sent` and an older amount cannot overwrite a newer one.

| HTTP | Meaning |
| --- | --- |
| `200 Applied`, `Duplicate`, `IgnoredStale` | The event has been resolved. A duplicate does no further work. |
| `200 Rejected`, `Unsupported`, `Conflict` | An authenticated delivery cannot be applied. A durable receipt records the reason and no order changes are committed. |
| `400` / `413` | Empty request body / body above the 16 KiB application limit. |
| `403 InvalidSignature` | Missing, malformed or mismatched HMAC. Salesforce can also reject OAuth, Apex REST or class access before Apex runs. |
| `503 RetryDelivery` | Recoverable row lock or unique-key contention. The sender can retry. |
| `500` | Missing configuration or an unexpected failure. Salesforce cannot safely acknowledge the delivery. |

Orders retries non-2xx responses and timeouts three times, then suspends the subscription. Acknowledging a permanently invalid **authenticated** event after recording it keeps one poison delivery from blocking every account. Wrong signatures and failed writes still surface as delivery failures. A receipt holds IDs for reconciliation or an upstream redrive request; it does not store the event body.

## What is stored and what is read live

| Data | Kept in Salesforce | Why |
| --- | --- | --- |
| Order ID, friendly ID, status and its source timestamp | Yes, from every event and snapshot | The list CX scans daily must work during an Orders outage, filter in list views and appear in reports. |
| Amount, currency and their snapshot timestamp | Yes, from the list endpoint | CX sees value in the list without a callout. |
| Participant reference and order lines | No; read from `GET /orders/{id}` when needed | Likely personal data under the client's retention policy, and needed only when drilling into one order. The on-demand view is listed under deliberate scope. |
| Account name | No | Accounts are linked by Orders ID. Enrichment from `GET /accounts/{id}` is left out of scope. |
| Event receipts | Yes | Idempotency and an audit trail of every terminal decision. |

At 60 requests per minute, reading the list live would let a few agents exhaust the budget, and an Orders outage would blank the Account page. The webhook therefore makes no callouts.

## Snapshot import

The webhook stream starts at the first status transition, so orders still in `created` and historical orders need a snapshot. Link the Account by Orders ID, then run `OrdersPageImport.run(accountId, page)` for one page of up to 50 orders. The callout runs before any lock or write. Two SOQL statements find the Account and all current orders, and collection DML handles the inserts and updates. Run each page in its own transaction and follow `nextPage` until it is null; set the script's `page` variable to advance. On `429`, wait for `Retry-After` and retry the same page. A failed page leaves its data unchanged. `OrdersApiClient` calls `callout:Orders_API` with a five-second timeout.

## Receipts

Every authenticated delivery leaves one receipt with its outcome and, when it was not applied, a reason. To list the deliveries that were acknowledged but not applied:

```bash
sf data query --target-org penchecks-dev \
  --query "SELECT External_Id__c, Outcome__c, Reason__c, Order_External_Id__c FROM Orders_Event__c WHERE Outcome__c IN ('Rejected','Unsupported','Conflict')"
```

| Outcome | Reason | Action |
| --- | --- | --- |
| `Unsupported` | `UnsupportedEventType`, `UnsupportedVersion` | Confirm the new type or version with Orders, then re-import the Account to catch up. |
| `Conflict` | `AccountOrderMismatch` | Fix the Account mapping, then reconcile with Orders. |
| `Rejected` | `InvalidJson`, `InvalidEnvelope`, `UnexpectedSubscription` | Raise it with Orders; the subscription or payload is wrong. |

`500` and `503` responses leave no receipt, because their transaction rolls back. Orders retries them; repeated failures show up as a suspended subscription on the Orders side.

## Tests

The Apex suites use `HttpCalloutMock` for every callout. They cover the spec sequence, duplicates, regressions, tampered and unsigned requests, empty and oversized bodies, missing configuration, unsupported and malformed events, account conflicts, the snapshot import with a full 50-order page and its statement budget, and `429` handling. Apex tests cannot exercise the HTTP layer, so Apex REST Services is verified by calling the endpoint as the integration identity.

## Questions I would have asked

| Question | Assumption | Why |
| --- | --- | --- |
| Can Orders use Salesforce OAuth? | Yes, through the client credentials flow with a dedicated integration identity. | It allows an authenticated Apex REST endpoint instead of an unauthenticated guest endpoint, and HMAC still protects the body. |
| How are existing Accounts matched, and may the integration create one? | The Orders account ID is the stable key. An unknown Account is created with its friendly ID as a provisional name and never renamed afterwards. | An event for an unlinked Account should not be lost or block the stream. Ownership, required fields and duplicate rules are the client's decision. |
| Do all non-2xx responses count toward suspension, and how are missed events recovered? | Yes, as the spec states. There is no redrive API, so recovery is a per-Account snapshot import. | One unusable event must not suspend every Account, so authenticated events that cannot be applied are acknowledged and recorded. The ranking rule makes a re-import safe to repeat. |
| Will new event types or schema versions arrive? | Only version `1.0` and the documented types are applied; anything else gets an `Unsupported` receipt. | Guessing at a new contract could corrupt order status, and the receipt keeps the event visible without suspending the subscription. |
| Can a `returned` order be reissued or move to another Account? | No. `returned` is terminal, and a different parent Account is recorded as a `Conflict`. | The spec defines no transition out of `returned`, and silently moving an order would hide it from the Account CX is looking at. |
| Do `occurredAt` on events and `updatedAt` on snapshots come from the same clock? | No. Status rank decides first, and timestamps only break ties within one status. | Comparing clocks across two feeds could move an order backward, which the spec says never happens. |
| Which order details may CX see and Salesforce keep? Is `participantRef` personal data? | Status and amount are stored; participant and lines stay in Orders. | They are likely personal data, and the Account list needs only status and amount. Retention and entitlement rules come first. |
| What load should it handle: peak events, orders per Account, replay window? | A take-home workload with one subscription. | Volume decides between this synchronous design and an asynchronous inbox, the lock strategy and how long receipts must outlive the replay window. |

## Deliberate scope

Left out on purpose, with the reason:

- **Durable asynchronous inbox.** Everything runs synchronously in the request. Salesforce waits up to about ten seconds for a row lock, the same window the sender allows, so a burst on one Account (a plan termination) could time out. The next iteration would verify and store the delivery, answer 200, then apply it asynchronously per Account.
- **On-demand order detail.** A Lightning Web Component on the order page that calls `GET /orders/{id}` when an agent asks for participant and lines. The stored fields already cover the Account list, and the import shows the callout path.
- **Automated import and reconciliation.** The page import is run by an operator, one page per transaction. A chained Queueable with `Retry-After` delays and a scheduled reconciliation would follow once call volume is measured against the 60-per-minute budget.
- **Operations UI and alerting.** Receipts are stored with outcome and reason and can be queried. A tab, a "needs attention" list view and alerts would come next.
- **Least-privilege test user.** An Apex test running as an API-only integration user with only **Orders Integration**, to prove every write path in user mode.
- **Account enrichment, receipt retention, secret rotation and the real OAuth client.** Each needs an answer from the questions above first.
