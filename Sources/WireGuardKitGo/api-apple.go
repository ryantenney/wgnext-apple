/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2018-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
 */

package main

// #include <stdlib.h>
// #include <sys/types.h>
// static void callLogger(void *func, void *ctx, int level, const char *msg)
// {
// 	((void(*)(void *, int, const char *))func)(ctx, level, msg);
// }
import "C"

import (
	"encoding/binary"
	"fmt"
	"math"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"runtime"
	"runtime/debug"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

var loggerFunc unsafe.Pointer
var loggerCtx unsafe.Pointer

type CLogger int

func cstring(s string) *C.char {
	b, err := unix.BytePtrFromString(s)
	if err != nil {
		b := [1]C.char{}
		return &b[0]
	}
	return (*C.char)(unsafe.Pointer(b))
}

func (l CLogger) Printf(format string, args ...interface{}) {
	if uintptr(loggerFunc) == 0 {
		return
	}
	C.callLogger(loggerFunc, loggerCtx, C.int(l), cstring(fmt.Sprintf(format, args...)))
}

type tunnelHandle struct {
	*device.Device
	*device.Logger
}

var tunnelHandles = make(map[int32]tunnelHandle)

func init() {
	signals := make(chan os.Signal)
	signal.Notify(signals, unix.SIGUSR2)
	go func() {
		buf := make([]byte, os.Getpagesize())
		for {
			select {
			case <-signals:
				n := runtime.Stack(buf, true)
				buf[n] = 0
				if uintptr(loggerFunc) != 0 {
					C.callLogger(loggerFunc, loggerCtx, 0, (*C.char)(unsafe.Pointer(&buf[0])))
				}
			}
		}
	}()
}

//export wgSetLogger
func wgSetLogger(context, loggerFn uintptr) {
	loggerCtx = unsafe.Pointer(context)
	loggerFunc = unsafe.Pointer(loggerFn)
}

//export wgTurnOn
func wgTurnOn(settings *C.char, tunFd int32) int32 {
	logger := &device.Logger{
		Verbosef: CLogger(0).Printf,
		Errorf:   CLogger(1).Printf,
	}
	dupTunFd, err := unix.Dup(int(tunFd))
	if err != nil {
		logger.Errorf("Unable to dup tun fd: %v", err)
		return -1
	}

	err = unix.SetNonblock(dupTunFd, true)
	if err != nil {
		logger.Errorf("Unable to set tun fd as non blocking: %v", err)
		unix.Close(dupTunFd)
		return -1
	}
	tun, err := tun.CreateTUNFromFile(os.NewFile(uintptr(dupTunFd), "/dev/tun"), 0)
	if err != nil {
		logger.Errorf("Unable to create new tun device from fd: %v", err)
		unix.Close(dupTunFd)
		return -1
	}
	logger.Verbosef("Attaching to interface")
	dev := device.NewDevice(tun, conn.NewStdNetBind(), logger)

	err = dev.IpcSet(C.GoString(settings))
	if err != nil {
		logger.Errorf("Unable to set IPC settings: %v", err)
		unix.Close(dupTunFd)
		return -1
	}

	dev.Up()
	logger.Verbosef("Device started")

	var i int32
	for i = 0; i < math.MaxInt32; i++ {
		if _, exists := tunnelHandles[i]; !exists {
			break
		}
	}
	if i == math.MaxInt32 {
		unix.Close(dupTunFd)
		return -1
	}
	tunnelHandles[i] = tunnelHandle{dev, logger}
	return i
}

//export wgTurnOff
func wgTurnOff(tunnelHandle int32) {
	dev, ok := tunnelHandles[tunnelHandle]
	if !ok {
		return
	}
	delete(tunnelHandles, tunnelHandle)
	dev.Close()
}

//export wgSetConfig
func wgSetConfig(tunnelHandle int32, settings *C.char) int64 {
	dev, ok := tunnelHandles[tunnelHandle]
	if !ok {
		return 0
	}
	err := dev.IpcSet(C.GoString(settings))
	if err != nil {
		dev.Errorf("Unable to set IPC settings: %v", err)
		if ipcErr, ok := err.(*device.IPCError); ok {
			return ipcErr.ErrorCode()
		}
		return -1
	}
	return 0
}

//export wgGetConfig
func wgGetConfig(tunnelHandle int32) *C.char {
	device, ok := tunnelHandles[tunnelHandle]
	if !ok {
		return nil
	}
	settings, err := device.IpcGet()
	if err != nil {
		return nil
	}
	return C.CString(settings)
}

//export wgBumpSockets
func wgBumpSockets(tunnelHandle int32) {
	dev, ok := tunnelHandles[tunnelHandle]
	if !ok {
		return
	}
	go func() {
		for i := 0; i < 10; i++ {
			err := dev.BindUpdate()
			if err == nil {
				dev.SendKeepalivesToPeersWithCurrentKeypair()
				return
			}
			dev.Errorf("Unable to update bind, try %d: %v", i+1, err)
			time.Sleep(time.Second / 2)
		}
		dev.Errorf("Gave up trying to update bind; tunnel is likely dysfunctional")
	}()
}

//export wgDisableSomeRoamingForBrokenMobileSemantics
func wgDisableSomeRoamingForBrokenMobileSemantics(tunnelHandle int32) {
	dev, ok := tunnelHandles[tunnelHandle]
	if !ok {
		return
	}
	dev.DisableSomeRoamingForBrokenMobileSemantics()
}

//export wgVersion
func wgVersion() *C.char {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return C.CString("unknown")
	}
	for _, dep := range info.Deps {
		if dep.Path == "golang.zx2c4.com/wireguard" {
			parts := strings.Split(dep.Version, "-")
			if len(parts) == 3 && len(parts[2]) == 12 {
				return C.CString(parts[2][:7])
			}
			return C.CString(dep.Version)
		}
	}
	return C.CString("unknown")
}

