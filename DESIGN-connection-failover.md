# Connection Failover Design

## Problem Statement

A user has two home internet connections, each running its own WireGuard server with **different keys** (different private keys, different peer public keys, different endpoints). One connection has poor upload speed and should only be used when the primary is unavailable. Today, switching between tunnels requires manual intervention: deactivate one, activate the other.

## Key Discovery: In-Place Configuration Swap

`WireGuardAdapter.update()` (line 241 of `WireGuardAdapter.swift`) can **hot-swap the entire tunnel configuration** on a running tunnel — including:
- Interface private key
- All peers (public keys, endpoints, allowed IPs, preshared keys)
- Network settings (IP addresses, DNS, routes via `setTunnelNetworkSettings()`)

It does this by:
1. Setting `packetTunnelProvider.reasserting = true`
2. Calling `setTunnelNetworkSettings()` with new `NEPacketTunnelNetworkSettings`
3. Calling `wgSetConfig()` with new UAPI config (`private_key=...`, `replace_peers=true`, ...)
4. Setting `packetTunnelProvider.reasserting = false`

From the OS perspective, the VPN stays "connected" — it just briefly enters "reasserting" state. **No tunnel teardown/rebuild. No connectivity gap visible to the user.** This makes tunnel-level failover nearly seamless.

## Constraints

### OS-Level
- **One active VPN tunnel at a time** (iOS/macOS system constraint). But with in-place config swap, we never need a second tunnel — we reuse the one active tunnel.
- **Network Extension runs as a separate process** and stays alive while the VPN is active, even if the app is killed. Health monitoring must live here.
- **The app may not be running.** On iOS, the app is frequently suspended. The extension is the only reliable place for failover logic.

### WireGuard Protocol
- No built-in connection health signal. Only observable metric: **`last_handshake_time`** via UAPI `wgGetConfig()`.
- **`persistent_keepalive`** must be enabled for reliable health monitoring. Without it, handshakes only occur when there's traffic, making stale handshake times unreliable.
- Different tunnel configs means different private keys → different WireGuard identities. This is a full config swap, not just an endpoint change.

### Existing Infrastructure Leveraged
- `WireGuardAdapter.update()` — hot-swap entire config (**the linchpin**)
- `WireGuardAdapter.getRuntimeConfiguration()` — query `last_handshake_time`
- `NWPathMonitor` in adapter — already detects network changes
- `PacketTunnelProvider.handleAppMessage()` — IPC for status/control
- `NETunnelProviderProtocol.providerConfiguration` — dict for passing extra data to extension
- `Keychain` — stores wg-quick configs, can store multiple

## Approach Comparison

### Option A: App-Level Tunnel Switching (TunnelsManager)
Deactivate one `NETunnelProviderManager`, activate another.

**Rejected**: 1-5s downtime per switch. App must be running. `NETunnelProviderManager` save/load cycle is slow.

### Option B: Per-Peer Endpoint Failover (same keys, different IPs)
Add fallback endpoints to each peer. Switch endpoints via `wgSetConfig()`.

**Rejected for this use case**: Only works when the same WireGuard server is reachable at multiple IPs. Doesn't apply when servers have different keys.

### Option C: Tunnel-Level Failover via In-Place Config Swap **[RECOMMENDED]**
Pass multiple full tunnel configurations to the Network Extension. Monitor health. On failure, call `adapter.update()` to hot-swap the entire WireGuard config — different private key, different peer, different endpoint — without tearing down the OS-level tunnel.

**Why this wins**:
- Matches the user's mental model: "I have tunnels in priority order, fail between them"
- Near-instant failover (no tunnel restart)
- Runs entirely in the Network Extension (works when app is killed)
- Each tunnel config is a standard wg-quick config (no custom extensions)
- Leverages existing `adapter.update()` infrastructure

## Detailed Design (Option C)

### Data Flow

