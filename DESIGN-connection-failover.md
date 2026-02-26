# Connection Failover Design

## Problem Statement

A user has two home internet connections, each with a WireGuard server configured. One connection has poor upload speed and should only be used when the primary is unavailable. Today, WireGuard for iOS/macOS has no built-in mechanism to automatically fail over between connections or fail back to the preferred one.

## Constraints

### OS-Level
- **iOS and macOS only allow one active VPN tunnel at a time.** The `NETunnelProviderManager` system enforces this. `TunnelsManager` also enforces it at the app level (queuing mechanism).
- **The Network Extension runs as a separate process** from the main app and continues to run when the app is backgrounded or killed. Any health monitoring must live here to be reliable.
- **The app process may not be running.** On iOS especially, the app is frequently suspended. Only the Network Extension is guaranteed to be running while the tunnel is active.

### WireGuard Protocol
- A single tunnel can have **multiple peers**, but each peer's `AllowedIPs` determines routing. Two peers with overlapping `AllowedIPs` (e.g., both `0.0.0.0/0`) is not a valid configuration.
- WireGuard has no built-in "connection health" concept. It is a stateless protocol at the transport layer. The only observable health signal is the **last handshake time** (available via UAPI `last_handshake_time_sec`).
- The `persistent_keepalive` interval (when configured) causes periodic handshakes, making `last_handshake_time` a reliable health indicator.

### Existing Infrastructure
- `WireGuardAdapter` already monitors network via `NWPathMonitor` and handles offline/online transitions
- `wgGetConfig()` returns runtime stats including `last_handshake_time` per peer
- `wgSetConfig()` can update a peer's endpoint without restarting the tunnel
- `PacketTunnelProvider.handleAppMessage()` provides IPC between app and extension

## Approach Options

### Option A: Tunnel-Level Failover (TunnelsManager)
**Concept**: Define failover groups of tunnel configs. Monitor active tunnel health in the app. Switch tunnels when health degrades.

**Pros**: No changes to WireGuardKit/Network Extension. Pure app-level logic.

**Cons**:
- Tunnel switching requires full deactivate/activate cycle (1-5 seconds of downtime)
- App may not be running on iOS (suspended/killed) - health monitoring stops
- Switching tunnels involves system VPN config changes (slow, requires preferences save)
- The `TunnelsManager` waiting/queuing mechanism makes this clunky

**Verdict**: Not recommended as primary approach. Too slow and unreliable on iOS.

### Option B: Peer Endpoint Failover (WireGuardAdapter) **[RECOMMENDED]**
**Concept**: Each peer has an ordered list of fallback endpoints. The adapter monitors handshake health in the Network Extension process and dynamically switches endpoints via `wgSetConfig()`.

**Pros**:
- No tunnel restart needed - endpoint switch via UAPI is near-instant
- Health monitoring runs in Network Extension (always alive while tunnel is up)
- Minimal data model changes (add `fallbackEndpoints` to `PeerConfiguration`)
- Clean separation: failover is transparent to the app layer
- Can fail back to primary when it recovers

**Cons**:
- Changes to WireGuardKit (the library layer) - affects downstream consumers
- Health monitoring adds CPU/battery overhead (mitigated by long polling intervals)
- Need to define "unhealthy" threshold carefully to avoid false positives

**Verdict**: Recommended. This is the most robust and lowest-latency approach.

### Option C: Hybrid (Endpoint Failover + App-Level Fallback)
**Concept**: Option B for same-peer multi-endpoint failover, plus Option A as a last resort when the entire tunnel configuration is broken.

**Verdict**: Good for later. Start with Option B, add Option A as enhancement.

## Detailed Design (Option B)

### 1. Data Model Changes

#### PeerConfiguration (Sources/WireGuardKit/PeerConfiguration.swift)
```swift
public struct PeerConfiguration {
    public var publicKey: PublicKey
    public var preSharedKey: PreSharedKey?
    public var allowedIPs = [IPAddressRange]()
    public var endpoint: Endpoint?
    public var persistentKeepAlive: UInt16?

    // NEW: Ordered list of fallback endpoints (index 0 = first fallback)
    public var fallbackEndpoints: [Endpoint] = []

    // Runtime stats (unchanged)
    public var rxBytes: UInt64?
    public var txBytes: UInt64?
    public var lastHandshakeTime: Date?
}
```

The primary endpoint remains in `endpoint`. `fallbackEndpoints` is an ordered list of alternatives. During failover, the adapter cycles through: `endpoint` -> `fallbackEndpoints[0]` -> `fallbackEndpoints[1]` -> ...

