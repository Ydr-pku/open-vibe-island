# Remote Codex Desktop Usage

The desktop IPC collector routes each candidate by its actual Codex host ID.
Local candidates come from the session registry and diagnostic thread IDs;
remote candidates come from the desktop's saved remote project and explicit
thread membership metadata. The NPU monitor's SSH host is unrelated.

The collector follows a thread only long enough to receive a usage snapshot,
then unsubscribes. It reads cumulative token counters and timestamps, and does
not persist prompts, responses, credentials, or the rest of the snapshot. The
private IPC protocol may change; unavailable snapshots leave cached observations
and rollout data intact. Collection uses a bounded deadline and local socket
timeouts. Only threads currently owned/loaded by a connected desktop instance
can return an IPC snapshot; opening or using a previously unloaded remote thread
makes it eligible for collection. This does not enumerate a remote host's full
rollout archive or retroactively recover all historical usage.

The cache identifies sources by host plus thread and reads the previous schema
as local data. The history aggregator counts a logical thread once across
handoff copies, takes its largest valid cumulative counter, and deducts tokens
already present in local rollouts.

Remote snapshots do not contain per-day historical counters. Their first
cumulative observation is assigned to a day only if its entire creation-to-update
interval falls on that day. Later differences are retained as observation
intervals; zero-delta samples also advance the observed lower bound. Known
same-day intervals enter daily charts, and known same-hour intervals enter hourly
charts. Cross-day cumulative history is exposed separately as
`unattributedRemoteTokens`, rather than being shown as usage on the last day.
Same-day observations spanning several hours are included in the daily total,
and shown separately as `unattributedRemoteHourlyTokens` instead of being
assigned to an arbitrary hour.
An old thread can continue accumulating new observations without requiring that
it was created within the chart's 30-day period. Offline observations remain
cached; unknown or unavailable remote data must not be described as complete
zero usage.
