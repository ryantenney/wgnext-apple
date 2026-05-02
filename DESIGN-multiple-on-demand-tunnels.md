# Multiple On-Demand Tunnels for WireGuard iOS/macOS

## Problem Statement

Today, only one tunnel can be "active" at any moment, where "active" includes any of:

- Currently connected
- Currently connecting / reasserting / restarting
- Configured with `isOnDemandEnabled = true` and matching rules (the OS will activate it on its own)

When the user starts a different tunnel, `TunnelsManager.startActivation` permanently flips `isOnDemandEnabled = false` on whatever tunnel was previously holding the on-demand slot — destroying the user's configured intent. The user has to manually re-enable on-demand later.

The user has two related needs that this single-slot model can't express:

1. **Manual override.** "I keep `home-one` set to on-demand. I want to briefly switch to `proton-vpn` to bypass it, then have `home-one` resume on-demand the moment I disable `proton-vpn` — without me having to remember to re-enable on-demand."
2. **Multiple independent on-demand configurations.** "I want `home-one` to be on-demand on my home Wi-Fi, and `road-warrior` to be on-demand on cellular, simultaneously configured. Whichever one matches the current network conditions should be the one that runs."

These are split into two delivery phases, both covered by this document:

- **F1 — Override-and-restore** (shipping in this branch)
- **F2 — Multiple independent on-demand** (planned, scoped here)

## Today's Behavior

`TunnelsManager.startActivation(of:)` (`Sources/WireGuardApp/Tunnel/TunnelsManager.swift:632`) gates new activations behind:

```
if let tunnelInOperation = allTunnels.first(where: { $0.status != .inactive }) {
    tunnel.status = .waiting
    if tunnelInOperation.isActivateOnDemandEnabled {
        setOnDemandEnabled(false, on: tunnelInOperation) { ... startDeactivation(...) }
    } else {
        startDeactivation(of: tunnelInOperation)
    }
}
```

The `setOnDemandEnabled(false, ...)` call writes through to the system via `NETunnelProviderManager.saveToPreferences()` and the change is permanent. There is no record that the displaced tunnel was ever an on-demand tunnel; once the user is done with the override, they must remember to re-enable on-demand by hand.

The reason on-demand has to be disabled at the system level (rather than just "stop the session") is that the OS treats `isOnDemandEnabled = true` as continuous: as soon as the matching rules apply, the OS will start the tunnel back up, fighting any deactivation. We can't keep it enabled while another tunnel runs as override.

## Goals & Non-Goals

### Goals

- F1: Preserve the user's on-demand intent across a manual override. The override "owns" the VPN slot only as long as it's active.
- F1: Restore on-demand automatically when the override goes inactive — including across app restarts and device reboots.
- F2: Allow multiple tunnels to be configured with on-demand simultaneously, with predictable rules for which one wins.
- F2: Don't regress existing single-tunnel users; the new behavior should be opt-in or transparently equivalent for users with one on-demand tunnel.

### Non-Goals

- Running more than one VPN session simultaneously. The OS allows exactly one `NEPacketTunnelProvider` to be connected at a time, and we don't try to work around that.
- Replacing the failover group / TiT group features. Those are about a single `NETunnelProviderManager` containing multiple configurations and choosing among them inside the extension. This document is about the orthogonal question of "which manager should be active right now."
- Changing how on-demand rules are configured. We continue to use `NEOnDemandRule*` from `ActivateOnDemandOption`.

## F1 — Override-and-Restore

### Model

There is at most one tunnel in the "on-demand suspended" state at a time, identified by tunnel name. State persists in the shared app-group `UserDefaults` so it survives app restart, device reboot, and extension restart.

A tunnel is **suspended** when:
- Another tunnel is being manually activated, and
- The displaced tunnel had `isActivateOnDemandEnabled == true` at the time of displacement.

A suspension is **cleared** by any of:
- The user toggles on-demand on the suspended tunnel (`setOnDemandEnabled` either direction). The user took explicit control; we no longer track it.
- The user removes the suspended tunnel.
- A **restore** event runs.

A **restore** runs when the system observes that no tunnel is in any non-`inactive` state and there is at least one suspended tunnel. The restore re-applies `isOnDemandEnabled = true` to each suspended tunnel (whose on-demand rules are still configured) and clears the suspension marker. From there, the OS resumes its normal on-demand evaluation.