```
┌─────────────────────────────────────────────┐
│                    App Process               │
│                                              │
│  ┌──────────────┐    ┌───────────────────┐   │
│  │TunnelsManager│    │ Failover Group UI │   │
│  │              │    │ [HomeOne] primary  │   │
│  │              │    │ [HomeTwo] fallback │   │
│  └──────┬───────┘    └───────────────────┘   │
│         │                                     │
│         │  Packs all configs into             │
│         │  providerConfiguration              │
└─────────┼─────────────────────────────────────┘
          │
          │  startTunnel(options:)
          ▼
┌─────────────────────────────────────────────┐
│             Network Extension Process        │
│                                              │
│  ┌─────────────────────┐                     │
│  │ PacketTunnelProvider │                     │
│  │                     │                     │
│  │  configs[0] ────────┼──► adapter.start()  │
│  │  configs[1..n]      │    (primary)        │
│  │                     │                     │
│  │  ┌─────────────────┐│                     │
│  │  │HealthMonitor    ││                     │
│  │  │                 ││                     │
│  │  │ every 30s:      ││                     │
│  │  │  wgGetConfig()  ││                     │
│  │  │  check handshake││                     │
│  │  │                 ││                     │
│  │  │ if stale:       ││                     │
│  │  │  adapter.update ││  ← full config swap │
│  │  │  (configs[1])   ││    new keys, peers, │
│  │  │                 ││    endpoint, etc.    │
│  │  └─────────────────┘│                     │
│  └─────────────────────┘                     │
└─────────────────────────────────────────────┘
```

### 1. Failover Group Model

#### FailoverGroup (NEW: Sources/WireGuardApp/Tunnel/FailoverGroup.swift)
```swift
struct FailoverGroup: Codable, Equatable, Identifiable {
    /// Unique identifier
    var id: UUID = UUID()

    /// Display name (e.g., "Home Failover")
    var name: String

    /// Ordered tunnel names. Index 0 = primary, rest = fallbacks by priority.
    var tunnelNames: [String]

    /// Failover behavior settings
    var settings: FailoverSettings = FailoverSettings()
}

struct FailoverSettings: Codable, Equatable {
    /// Seconds without handshake before declaring connection unhealthy.
    /// Should be > 2x persistentKeepAlive. Default: 180s.
    var handshakeTimeout: TimeInterval = 180

    /// How often to poll handshake freshness. Default: 30s.
    var healthCheckInterval: TimeInterval = 30

    /// How often to probe higher-priority configs when on a fallback. Default: 300s.
    var failbackProbeInterval: TimeInterval = 300

    /// Automatically try to return to higher-priority configs. Default: true.
    var autoFailback: Bool = true
}
```

Persisted as JSON in shared `UserDefaults` (app group container accessible by both app and extension).

### 2. Passing Configs to the Network Extension

When activating a failover group, `TunnelsManager` loads ALL referenced tunnel configs and packs them into `providerConfiguration`:

```swift
extension TunnelsManager {
    func startActivation(ofFailoverGroup group: FailoverGroup) {
        // Load all referenced tunnel configs from Keychain
        let configs: [String] = group.tunnelNames.compactMap { name in
            tunnel(named: name)?.tunnelConfiguration?.asWgQuickConfig()
        }
        guard !configs.isEmpty else { return }
        guard let primaryTunnel = tunnel(named: group.tunnelNames[0]) else { return }

        // Pack into providerConfiguration
        let tunnelProvider = primaryTunnel.tunnelProvider
        var providerConfig: [String: Any] = [:]
        #if os(macOS)
        providerConfig["UID"] = getuid()
        #endif
        providerConfig["FailoverConfigs"] = configs
        providerConfig["FailoverSettings"] = try? JSONEncoder().encode(group.settings)
        providerConfig["FailoverConfigNames"] = group.tunnelNames

        (tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration = providerConfig

        tunnelProvider.saveToPreferences { [weak self] error in
            guard error == nil, let self = self else { return }
            self.startActivation(of: primaryTunnel)
        }
    }
}
```