#### FailoverConfiguration (NEW: Sources/WireGuardKit/FailoverConfiguration.swift)
```swift
public struct FailoverConfiguration {
    /// How long without a handshake before considering endpoint unhealthy.
    /// Should be > 2x persistentKeepAlive to avoid false positives.
    /// Default: 180 seconds (3 minutes)
    public var handshakeTimeout: TimeInterval = 180

    /// How often to check handshake health while connected.
    /// Default: 30 seconds
    public var healthCheckInterval: TimeInterval = 30

    /// How often to attempt failback to the primary endpoint.
    /// Default: 300 seconds (5 minutes)
    public var failbackInterval: TimeInterval = 300

    /// Whether failover is enabled at all.
    public var isEnabled: Bool = false
}
```

#### TunnelConfiguration
```swift
public final class TunnelConfiguration {
    public var name: String?
    public var interface: InterfaceConfiguration
    public let peers: [PeerConfiguration]

    // NEW
    public var failoverConfiguration: FailoverConfiguration?
}
```

### 2. wg-quick Config Format Extension

To persist failover endpoints in the existing wg-quick config format, use a comment-based extension (preserves compatibility with standard wg-quick):

```ini
[Interface]
PrivateKey = ...
Address = 10.0.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = ...
AllowedIPs = 0.0.0.0/0
Endpoint = vpn-primary.example.com:51820
PersistentKeepalive = 25
# FailoverEndpoint = vpn-secondary.example.com:51820
# FailoverEndpoint = vpn-tertiary.example.com:51820
# FailoverHandshakeTimeout = 180
# FailoverHealthCheckInterval = 30
# FailoverFailbackInterval = 300
```

Parser changes in `TunnelConfiguration+WgQuickConfig.swift` to read these comments. Standard WireGuard tools will ignore them.

### 3. Health Monitor (NEW: Sources/WireGuardKit/ConnectionHealthMonitor.swift)

```swift
class ConnectionHealthMonitor {
    private let adapter: WireGuardAdapter  // weak?
    private let configuration: FailoverConfiguration
    private let peers: [PeerConfiguration]
    private var healthCheckTimer: DispatchSourceTimer?
    private var failbackTimer: DispatchSourceTimer?
    private var currentEndpointIndices: [PublicKey: Int]  // -1 = primary, 0..n = fallback index
    private let workQueue: DispatchQueue

    /// Start health monitoring
    func start()

    /// Stop health monitoring
    func stop()

    /// Called periodically to check peer handshake health
    private func checkHealth()

    /// Attempt to switch a peer to its next endpoint
    private func failover(peerIndex: Int)

    /// Attempt to switch a peer back to its primary endpoint
    private func failback(peerIndex: Int)
}
```

#### Health Check Logic (pseudocode)
```
every healthCheckInterval:
    runtimeConfig = wgGetConfig(handle)
    for each peer with failover enabled:
        timeSinceHandshake = now - peer.lastHandshakeTime
        if timeSinceHandshake > handshakeTimeout:
            if currentEndpoint is NOT last in fallback list:
                failover(peer)
            else:
                log("All endpoints exhausted for peer, cycling back to primary")
                reset to primary endpoint
```

#### Failover Action
```
failover(peerIndex):
    nextEndpointIndex = currentEndpointIndices[peer.publicKey] + 1
    nextEndpoint = resolveEndpoint(peer.fallbackEndpoints[nextEndpointIndex])

    wgSetConfig(handle, "public_key=<hex>\nendpoint=<resolved>\n")

    currentEndpointIndices[peer.publicKey] = nextEndpointIndex
    log("Failing over peer <key> to endpoint <endpoint>")
```

#### Failback Logic
```
every failbackInterval (only when NOT on primary):
    // Temporarily switch back to primary
    primaryEndpoint = resolve(peer.endpoint)
    wgSetConfig(handle, "public_key=<hex>\nendpoint=<primary>\n")

    // Wait for handshake attempt
    sleep(handshakeTimeout / 2)

    runtimeConfig = wgGetConfig(handle)
    if peer.lastHandshakeTime is recent:
        log("Primary endpoint recovered, staying on primary")
        currentEndpointIndices[peer.publicKey] = -1
    else:
        log("Primary still unhealthy, reverting to failover endpoint")
        wgSetConfig(handle, "public_key=<hex>\nendpoint=<failover>\n")
```

### 4. Integration Points

