/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2018-2023 WireGuard LLC. All Rights Reserved.
 */

#ifndef WIREGUARD_H
#define WIREGUARD_H

#include <sys/types.h>
#include <stdint.h>
#include <stdbool.h>

typedef void(*logger_fn_t)(void *context, int level, const char *msg);
extern void wgSetLogger(void *context, logger_fn_t logger_fn);
extern int wgTurnOn(const char *settings, int32_t tun_fd);
extern void wgTurnOff(int handle);
extern int64_t wgSetConfig(int handle, const char *settings);
extern char *wgGetConfig(int handle);
extern void wgBumpSockets(int handle);
extern void wgDisableSomeRoamingForBrokenMobileSemantics(int handle);
extern const char *wgVersion();

// Tunnel-in-Tunnel (TiT): runs two wireguard-go instances in-process.
// INNER uses the real utun fd and a virtual PipedBind (no real UDP sockets).
// OUTER uses a virtual PipedTun and real UDP sockets (StdNetBind) to reach Server A.
// outerIfaceIP is the OUTER tunnel's interface address (e.g. "10.200.0.2"), used as the
// IP source address when wrapping INNER's WireGuard UDP in IP+UDP for OUTER to encrypt.
extern int32_t wgTurnOnTiT(const char *outerSettings, const char *innerSettings,
                            const char *outerIfaceIP, int32_t tun_fd);
extern void    wgTurnOffTiT(int32_t handle);
extern char   *wgGetConfigTiT(int32_t handle);
extern int64_t wgSetInnerConfigTiT(int32_t handle, const char *settings);
extern void    wgBumpSocketsTiT(int32_t handle);
extern void    wgDisableSomeRoamingForBrokenMobileSemanticsForOuterTiT(int32_t handle);

// Background probe: lightweight WireGuard device with null tun and real UDP sockets.
// Used for non-disruptive failback probing and hot spare validation.
// keepalive_override: if > 0, injects persistent_keepalive_interval for all peers (seconds).
extern int32_t wgProbeOn(const char *settings, int32_t keepalive_override);
extern void    wgProbeOff(int32_t handle);
extern char   *wgProbeGetConfig(int32_t handle);
extern int64_t wgProbeSetConfig(int32_t handle, const char *settings);
extern void    wgProbeBumpSockets(int32_t handle);
// Promote a probe to a full tunnel by swapping in a real utun fd.
// Preserves the existing WireGuard session (no re-handshake).
// Returns a tunnel handle (for use with wgTurnOff/wgSetConfig/etc), or -1 on failure.
extern int32_t wgProbePromote(int32_t probe_handle, int32_t tun_fd);

#endif