// ========== Tunnel-in-Tunnel (TiT) Support ==========
//
// TiT runs two wireguard-go instances in-process:
//   INNER — owns the real utun fd; handles user traffic; uses PipedBind instead of real UDP sockets.
//   OUTER — owns a virtual PipedTun; uses real UDP sockets (StdNetBind) to reach Server A.
//
// Packet flow (outbound):
//   user IP pkt → INNER TUN (utun) → INNER encrypts → PipedBind.Send wraps as IP+UDP
//   → PipedTun.Read (OUTER reads) → OUTER encrypts → StdNetBind.Send → Server A → Server B
//
// Packet flow (inbound):
//   Server A → StdNetBind.Receive → OUTER decrypts → PipedTun.Write (IP+UDP)
//   → PipedBind.ReceiveFunc unwraps → INNER decrypts → TUN write → user IP pkt

// pipedTunnel holds the channels shared between PipedTun and PipedBind.
type pipedTunnel struct {
	// toOuter: INNER's PipedBind puts wrapped IP+UDP packets here; OUTER's PipedTun reads from here.
	toOuter chan []byte
	// fromOuter: OUTER's PipedTun puts decrypted IP+UDP packets here; INNER's PipedBind reads from here.
	fromOuter    chan []byte
	outerIfaceIP netip.Addr // source IP used when wrapping INNER's WireGuard UDP as IP+UDP
	closed       chan struct{}
}

// ---- PipedTun: tun.Device implementation for OUTER ----

type pipedTunDevice struct {
	pt     *pipedTunnel
	events chan tun.Event
	mtu    int
}

func (t *pipedTunDevice) File() *os.File { return nil }

// Read is called by OUTER to get the next IP packet to encrypt and send.
func (t *pipedTunDevice) Read(data []byte, offset int) (int, error) {
	select {
	case <-t.pt.closed:
		return 0, os.ErrClosed
	case pkt := <-t.pt.toOuter:
		n := copy(data[offset:], pkt)
		return n, nil
	}
}

// Write is called by OUTER when it has a decrypted IP packet to deliver.
func (t *pipedTunDevice) Write(data []byte, offset int) (int, error) {
	pkt := make([]byte, len(data)-offset)
	copy(pkt, data[offset:])
	select {
	case <-t.pt.closed:
		return 0, os.ErrClosed
	case t.pt.fromOuter <- pkt:
		return len(pkt), nil
	}
}

func (t *pipedTunDevice) Flush() error             { return nil }
func (t *pipedTunDevice) MTU() (int, error)        { return t.mtu, nil }
func (t *pipedTunDevice) Name() (string, error)    { return "tit-outer0", nil }
func (t *pipedTunDevice) Events() <-chan tun.Event { return t.events }
func (t *pipedTunDevice) Close() error {
	select {
	case <-t.pt.closed:
	default:
		close(t.pt.closed)
	}
	return nil
}

// ---- PipedBind: conn.Bind implementation for INNER ----

type pipedBind struct {
	pt          *pipedTunnel
	closeSignal chan struct{}
}

// pipedEndpoint implements conn.Endpoint for pipe-based addressing.
type pipedEndpoint struct {
	addrPort netip.AddrPort
}