The extension reads these in `startTunnel()`. Each config string is a full wg-quick config that can be parsed independently.

### 3. PacketTunnelProvider Changes

```swift
class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter: WireGuardAdapter = { ... }()

    // NEW: Failover state
    private var healthMonitor: ConnectionHealthMonitor?
    private var failoverConfigs: [TunnelConfiguration] = []
    private var failoverConfigNames: [String] = []
    private var activeConfigIndex: Int = 0

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        // ... existing logging/error notifier setup ...

        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else { ... }
        let providerConfig = proto.providerConfiguration

        // Load failover configs if present
        if let configStrings = providerConfig?["FailoverConfigs"] as? [String] {
            failoverConfigs = configStrings.enumerated().compactMap { index, str in
                let name = (providerConfig?["FailoverConfigNames"] as? [String])?[safe: index]
                return try? TunnelConfiguration(fromWgQuickConfig: str, called: name)
            }
            failoverConfigNames = providerConfig?["FailoverConfigNames"] as? [String] ?? []
        }

        // Use first failover config as primary, or fall back to normal config loading
        let tunnelConfig: TunnelConfiguration
        if let primary = failoverConfigs.first {
            tunnelConfig = primary
        } else {
            guard let config = proto.asTunnelConfiguration() else {
                completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
                return
            }
            tunnelConfig = config
        }

        adapter.start(tunnelConfiguration: tunnelConfig) { adapterError in
            guard adapterError == nil else {
                // ... existing error handling ...
                return
            }
            completionHandler(nil)

            // Start health monitoring if we have fallback configs
            if self.failoverConfigs.count > 1 {
                self.startHealthMonitor(providerConfig: providerConfig)
            }
        }
    }

    private func startHealthMonitor(providerConfig: [String: Any]?) {
        var settings = FailoverSettings()
        if let data = providerConfig?["FailoverSettings"] as? Data {
            settings = (try? JSONDecoder().decode(FailoverSettings.self, from: data))
                ?? FailoverSettings()
        }

        healthMonitor = ConnectionHealthMonitor(
            adapter: adapter,
            configurations: failoverConfigs,
            settings: settings
        ) { [weak self] newIndex, configName in
            self?.activeConfigIndex = newIndex
            wg_log(.info, message: "Failover: switched to '\(configName)' (config #\(newIndex))")
        }
        healthMonitor?.start()
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        healthMonitor?.stop()
        healthMonitor = nil
        // ... existing stop logic ...
    }

    override func handleAppMessage(_ messageData: Data,
                                   completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler = completionHandler else { return }

        if messageData.count == 1 && messageData[0] == 0 {
            // Existing: get runtime config
            adapter.getRuntimeConfiguration { settings in
                completionHandler(settings?.data(using: .utf8))
            }
        } else if messageData.count == 1 && messageData[0] == 1 {
            // NEW: get failover state
            let state: [String: Any] = [
                "activeIndex": activeConfigIndex,
                "activeConfig": failoverConfigNames[safe: activeConfigIndex] ?? "unknown",
                "totalConfigs": failoverConfigs.count,
                "configNames": failoverConfigNames
            ]
            completionHandler(try? JSONSerialization.data(withJSONObject: state))
        } else {
            completionHandler(nil)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

### 4. ConnectionHealthMonitor

```swift
/// Monitors WireGuard handshake health and triggers failover between
/// tunnel configurations when the active connection becomes unhealthy.
class ConnectionHealthMonitor {
    private let adapter: WireGuardAdapter
    private let configurations: [TunnelConfiguration]
    private let settings: FailoverSettings
    private let onConfigSwitch: (Int, String) -> Void

    private var activeIndex: Int = 0
    private var healthCheckTimer: DispatchSourceTimer?
    private var failbackTimer: DispatchSourceTimer?
    private let workQueue = DispatchQueue(label: "WireGuardFailoverMonitor")