### Persistence

`OnDemandSuspensionStore` (new, in `Sources/WireGuardApp/Tunnel/`) wraps the same app-group `UserDefaults` used by `RecentTunnelsTracker` and `IPDiscoverySettings`. It stores a single key, `suspendedOnDemandTunnelNames`, as a `[String]`.

Tunnel names are mutable. As with `RecentTunnelsTracker`, we update the store on rename (`handleTunnelRenamed(oldName:newName:)`) and remove (`handleTunnelRemoved(tunnelName:)`).

We don't persist the original `ActivateOnDemandOption` — we don't change `tunnelProviderManager.onDemandRules` during suspension, only `isOnDemandEnabled`. Restoring is therefore just flipping the bit back on.

### Lifecycle

```
1. Tunnel A: hasOnDemandRules=true, isOnDemandEnabled=true, currently .active (per OS)
2. User toggles tunnel B on.
   - TunnelsManager.startActivation(of: B) sees A in operation.
   - Adds A.name to OnDemandSuspensionStore.
   - Calls setOnDemandEnabled(false, on: A) → A: isOnDemandEnabled=false.
   - Calls startDeactivation(of: A) → A: .deactivating → .inactive.
   - On A.inactive observer: starts B → B: .activating → .active.
3. User toggles tunnel B off.
   - TunnelsManager.startDeactivation(of: B) → B: .inactive.
   - statusObservation sees zero non-inactive tunnels and a non-empty suspension store.
   - Calls restoreSuspendedOnDemand():
       - For A.name in store: setOnDemandEnabled(true, on: A) if A still has rules.
       - Clears store.
   - OS sees A.isOnDemandEnabled=true and rules match → activates A.
```

### Edge Cases