#### WireGuardAdapter Changes
```swift
public class WireGuardAdapter {
    // NEW
    private var healthMonitor: ConnectionHealthMonitor?

    public func start(tunnelConfiguration: TunnelConfiguration, ...) {
        // ... existing start logic ...
        if let failoverConfig = tunnelConfiguration.failoverConfiguration,
           failoverConfig.isEnabled {
            healthMonitor = ConnectionHealthMonitor(
                adapter: self,
                configuration: failoverConfig,
                peers: tunnelConfiguration.peers
            )
            healthMonitor?.start()
        }
    }

    public func stop(...) {
        healthMonitor?.stop()
        healthMonitor = nil
        // ... existing stop logic ...
    }

    // NEW: Internal method for health monitor to query config
    func getConfig(handle: Int32) -> String? { ... }

    // NEW: Internal method for health monitor to update endpoint
    func setConfig(handle: Int32, config: String) { ... }
}
```

#### PacketTunnelProvider IPC Extension
Add a new message type for the app to query/control failover state:

```swift
// Message byte 0x00 = get runtime config (existing)
// Message byte 0x01 = get failover state (NEW)
// Message byte 0x02 = force failover (NEW)
// Message byte 0x03 = force failback (NEW)
```

### 5. UI Changes

#### Tunnel Edit Screen
- Per-peer: Add "Failover Endpoints" section below Endpoint field
- Add/remove/reorder fallback endpoints
- Toggle: "Enable Connection Failover"
- Advanced settings: handshake timeout, health check interval, failback interval

#### Tunnel Detail Screen
- Show current active endpoint (primary vs. which fallback)
- Show time since last handshake per peer
- Show failover event history (optional)

#### Status Bar / Tunnel List
- Visual indicator when running on failover endpoint (e.g., yellow dot instead of green)

### 6. Implementation Plan

**Phase 1: Core Failover Engine (WireGuardKit)**
1. Add `fallbackEndpoints` to `PeerConfiguration`
2. Add `FailoverConfiguration` struct
3. Implement `ConnectionHealthMonitor`
4. Integrate health monitor into `WireGuardAdapter`
5. Update `PacketTunnelSettingsGenerator` to handle failover state
6. Update wg-quick parser/serializer for failover config comments

**Phase 2: Config Persistence & IPC**
7. Update `TunnelConfiguration+WgQuickConfig` for failover fields
8. Extend `PacketTunnelProvider.handleAppMessage()` for failover IPC
9. Add failover state reporting

**Phase 3: UI (iOS)**
10. Extend `TunnelEditTableViewController` for failover endpoint editing
11. Extend `TunnelDetailTableViewController` for failover status display
12. Extend `TunnelViewModel` for failover data binding

**Phase 4: UI (macOS)**
13. Extend `TunnelEditViewController` for failover endpoint editing
14. Extend `TunnelDetailTableViewController` for failover status display
15. Status bar icon changes for failover state

**Phase 5: Polish**
16. Logging and diagnostics for failover events
17. Edge case handling (all endpoints down, rapid cycling, DNS failures)
18. Battery impact testing and optimization

## Edge Cases and Mitigations

| Edge Case | Mitigation |
|-----------|------------|
| Both endpoints down | Cycle through all endpoints, then wait and retry. Don't burn battery in tight loop. Use exponential backoff. |
| Rapid failover cycling | Minimum hold time per endpoint (e.g., 60 seconds). After N cycles, enter cooldown. |
| DNS resolution failure during failover | Skip to next endpoint. If all DNS fails, use last-known-good resolved IP. |
| Network completely offline | Existing `NWPathMonitor` handles this - adapter enters `temporaryShutdown`. Health monitor pauses. |
| Failback probe disrupts active connection | Use a short probe window. If failback fails, immediately restore failover endpoint. Connection disruption is brief (< handshakeTimeout/2). |
| User manually switches endpoint | Reset failover state. Treat new manual endpoint as primary. |
| persistentKeepAlive not set | Handshake-based health monitoring is unreliable without keepalive. Warn user to enable it (>= 25s recommended). |
| Multiple peers with failover | Each peer has independent failover state. Health monitor checks all peers. |

## Battery and Performance Impact

- Health check timer: One `wgGetConfig()` call every 30 seconds (default). This is a lightweight in-process function call to the Go backend.
- Failback timer: One endpoint switch attempt every 5 minutes. Involves DNS resolution + `wgSetConfig()`.
- Estimated additional battery impact: Negligible. The WireGuard tunnel itself and persistent keepalives are the dominant power consumers.

## Alternative Considered: DNS-Based Failover

Instead of application-level failover, the user could use DNS-based failover (e.g., health-checked DNS with Route53 or Cloudflare) where both WireGuard servers share a hostname. When the primary goes down, DNS resolves to the secondary.

**Pros**: Zero client changes. Works with any WireGuard client.
**Cons**: DNS TTL causes slow failover (minutes). No control over failback priority. Requires server-side DNS infrastructure. Doesn't address the user's scenario of preferring one connection for performance reasons.