func (e *pipedEndpoint) ClearSrc()           {}
func (e *pipedEndpoint) SrcToString() string { return "" }
func (e *pipedEndpoint) DstToString() string { return e.addrPort.String() }
func (e *pipedEndpoint) DstToBytes() []byte {
	b, _ := e.addrPort.MarshalBinary()
	return b
}
func (e *pipedEndpoint) DstIP() netip.Addr { return e.addrPort.Addr() }
func (e *pipedEndpoint) SrcIP() netip.Addr { return netip.Addr{} }

func (b *pipedBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	b.closeSignal = make(chan struct{})
	receive := func(data []byte) (int, conn.Endpoint, error) {
		select {
		case <-b.closeSignal:
			return 0, nil, net.ErrClosed
		case <-b.pt.closed:
			return 0, nil, net.ErrClosed
		case pkt := <-b.pt.fromOuter:
			payload, srcAddrPort, err := titUnwrapIPUDP(pkt)
			if err != nil {
				return 0, nil, fmt.Errorf("tit: unwrap: %w", err)
			}
			n := copy(data, payload)
			return n, &pipedEndpoint{addrPort: srcAddrPort}, nil
		}
	}
	return []conn.ReceiveFunc{receive}, 0, nil
}

func (b *pipedBind) Close() error {
	if b.closeSignal != nil {
		select {
		case <-b.closeSignal:
		default:
			close(b.closeSignal)
		}
	}
	return nil
}

func (b *pipedBind) SetMark(mark uint32) error { return nil }

func (b *pipedBind) Send(data []byte, ep conn.Endpoint) error {
	pkt, err := titWrapIPUDP(data, b.pt.outerIfaceIP, ep)
	if err != nil {
		return fmt.Errorf("tit: wrap: %w", err)
	}
	select {
	case <-b.pt.closed:
		return net.ErrClosed
	case b.pt.toOuter <- pkt:
		return nil
	}
}

func (b *pipedBind) ParseEndpoint(s string) (conn.Endpoint, error) {
	addrPort, err := netip.ParseAddrPort(s)
	if err != nil {
		return nil, err
	}
	return &pipedEndpoint{addrPort: addrPort}, nil
}

// ---- IP+UDP wrapping/unwrapping ----

// titWrapIPUDP wraps a WireGuard UDP payload in an IP+UDP packet.
// srcIP is OUTER's tunnel interface address; ep is INNER's peer endpoint (Server B).
func titWrapIPUDP(payload []byte, srcIP netip.Addr, ep conn.Endpoint) ([]byte, error) {
	dstAddrPort, err := netip.ParseAddrPort(ep.DstToString())
	if err != nil {
		return nil, fmt.Errorf("bad endpoint %q: %w", ep.DstToString(), err)
	}
	dst := dstAddrPort.Addr()
	dstPort := dstAddrPort.Port()
	const srcPort = 51820

	if dst.Is4() {
		src4 := srcIP.As4()
		if !srcIP.Is4() {
			src4 = [4]byte{10, 200, 0, 1} // fallback if outer iface is not IPv4
		}
		return titWrapIPv4UDP(payload, src4, dst.As4(), srcPort, dstPort), nil
	}
	// IPv6
	src6 := srcIP.As16()
	return titWrapIPv6UDP(payload, src6, dst.As16(), srcPort, dstPort), nil
}

func titWrapIPv4UDP(payload []byte, src, dst [4]byte, srcPort, dstPort uint16) []byte {
	totalLen := 20 + 8 + len(payload)
	pkt := make([]byte, totalLen)

	// IPv4 header
	pkt[0] = 0x45 // version=4, IHL=5
	binary.BigEndian.PutUint16(pkt[2:], uint16(totalLen))
	pkt[8] = 64  // TTL
	pkt[9] = 17  // protocol: UDP
	copy(pkt[12:16], src[:])
	copy(pkt[16:20], dst[:])
	cksum := titIPv4Checksum(pkt[:20])
	binary.BigEndian.PutUint16(pkt[10:], cksum)

	// UDP header
	binary.BigEndian.PutUint16(pkt[20:], srcPort)
	binary.BigEndian.PutUint16(pkt[22:], dstPort)
	binary.BigEndian.PutUint16(pkt[24:], uint16(8+len(payload)))
	// UDP checksum left as 0 (optional for IPv4)

	copy(pkt[28:], payload)
	return pkt
}