    // Anti-flap: prevent rapid cycling
    private var lastSwitchTime: Date = .distantPast
    private let minimumHoldTime: TimeInterval = 60
    private var consecutiveCycles: Int = 0
    private let maxCyclesBeforeCooldown: Int = 3
    private let cooldownDuration: TimeInterval = 300

    init(adapter: WireGuardAdapter,
         configurations: [TunnelConfiguration],
         settings: FailoverSettings,
         onConfigSwitch: @escaping (Int, String) -> Void) {
        self.adapter = adapter
        self.configurations = configurations
        self.settings = settings
        self.onConfigSwitch = onConfigSwitch
    }

    func start() {
        startHealthCheckTimer()
        if settings.autoFailback {
            startFailbackTimer()
        }
    }

    func stop() {
        healthCheckTimer?.cancel()
        healthCheckTimer = nil
        failbackTimer?.cancel()
        failbackTimer = nil
    }

    // MARK: - Health Checking

    private func startHealthCheckTimer() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(
            deadline: .now() + settings.healthCheckInterval,
            repeating: settings.healthCheckInterval
        )
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        timer.resume()
        healthCheckTimer = timer
    }

    private func checkHealth() {
        adapter.getRuntimeConfiguration { [weak self] configString in
            guard let self = self, let configString = configString else { return }
            self.workQueue.async {
                self.evaluateHealth(runtimeConfig: configString)
            }
        }
    }

    private func evaluateHealth(runtimeConfig: String) {
        let handshakeAge = parseLastHandshakeAge(from: runtimeConfig)

        guard handshakeAge > settings.handshakeTimeout else {
            // Healthy — reset cycle counter
            consecutiveCycles = 0
            return
        }

        // Unhealthy — check anti-flap guards
        let timeSinceLastSwitch = Date().timeIntervalSince(lastSwitchTime)
        guard timeSinceLastSwitch > minimumHoldTime else { return }

        if consecutiveCycles >= maxCyclesBeforeCooldown {
            guard timeSinceLastSwitch > cooldownDuration else {
                wg_log(.verbose, message: "Failover: in cooldown after \(consecutiveCycles) cycles")
                return
            }
            consecutiveCycles = 0
        }

        // Try next config
        let nextIndex = (activeIndex + 1) % configurations.count
        wg_log(.info, message: "Failover: handshake stale (\(Int(handshakeAge))s > \(Int(settings.handshakeTimeout))s), switching to config #\(nextIndex) '\(configurations[nextIndex].name ?? "unnamed")'")
        switchToConfig(at: nextIndex)
    }

    // MARK: - Config Switching (via adapter.update)

    private func switchToConfig(at index: Int) {
        let config = configurations[index]
        adapter.update(tunnelConfiguration: config) { [weak self] error in
            guard let self = self else { return }
            self.workQueue.async {
                if let error = error {
                    wg_log(.error, message: "Failover: switch to config #\(index) failed: \(error)")
                    // Try next config in line
                    let nextNext = (index + 1) % self.configurations.count
                    if nextNext != self.activeIndex {
                        self.switchToConfig(at: nextNext)
                    }
                } else {
                    self.activeIndex = index
                    self.lastSwitchTime = Date()
                    self.consecutiveCycles += 1
                    self.onConfigSwitch(index, config.name ?? "unnamed")
                }
            }
        }
    }

    // MARK: - Failback Probing

    private func startFailbackTimer() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(
            deadline: .now() + settings.failbackProbeInterval,
            repeating: settings.failbackProbeInterval
        )
        timer.setEventHandler { [weak self] in self?.probeFailback() }
        timer.resume()
        failbackTimer = timer
    }

    private func probeFailback() {
        guard activeIndex != 0 else { return } // Already on primary

        let savedIndex = activeIndex
        wg_log(.info, message: "Failover: probing primary '\(configurations[0].name ?? "unnamed")' for recovery")

        // Switch to primary
        adapter.update(tunnelConfiguration: configurations[0]) { [weak self] error in
            guard let self = self, error == nil else { return }

            // Wait for a handshake attempt (keepalive interval + margin)
            self.workQueue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self = self else { return }

                self.adapter.getRuntimeConfiguration { [weak self] configString in
                    guard let self = self, let configString = configString else { return }
                    self.workQueue.async {
                        let handshakeAge = self.parseLastHandshakeAge(from: configString)
                        if handshakeAge < self.settings.handshakeTimeout {
                            wg_log(.info, message: "Failover: primary recovered! Staying on primary.")
                            self.activeIndex = 0
                            self.lastSwitchTime = Date()
                            self.consecutiveCycles = 0
                            self.onConfigSwitch(0, self.configurations[0].name ?? "unnamed")
                        } else {
                            wg_log(.info, message: "Failover: primary still unhealthy, reverting to config #\(savedIndex)")
                            self.adapter.update(tunnelConfiguration: self.configurations[savedIndex]) { _ in }
                        }
                    }
                }
            }
        }
    }

    // MARK: - UAPI Parsing

    private func parseLastHandshakeAge(from uapiConfig: String) -> TimeInterval {
        for line in uapiConfig.split(separator: "\n") {
            if line.hasPrefix("last_handshake_time_sec=") {
                let value = line.dropFirst("last_handshake_time_sec=".count)
                if let timestamp = TimeInterval(value), timestamp > 0 {
                    return Date().timeIntervalSince1970 - timestamp
                }
            }
        }
        return .infinity // No handshake ever
    }
}
```

### 5. UI Design

#### Tunnel List (matching user's existing iOS view)
```
┌────────────────────────────────────┐
│ WireGuard               +  Import  │
├────────────────────────────────────┤
│                                    │
│  FAILOVER GROUPS                   │
│  ┌────────────────────────────────┐│
│  │ Home Failover            [On] ││
│  │   ├─ HomeOne (active)    ✓    ││
│  │   └─ HomeTwo (standby)        ││
│  └────────────────────────────────┘│
│                                    │
│  TUNNELS                           │
│  ┌────────────────────────────────┐│
│  │   HomeOne                      ││
│  │   HomeOne+VPN                  ││
│  │   HomeTwo                      ││
│  └────────────────────────────────┘│
└────────────────────────────────────┘
```

- The toggle activates the group (starts primary, arms failover)
- Checkmark shows which config is currently active
- Activating any individual tunnel implicitly deactivates any active group
- When the extension switches configs, the app queries failover state via IPC (message byte `0x01`) and updates the UI

#### Failover Group Edit Screen
```
┌────────────────────────────────────┐
│ ◁ Back         Edit Group    Save  │
├────────────────────────────────────┤
│ Name: [Home Failover           ]   │
│                                    │
│ CONNECTIONS (drag to reorder)      │
│  1. HomeOne              Primary   │
│  2. HomeTwo              Fallback  │
│  [+ Add Tunnel]                    │
│                                    │
│ FAILOVER SETTINGS                  │
│ Handshake Timeout    [  180] sec   │
│ Health Check Every   [   30] sec   │
│ Failback Probe Every [  300] sec   │
│ Auto Failback        [  ON]        │
│                                    │
│ ⓘ PersistentKeepalive must be     │
│   enabled on all tunnels for       │
│   reliable failure detection.      │
└────────────────────────────────────┘
```

### 6. Failover State Machine

```
                    ┌──────────┐
      activate      │ PRIMARY  │◄──── failback probe succeeds
      group         │ ACTIVE   │
      ──────────►   └────┬─────┘
                         │
                  handshake stale
                  (age > timeout)
                         │
                         ▼
                    ┌──────────┐
                    │ SWITCHING│  adapter.update(fallback)
                    └────┬─────┘
                         │
                  update() succeeds
                         │
                         ▼
                    ┌──────────┐
   failback probe   │ FALLBACK │  ──── if also stale,
   every N sec ──►  │ ACTIVE   │       try next config
                    └────┬─────┘
                         │
                  probe primary
                         │
                    ┌────┴─────┐
              ┌─────┤ PROBING  ├─────┐
              │     │ PRIMARY  │     │
              │     └──────────┘     │
        handshake               handshake
        within timeout          still stale
              │                      │
              ▼                      ▼
        ┌──────────┐          ┌──────────┐
        │ PRIMARY  │          │ FALLBACK │
        │ ACTIVE   │          │ ACTIVE   │  (revert)
        └──────────┘          └──────────┘
