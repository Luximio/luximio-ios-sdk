# Scoped local handoff erasure

**Unpublished candidate `0.1.0-rc.2`.** This API is absent from the issued
[`0.1.0-rc.1`](https://github.com/Luximio/luximio-ios-sdk/tree/0.1.0-rc.1).
It removes one completed handoff's readable local journal context and preserves
unrelated handoffs. It does not authenticate a privacy requester or erase
server/provider records.

## Call the scoped operation

Use the retained token session from the original handoff's configuration, on
the main actor:

```swift
let result = try session.eraseCompleted(invocationID: completedInvocationID)
```

The session supplies its own scope. The lower-level API is:

```swift
let result = try journal.eraseCompleted(
    invocationID: completedInvocationID,
    scope: configuration.scope
)
```

Follow this order:

1. Verify the case's authority and identify the original project, app/Clip,
   host configuration and exact invocation. Changing namespaces does not
   remove the old files.
2. Arrange the appropriate server handling separately. A cleared local ACK is
   a technical precondition, not evidence that every server/provider copy is gone.
3. Stop new collection for the affected operation and coordinate live writers
   in both app roles. Retain and join app-owned capture/resume tasks. Cancellation
   is cooperative; `cancelPending()` plus `waitUntilIdle()` does not prove a
   general cross-process drain.
4. Confirm that the selected entry has a pinned receipt, is `.applied` or
   `.discarded`, and has no queued acknowledgement. Finish normal completion
   handling rather than discarding outboxes to bypass this condition.
5. Call erasure and verify the selected result. Do not clear a whole journal,
   delete other handoffs or create a replacement configuration as a shortcut.

| Result | Meaning |
| --- | --- |
| `.erased` | Selected readable context was replaced by its finite replay marker |
| `.alreadyErased` | The same scoped marker exists; the deadline is not renewed |
| `.notFound` | The invocation is absent from this journal; no all-system absence claim |

| Error | Handling |
| --- | --- |
| `.wrongScope` | Correct the case mapping; the found entry/marker has another scope |
| `.busy` | Finish/coordinate active work or the pending ACK, or retry a busy lock |
| `.unverifiedContext` | A terminal entry has no pinned receipt; do not fabricate one |
| `.conflict` | A raw neighbour shares the capability, or a new capture matches a marker; preserve unrelated state |
| `.invalidData` / `.storage` | Stop and inspect bounded diagnostics; never silently reset files |

Rejected scope/state/validation requests leave journal content unchanged. A
storage failure can occur after atomic replacement, so do not infer that nothing
committed. Reopen and retry the same scoped invocation; the operation is
idempotent. No result permits logging raw URLs, capabilities or full journals.

## What remains locally

Erasure removes the selected raw capability, original URL, receipt/destination
and completion payload. The replacement contains only invocation/create-operation
IDs, project/full-app/Clip scope, a SHA-256 capability hash and original capture
and expiry dates. These are potentially linkable replay metadata, not
automatically anonymous information.

The marker follows **original invocation expiry**, not a shorter receipt expiry.
Its maximum is the original seven-day capture lifetime; erasure and retry do not
extend it. Entries plus markers share the **32-record** journal limit. An
unexpired marker cannot be evicted merely to admit another capture.

Capture checks erased invocation IDs, operation IDs and capability hashes before
superseding pending state. Saved matching capture material is rejected with
`.conflict`; a new intentional capture with new IDs/capability can still use the
same URL. Pin/transition/ACK mutations reload under the shared lock, so stale
SDK callbacks cannot recreate the removed entry.

`purge(at:)` removes eligible records when subsequent SDK work calls it with a
truthful clock. Reading alone does not purge, and an inactive app can retain
expired files. There is no background wall-clock deletion. A fabricated future
purge time is not an erasure procedure.

## Upgrade and rollback

**Upgrade both the full app and App Clip before enabling erasure.** Ordinary
schema-2 journals remain readable without eager migration. First successful
erasure writes **schema 3 in the same `SDKPrototype-v2/journal-v2.json`** under
the existing `record.lock`. Schema 3 does not downgrade after markers expire.

The previous RC rejects schema 3 rather than ignoring its markers. A downgrade
after erasure therefore fails closed. Deleting the file, resetting storage or
moving namespaces to make an old reader work would lose replay protection and
is not a supported rollback procedure. Keep both roles on the compatible release.

An externally restored old journal can rewind local history. The SDK cannot
prove that external snapshots disappeared; preserve and reconcile the applicable
server terminal/replay history under the reviewed restore procedure. Do not
equate successful local erasure with restoration safety or all-copy erasure.

This operation does not remove values already retained in application memory,
stop a dispatched server request, erase app-owned copies, or guarantee physical
overwriting of filesystem/provider history. The implementation's local tests
and candidate build checks do not establish real cross-process App Group
scheduling, device protection, server authorization or a complete rights response.