func titWrapIPv6UDP(payload []byte, src, dst [16]byte, srcPort, dstPort uint16) []byte {
	udpLen := 8 + len(payload)
	totalLen := 40 + udpLen
	pkt := make([]byte, totalLen)

	// IPv6 header
	pkt[0] = 0x60 // version=6
	binary.BigEndian.PutUint16(pkt[4:], uint16(udpLen)) // payload length
	pkt[6] = 17                                          // next header: UDP
	pkt[7] = 64                                          // hop limit
	copy(pkt[8:24], src[:])
	copy(pkt[24:40], dst[:])

	// UDP header
	binary.BigEndian.PutUint16(pkt[40:], srcPort)
	binary.BigEndian.PutUint16(pkt[42:], dstPort)
	binary.BigEndian.PutUint16(pkt[44:], uint16(udpLen))
	// UDP checksum: compute pseudo-header checksum for IPv6 (required)
	cksum := titIPv6UDPChecksum(src, dst, pkt[40:40+udpLen], uint32(udpLen))
	binary.BigEndian.PutUint16(pkt[46:], cksum)

	copy(pkt[48:], payload)
	return pkt
}

// titUnwrapIPUDP extracts WireGuard payload and source address from a decrypted IP+UDP packet.
func titUnwrapIPUDP(pkt []byte) (payload []byte, src netip.AddrPort, err error) {
	if len(pkt) < 1 {
		return nil, netip.AddrPort{}, fmt.Errorf("packet too short")
	}
	version := pkt[0] >> 4
	switch version {
	case 4:
		if len(pkt) < 28 {
			return nil, netip.AddrPort{}, fmt.Errorf("IPv4+UDP packet too short (%d bytes)", len(pkt))
		}
		ihl := int(pkt[0]&0x0f) * 4
		if len(pkt) < ihl+8 {
			return nil, netip.AddrPort{}, fmt.Errorf("IPv4+UDP packet too short for IHL")
		}
		srcAddr := netip.AddrFrom4([4]byte{pkt[12], pkt[13], pkt[14], pkt[15]})
		srcPort := binary.BigEndian.Uint16(pkt[ihl:])
		return pkt[ihl+8:], netip.AddrPortFrom(srcAddr, srcPort), nil
	case 6:
		if len(pkt) < 48 {
			return nil, netip.AddrPort{}, fmt.Errorf("IPv6+UDP packet too short (%d bytes)", len(pkt))
		}
		var srcB [16]byte
		copy(srcB[:], pkt[8:24])
		srcAddr := netip.AddrFrom16(srcB)
		srcPort := binary.BigEndian.Uint16(pkt[40:])
		return pkt[48:], netip.AddrPortFrom(srcAddr, srcPort), nil
	default:
		return nil, netip.AddrPort{}, fmt.Errorf("unknown IP version %d", version)
	}
}

func titIPv4Checksum(header []byte) uint16 {
	var sum uint32
	for i := 0; i+1 < len(header); i += 2 {
		sum += uint32(header[i])<<8 | uint32(header[i+1])
	}
	for sum > 0xffff {
		sum = (sum >> 16) + (sum & 0xffff)
	}
	return ^uint16(sum)
}

func titIPv6UDPChecksum(src, dst [16]byte, udpSegment []byte, udpLen uint32) uint16 {
	var sum uint32
	for i := 0; i < 16; i += 2 {
		sum += uint32(src[i])<<8 | uint32(src[i+1])
		sum += uint32(dst[i])<<8 | uint32(dst[i+1])
	}
	sum += uint32(udpLen) & 0xffff
	sum += uint32(udpLen) >> 16
	sum += 17 // next header = UDP
	for i := 0; i+1 < len(udpSegment); i += 2 {
		sum += uint32(udpSegment[i])<<8 | uint32(udpSegment[i+1])
	}
	if len(udpSegment)%2 != 0 {
		sum += uint32(udpSegment[len(udpSegment)-1]) << 8
	}
	for sum > 0xffff {
		sum = (sum >> 16) + (sum & 0xffff)
	}
	return ^uint16(sum)
}

// ---- TiT handle management ----

type titHandle struct {
	innerDev    *device.Device
	innerLogger *device.Logger
	outerDev    *device.Device
	outerLogger *device.Logger
	tunnel      *pipedTunnel
}

var titHandles = make(map[int32]titHandle)