| Situation | Behavior |
|-----------|----------|
| App killed mid-override; user later re-launches and override is still running | TunnelsManager loads tunnels, sees override still `.active`, leaves suspension intact. Restore happens on the next deactivation. |
| Device reboot with suspension persisted | All tunnels start `.inactive`. On TunnelsManager init, restore runs immediately (no tunnels active, suspension non-empty). |
| User edits the suspended tunnel's config (`modify`) while suspended | `modify()` saves with `isOnDemandEnabled=false` (current system state). Suspension remains; restore still flips it back. |
| User toggles on-demand on the suspended tunnel via UI while override runs | The user took control; we clear suspension. No automatic restore later. |
| User deletes the suspended tunnel | `remove()` clears suspension. |
| User renames the suspended tunnel | `modify()`'s rename path updates the store key. |
| Suspension target no longer has on-demand rules at restore time | Skip the bit-flip for that name (still clear the marker). |
| Multiple names in the store (shouldn't happen with current single-slot OS, but defensive) | Restore each. The OS will resolve which actually runs. |

### What This Does Not Do

- Doesn't introduce any UI to indicate "suspended". The on-demand toggle on the suspended tunnel just shows "off" because at the system level, it is off. F2 introduces explicit UI for this.
- Doesn't reorder or re-evaluate which tunnel "should" be on-demand based on current network conditions; that's F2.

## F2 — Multiple Independent On-Demand Configurations

### Why It's Hard

The OS-level constraint is sticky: when more than one `NETunnelProviderManager` has `isOnDemandEnabled = true` with rules that all match the current conditions, the OS does not consistently pick one — empirically it can flap between them or deactivate them in sequence. The existing code treats "only one tunnel has `isOnDemandEnabled = true` at a time" as an invariant precisely because of this.

We preserve that invariant, but make it computed from a higher-level intent rather than a hand-toggle.

### Approach: App-Side Rule Evaluator with a Single System "Winner"

Each tunnel carries its own rule set and an `onDemandIntent: Bool` (the user's "I want this on-demand" toggle, decoupled from the system-level `isOnDemandEnabled`). The app — specifically `OnDemandCoordinator`, a new component owned by `TunnelsManager` — picks one tunnel as the **winner**:

- Iterate tunnels in priority order (defined below).
- For each, evaluate its rules against the current `NWPathMonitor` snapshot (interface type, SSID, etc.).
- The first tunnel whose rules say "connect" under the current conditions is the winner.
- The winner gets `isOnDemandEnabled = true` at the system level. All others get `isOnDemandEnabled = false`.
- If no tunnel's rules match, no system-level on-demand is active. The user can still manually start any tunnel.

The OS continues to do its normal job for the winner; the app's role is solely to choose who that winner is.

### When to Re-Evaluate

| Trigger | Source |
|---------|--------|
| App launch (TunnelsManager init) | Self |
| Network path change | `NWPathMonitor` (already used in `WireGuardAdapter` — extended to a shared `NetworkPathObserver` accessible from the app process) |
| User changes a tunnel's rules, intent, or priority | `modify()` / settings UI |
| Override starts / ends (F1) | `OnDemandSuspensionStore` |
| Tunnel added / removed | `add()` / `remove()` |

Re-evaluation is debounced (~500ms) to absorb the noise from rapid path changes during interface transitions.

### Priority & Tiebreakers

User-controlled priority is required because two tunnels might both match (e.g., one says "any Wi-Fi", another says "specific SSID"). Specific should win.

Priority sources, in order:

1. **User-assigned priority** — a per-tunnel integer in tunnel settings, lower number = higher priority. UI exposes drag-to-reorder in a new "On-Demand Priority" list.
2. **Rule specificity heuristic** (only if priorities are equal) — `wiFiInterfaceOnly(.onlySpecificSSIDs)` > `wiFiInterfaceOnly(.exceptSpecificSSIDs)` > `wiFiInterfaceOnly(.anySSID)` > `nonWiFiInterfaceOnly` > `anyInterface(.onlySpecificSSIDs)` > `anyInterface(.exceptSpecificSSIDs)` > `anyInterface(.anySSID)`.
3. **Tunnel name** (lexicographic, case-insensitive) — final deterministic tiebreaker.

### Coexistence with Override (F1)

F1 and F2 compose cleanly:

- When an override starts, the **current winner** is moved into the suspension store and its `isOnDemandEnabled` flipped to false. The override runs.
- While the override is running, the coordinator does **not** re-elect a new winner. The override "owns" the slot.
- When the override stops, the coordinator re-runs. The previously suspended tunnel may or may not still be the winner — if rules and conditions have changed, a different tunnel may take the slot. In either case, the suspension store is cleared.

Practically: F1's "suspension store" becomes the coordinator's "frozen winner" record. F1's restore step is replaced by a re-election in F2.

### Data Model Changes

```swift
// Per-tunnel, persisted in providerConfiguration:
"OnDemandIntent":   Bool       // user toggle, separate from isOnDemandEnabled
"OnDemandPriority": Int        // lower = higher priority

// Existing isOnDemandEnabled becomes app-managed: written by OnDemandCoordinator,
// not by user-facing UI. UI binds to OnDemandIntent instead.
```

`onDemandRules` continue to live where they do today (on `NETunnelProviderManager`).

### State Machine

```
                     ┌──────────────────────────────────┐
                     │  No on-demand intent on any      │
        ┌──────────► │  tunnel — coordinator idle.      │
        │            └──────────────────────────────────┘
        │                          │
        │ user enables intent      │
        │ on some tunnel           ▼
        │            ┌──────────────────────────────────┐
        │            │  Coordinator running.            │
        │            │  Evaluates on every trigger;     │
        │            │  flips one isOnDemandEnabled bit │◄─┐
        │            │  to match the winner.            │  │ network change,
        │            └──────────────────────────────────┘  │ rule edit, etc.
        │                          │                        │
        │ user disables intent     │ override starts        │
        │ on all tunnels           ▼                        │
        │            ┌──────────────────────────────────┐  │
        │            │  Coordinator suspended.          │  │
        │            │  Records winner in suspension    │  │
        │            │  store. Override runs.           │  │
        │            └──────────────────────────────────┘  │
        │                          │                        │
        │                          │ override stops         │
        │                          ▼                        │
        │            ┌──────────────────────────────────┐  │
        │            │  Re-election. Clear suspension. ─┼──┘
        │            └──────────────────────────────────┘
```

### UI Implications

- **Tunnel detail view** — the on-demand toggle binds to `OnDemandIntent`, not `isActivateOnDemandEnabled`. A subtitle reads "Active" or "Standby" based on whether this tunnel is the current winner.
- **New "On-Demand" settings screen** — list of tunnels with `OnDemandIntent == true`, drag-to-reorder for priority, with the current winner annotated.
- **Tunnel list cell** — the existing on-demand badge becomes a two-state badge: "On-Demand (active)" for the winner, "On-Demand (standby)" for others with intent.

### Migration

The existing single-on-demand-tunnel state maps cleanly:

- For each existing tunnel where `isOnDemandEnabled == true`, set `OnDemandIntent = true` and `OnDemandPriority = 0`.
- For each existing tunnel where `isOnDemandEnabled == false` but `onDemandRules` are configured, leave `OnDemandIntent = false`.
- After migration, run the coordinator once. The result should match the user's existing state (since at most one tunnel had the intent).

Migration is idempotent and runs in `TunnelsManager.create()`.

## Approaches Considered

### Single shared `NETunnelProviderManager` with composite rules

Pack all tunnels' configs into one manager with concatenated rules, similar to failover groups. Inside the extension, dispatch to the right config based on rule matching.

**Rejected.** This is essentially "failover groups for arbitrary tunnels" and conflates two distinct features. The extension would need rule-match logic that mirrors what the OS already does. The user model also gets confusing: "is my home-one tunnel a separate tunnel or part of a meta-tunnel?"

### Multiple `isOnDemandEnabled = true` simultaneously

Just trust the OS to pick. We've tried this — the behavior is inconsistent across iOS/macOS versions and produces flap. The existing comment-laden code in `startActivation` exists for a reason.

**Rejected.** The OS doesn't expose tiebreaking and we have no way to influence it.

### Background coordinator inside the Network Extension

Run the coordinator inside the extension process so it survives app death.

**Rejected for now.** When the coordinator's job is "elect a winner and flip `isOnDemandEnabled`", it has to call `NETunnelProviderManager.saveToPreferences()` — and that API is only reliably available in the app process. Also: the coordinator needs to re-elect on user actions (rule edits, intent toggles), which originate in the app. Keeping it app-side avoids IPC complexity.

The coordinator runs whenever the app is alive. When the app is dead, the OS runs whichever tunnel was the last winner, which is the correct behavior — the user's most recent configuration wins until they next change it.

## Files (planned)

### F1 (this branch)

| File | Purpose |
|------|---------|
| `Sources/WireGuardApp/Tunnel/OnDemandSuspensionStore.swift` | New. App-group `UserDefaults`-backed suspension set. |
| `Sources/WireGuardApp/Tunnel/TunnelsManager.swift` | Modified. Mark/clear suspensions; restore when no tunnels active; rename/remove hooks. |

### F2 (future)

| File | Purpose |
|------|---------|
| `Sources/WireGuardApp/Tunnel/OnDemandCoordinator.swift` | New. Rule evaluator, winner election, debounced re-eval. |
| `Sources/WireGuardApp/Tunnel/NetworkPathObserver.swift` | New. App-side `NWPathMonitor` wrapper, shared by coordinator. |
| `Sources/WireGuardApp/Tunnel/TunnelsManager.swift` | Modified. Owns the coordinator, calls it on lifecycle events. |
| `Sources/WireGuardApp/Tunnel/ActivateOnDemandOption.swift` | Modified. Adds `evaluate(against:) -> RuleVerdict` for app-side rule matching. |
| `Sources/WireGuardApp/UI/iOS/ViewController/OnDemandPriorityViewController.swift` | New. Drag-to-reorder priority list. |
| `Sources/WireGuardApp/UI/iOS/View/TunnelListCell.swift` | Modified. Two-state on-demand badge. |
| `Sources/WireGuardApp/UI/iOS/ViewController/TunnelDetailTableViewController.swift` | Modified. Bind on-demand toggle to `OnDemandIntent`; show winner status. |
| `Sources/WireGuardApp/UI/macOS/...` | Mirror the iOS changes. |

## Open Questions for F2

- Should the priority list also include tunnels without on-demand intent (so adding intent later remembers their position), or only the ones with intent?
- Do we want a "fallback" priority where a tunnel becomes the winner only if no higher-priority tunnel has matching rules? (Today's design already does this implicitly — a tunnel without matching rules is skipped.)
- How do we surface "winner changed because network changed" to the user? A transient banner in the tunnel list, or just the cell badges?
- Failover groups already do their own internal switching. Should a failover group participate in coordinator election as a single unit (yes — it appears as one `NETunnelProviderManager` already), or should its constituent tunnels be visible to the coordinator? (Current answer: the group is one unit. The coordinator doesn't see inside.)