```

## Implementation Plan

### Phase 1: Health Monitor Core
1. Add `ConnectionHealthMonitor` class to `Sources/WireGuardKit/`
2. Add `FailoverSettings` struct (Codable)
3. Test handshake time parsing from UAPI output
4. Wire start/stop into `WireGuardAdapter`

### Phase 2: Multi-Config in Network Extension
5. Extend `PacketTunnelProvider` to read `FailoverConfigs` from `providerConfiguration`
6. Parse multiple wg-quick configs in extension
7. Start health monitor when failover configs present
8. Trigger `adapter.update()` on health failure
9. Add failover state IPC (message byte `0x01`)

### Phase 3: Failover Group Data Model
10. Define `FailoverGroup` struct with persistence
11. Extend `TunnelsManager` with `startActivation(ofFailoverGroup:)`
12. Pack all configs into `providerConfiguration` on activation

### Phase 4: iOS UI
13. Add "Failover Groups" section to tunnel list
14. Create failover group create/edit view controller
15. Active config indicator via IPC polling
16. PersistentKeepalive validation warning

### Phase 5: macOS UI
17. Failover group support in sidebar/manage tunnels window
18. Status bar icon change when on fallback (yellow dot)

### Phase 6: Polish & Edge Cases
19. Anti-flap logic (minimum hold time, cycle counter, cooldown)
20. Handle all-configs-unhealthy (exponential backoff)
21. Handle DNS failures during failover
22. Pause health monitor during `NWPathMonitor` offline
23. Logging and diagnostics
24. Battery impact measurement

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| All configs unhealthy | Cycle through all, then exponential backoff (60s, 120s, 240s...). Stay on last-tried config. |
| Rapid cycling between configs | 60-second minimum hold time. After 3 full cycles, 5-minute cooldown. |
| Network goes offline entirely | `NWPathMonitor` triggers `temporaryShutdown` (existing). Health monitor effectively pauses — no `wgGetConfig()` possible. Resumes on network recovery. |
| App killed while on fallback | Extension keeps running. Failover state lives in extension process memory. App queries via IPC when foregrounded. |
| User manually activates different tunnel | Failover group implicitly deactivates. Normal tunnel activation takes over. |
| Failback probe disrupts traffic | ~15-second probe window. If primary is dead, reverts immediately. Brief disruption is acceptable since it means the faster connection may be back. |
| Config has no PersistentKeepalive | Warn in group edit UI. Without keepalive, `last_handshake_time` only updates when there's active traffic — making failure detection unreliable. |
| DNS resolution fails during switch | `adapter.update()` will fail with `.dnsResolution` error. Skip to next config. Retry on next health check. |
| Tunnel config deleted while in group | Group activation detects missing config and skips it. Warn user in UI. |
| Extension memory pressure | Health monitor is lightweight (one timer, one string parse). No significant memory footprint. |

## Battery and Performance

- **Health check**: One `wgGetConfig()` call every 30s — lightweight in-process C function call to Go backend. Returns a small string.
- **Failback probe**: One `adapter.update()` call every 5 minutes (only when on fallback). Involves DNS resolution + UAPI config push.
- **Net impact**: Negligible. The WireGuard tunnel itself and `persistent_keepalive` packets dominate power usage.

## Alternative Considered: DNS-Based Failover

Health-checked DNS (Route53, Cloudflare) where servers share a hostname. When primary goes down, DNS resolves to secondary.

**Why not**: DNS TTL causes slow failover (minutes). No client-side priority control. Doesn't work when servers have different keys. Requires server-side infrastructure.