//export wgTurnOnTiT
func wgTurnOnTiT(outerSettings *C.char, innerSettings *C.char, outerIfaceIPStr *C.char, tunFd int32) int32 {
	innerLogger := &device.Logger{
		Verbosef: CLogger(0).Printf,
		Errorf:   CLogger(1).Printf,
	}
	outerLogger := &device.Logger{
		Verbosef: CLogger(0).Printf,
		Errorf:   CLogger(1).Printf,
	}

	outerIfaceIP, ok := netip.AddrFromSlice(net.ParseIP(C.GoString(outerIfaceIPStr)))
	if !ok {
		outerLogger.Errorf("TiT: invalid outer interface IP %q", C.GoString(outerIfaceIPStr))
		return -1
	}
	outerIfaceIP = outerIfaceIP.Unmap()

	tunnel := &pipedTunnel{
		toOuter:      make(chan []byte, 128),
		fromOuter:    make(chan []byte, 128),
		outerIfaceIP: outerIfaceIP,
		closed:       make(chan struct{}),
	}

	// Build OUTER device: virtual PipedTun + real UDP sockets
	outerTunDev := &pipedTunDevice{
		pt:     tunnel,
		events: make(chan tun.Event, 1),
		mtu:    1420,
	}
	outerTunDev.events <- tun.EventUp
	outerDev := device.NewDevice(outerTunDev, conn.NewStdNetBind(), outerLogger)
	if err := outerDev.IpcSet(C.GoString(outerSettings)); err != nil {
		outerLogger.Errorf("TiT: unable to configure outer device: %v", err)
		outerDev.Close()
		return -1
	}
	outerDev.Up()

	// Build INNER device: real utun + PipedBind
	dupTunFd, err := unix.Dup(int(tunFd))
	if err != nil {
		innerLogger.Errorf("TiT: unable to dup tun fd: %v", err)
		outerDev.Close()
		return -1
	}
	if err = unix.SetNonblock(dupTunFd, true); err != nil {
		innerLogger.Errorf("TiT: unable to set tun fd non-blocking: %v", err)
		unix.Close(dupTunFd)
		outerDev.Close()
		return -1
	}
	innerTunDev, err := tun.CreateTUNFromFile(os.NewFile(uintptr(dupTunFd), "/dev/tun"), 0)
	if err != nil {
		innerLogger.Errorf("TiT: unable to create tun device: %v", err)
		unix.Close(dupTunFd)
		outerDev.Close()
		return -1
	}
	innerBind := &pipedBind{pt: tunnel}
	innerDev := device.NewDevice(innerTunDev, innerBind, innerLogger)
	if err = innerDev.IpcSet(C.GoString(innerSettings)); err != nil {
		innerLogger.Errorf("TiT: unable to configure inner device: %v", err)
		innerDev.Close()
		outerDev.Close()
		return -1
	}
	innerDev.Up()
	innerLogger.Verbosef("TiT: devices started")

	var i int32
	for i = 0; i < math.MaxInt32; i++ {
		if _, exists := titHandles[i]; !exists {
			break
		}
	}
	if i == math.MaxInt32 {
		innerDev.Close()
		outerDev.Close()
		return -1
	}
	titHandles[i] = titHandle{innerDev, innerLogger, outerDev, outerLogger, tunnel}
	return i
}

//export wgTurnOffTiT
func wgTurnOffTiT(handle int32) {
	h, ok := titHandles[handle]
	if !ok {
		return
	}
	delete(titHandles, handle)
	h.innerDev.Close()
	h.outerDev.Close()
}

//export wgGetConfigTiT
func wgGetConfigTiT(handle int32) *C.char {
	h, ok := titHandles[handle]
	if !ok {
		return nil
	}
	settings, err := h.innerDev.IpcGet()
	if err != nil {
		return nil
	}
	return C.CString(settings)
}

//export wgSetInnerConfigTiT
func wgSetInnerConfigTiT(handle int32, settings *C.char) int64 {
	h, ok := titHandles[handle]
	if !ok {
		return 0
	}
	if err := h.innerDev.IpcSet(C.GoString(settings)); err != nil {
		h.innerLogger.Errorf("TiT: unable to update inner config: %v", err)
		if ipcErr, ok := err.(*device.IPCError); ok {
			return ipcErr.ErrorCode()
		}
		return -1
	}
	return 0
}

//export wgBumpSocketsTiT
func wgBumpSocketsTiT(handle int32) {
	h, ok := titHandles[handle]
	if !ok {
		return
	}
	go func() {
		for i := 0; i < 10; i++ {
			if err := h.outerDev.BindUpdate(); err == nil {
				h.outerDev.SendKeepalivesToPeersWithCurrentKeypair()
				return
			}
			h.outerLogger.Errorf("TiT: unable to update bind, try %d", i+1)
			time.Sleep(time.Second / 2)
		}
		h.outerLogger.Errorf("TiT: gave up trying to update bind")
	}()
}

//export wgDisableSomeRoamingForBrokenMobileSemanticsForOuterTiT
func wgDisableSomeRoamingForBrokenMobileSemanticsForOuterTiT(handle int32) {
	h, ok := titHandles[handle]
	if !ok {
		return
	}
	h.outerDev.DisableSomeRoamingForBrokenMobileSemantics()
}

func main() {}
