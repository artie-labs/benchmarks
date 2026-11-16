// hold fills a NAT's connection table with real, established TCP connections that then sit idle, without a socket
// at either end, so millions fit on small generators and a small receiver. Each is a full handshake through the NAT
// (SYN, SYN-ACK, ACK), which the NAT's connection table marks established and assured, as it would a worker's idle
// keep-alive connection. It needs root.
//
// Server, on the receiver: answers each SYN from -peer (the NAT's shared address) to -ports with a SYN-ACK.
//
//	hold -serve -peer 10.40.0.100 -ports 7000-7255
//
// Client, on a generator: opens connections from to from+count, at -rate a second, from -source. Connection i goes from source
// port 1024 + i / (number of ports) to port first + i % (number of ports), so 256 ports allow 16.5 million.
//
//	hold -target 10.50.0.10 -source 10.40.1.10 -ports 7000-7255 -from 0 -count 500000 -rate 20000 -out hold.json
//
// -close sends a reset for each instead, which ends its entry in the NAT's table within 10 s.
//
// Neither end's kernel has a socket for these connections, so each would answer the other's packets with a reset,
// which would end the connection in the NAT. Drop them before the kernel sees them, in the raw table (a packet
// socket still sees them first):
//
//	receiver:  iptables -t raw -I PREROUTING -p tcp --dport 7000:7255 -j DROP
//	generator: iptables -t raw -I PREROUTING -p tcp -s <receiver> --sport 7000:7255 -j DROP
package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	firstSourcePort = 1024
	ethPIP          = 0x0800
	packetOutgoing  = 4
	synFlag         = 0x02
	rstFlag         = 0x04
	ackFlag         = 0x10
)

func main() {
	serve := flag.Bool("serve", false, "answer SYNs on the receiver")
	peer := flag.String("peer", "", "with -serve, answer only SYNs from this address, such as the NAT's shared address")
	target := flag.String("target", "", "receiver IPv4 address")
	source := flag.String("source", "", "this generator's address to send from, empty for the one routed to -target")
	portRange := flag.String("ports", "7000-7255", "receiver ports, first-last")
	from := flag.Int("from", 0, "first connection index")
	count := flag.Int("count", 0, "how many connections")
	rate := flag.Int("rate", 20000, "connections (or resets) a second")
	closeMode := flag.Bool("close", false, "send a reset for each connection instead of opening it")
	retries := flag.Int("retries", 2, "passes that resend the SYN of connections not yet answered")
	out := flag.String("out", "-", "JSON summary file, - for stdout")
	flag.Parse()

	first, last, err := parsePorts(*portRange)
	if err != nil {
		fail("-ports: %v", err)
	}
	if *serve {
		peerIP := net.ParseIP(*peer).To4()
		if peerIP == nil {
			fail("-serve needs -peer IPv4")
		}
		runServer(peerIP, uint16(first), uint16(last))
		return
	}
	dst := net.ParseIP(*target).To4()
	ports := last - first + 1
	if dst == nil || *count <= 0 || *from < 0 || *rate <= 0 || (*from+*count)/ports+firstSourcePort > 65535 {
		fail("need -target IPv4, -count > 0, -rate > 0, and from+count within %d connections", (65536-firstSourcePort)*ports)
	}
	c, err := newClient(net.ParseIP(*source).To4(), dst, first, ports)
	if err != nil {
		fail("%v", err)
	}
	var summary map[string]any
	if *closeMode {
		summary = c.close(*from, *count, *rate)
	} else {
		summary = c.open(*from, *count, *rate, *retries)
	}
	w := os.Stdout
	if *out != "-" {
		if w, err = os.Create(*out); err != nil {
			fail("create %s: %v", *out, err)
		}
		defer w.Close()
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", " ")
	enc.Encode(summary)
}

type client struct {
	src, dst    net.IP
	first       int
	ports       int
	send        int
	addr        *syscall.SockaddrInet4
	capture     int
	answered    []atomic.Bool
	from, count int
	synAcks     atomic.Int64
	acks        atomic.Int64
	sendErrors  atomic.Int64
}

func newClient(src, dst net.IP, first, ports int) (*client, error) {
	if src == nil {
		var err error
		if src, err = sourceFor(dst); err != nil {
			return nil, err
		}
	}
	send, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_RAW)
	if err != nil {
		return nil, fmt.Errorf("raw socket: %w", err)
	}
	addr := &syscall.SockaddrInet4{}
	copy(addr.Addr[:], dst)
	return &client{src: src, dst: dst, first: first, ports: ports, send: send, addr: addr}, nil
}

// tuple returns connection i's source and destination ports.
func (c *client) tuple(i int) (uint16, uint16) {
	return uint16(firstSourcePort + i/c.ports), uint16(c.first + i%c.ports)
}

// isn is connection i's initial sequence number, fixed so -close can reset it later without keeping state.
func isn(i int) uint32 {
	return uint32(i)*2654435761 + 0x1000
}

func (c *client) open(from, count, rate, retries int) map[string]any {
	c.from, c.count = from, count
	c.answered = make([]atomic.Bool, count)
	capture, err := openCapture(c.src, clientFilter(c.src, c.dst, uint16(c.first), uint16(c.first+c.ports-1)))
	if err != nil {
		fail("%v", err)
	}
	c.capture = capture
	go c.answer()

	start := time.Now()
	sent := c.paced(rate, count, func(k int) []byte {
		sport, dport := c.tuple(from + k)
		return segment(c.src, c.dst, sport, dport, isn(from+k), 0, synFlag)
	})
	resent := 0
	for pass := 0; pass < retries; pass++ {
		time.Sleep(2 * time.Second)
		var missing []int
		for k := range c.answered {
			if !c.answered[k].Load() {
				missing = append(missing, k)
			}
		}
		if len(missing) == 0 {
			break
		}
		resent += c.paced(rate, len(missing), func(j int) []byte {
			sport, dport := c.tuple(from + missing[j])
			return segment(c.src, c.dst, sport, dport, isn(from+missing[j]), 0, synFlag)
		})
	}
	time.Sleep(2 * time.Second)
	seconds := time.Since(start).Seconds()
	established := 0
	for k := range c.answered {
		if c.answered[k].Load() {
			established++
		}
	}
	return map[string]any{
		"mode": "open", "source": c.src.String(), "target": c.dst.String(), "from": from, "count": count,
		"rate": rate, "seconds": seconds, "syns": sent, "resent": resent, "syn_acks": c.synAcks.Load(),
		"acks": c.acks.Load(), "established": established, "send_errors": c.sendErrors.Load(),
	}
}

func (c *client) close(from, count, rate int) map[string]any {
	start := time.Now()
	sent := c.paced(rate, count, func(k int) []byte {
		sport, dport := c.tuple(from + k)
		return segment(c.src, c.dst, sport, dport, isn(from+k)+1, 0, rstFlag)
	})
	return map[string]any{
		"mode": "close", "source": c.src.String(), "target": c.dst.String(), "from": from, "count": count,
		"rate": rate, "seconds": time.Since(start).Seconds(), "resets": sent, "send_errors": c.sendErrors.Load(),
	}
}

// paced sends n packets built by packet at rate a second and returns how many it sent.
func (c *client) paced(rate, n int, packet func(k int) []byte) int {
	start := time.Now()
	sent := 0
	for k := 0; k < n; k++ {
		if due := time.Duration(float64(k) / float64(rate) * float64(time.Second)); k%64 == 0 {
			if wait := due - time.Since(start); wait > 0 {
				time.Sleep(wait)
			}
		}
		if err := syscall.Sendto(c.send, packet(k), 0, c.addr); err != nil {
			c.sendErrors.Add(1)
			continue
		}
		sent++
	}
	return sent
}

// answer acknowledges each SYN-ACK, which completes the handshake.
func (c *client) answer() {
	buf := make([]byte, 2048)
	for {
		n, from, err := syscall.Recvfrom(c.capture, buf, 0)
		if err != nil {
			continue
		}
		if ll, ok := from.(*syscall.SockaddrLinklayer); ok && ll.Pkttype == packetOutgoing {
			continue
		}
		p := buf[:n]
		if len(p) < 20 || int(p[0]&0xf)*4+20 > len(p) {
			continue
		}
		l4 := p[int(p[0]&0xf)*4:]
		sport, dport := binary.BigEndian.Uint16(l4[0:]), binary.BigEndian.Uint16(l4[2:])
		i := (int(dport)-firstSourcePort)*c.ports + int(sport) - c.first
		if i < c.from || i >= c.from+c.count || binary.BigEndian.Uint32(l4[8:]) != isn(i)+1 {
			continue
		}
		c.synAcks.Add(1)
		reply := segment(c.src, c.dst, dport, sport, isn(i)+1, binary.BigEndian.Uint32(l4[4:])+1, ackFlag)
		if err := syscall.Sendto(c.send, reply, 0, c.addr); err != nil {
			c.sendErrors.Add(1)
			continue
		}
		c.acks.Add(1)
		c.answered[i-c.from].Store(true)
	}
}

func runServer(peer net.IP, first, last uint16) {
	send, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_RAW)
	if err != nil {
		fail("raw socket: %v", err)
	}
	capture, err := openCapture(nil, serverFilter(peer, first, last))
	if err != nil {
		fail("%v", err)
	}
	var answered, failed atomic.Int64
	go func() {
		for range time.Tick(10 * time.Second) {
			fmt.Fprintf(os.Stderr, "%s answered %d failed %d\n", time.Now().UTC().Format(time.TimeOnly), answered.Load(), failed.Load())
		}
	}()
	buf := make([]byte, 2048)
	for {
		n, from, err := syscall.Recvfrom(capture, buf, 0)
		if err != nil {
			continue
		}
		if ll, ok := from.(*syscall.SockaddrLinklayer); ok && ll.Pkttype == packetOutgoing {
			continue
		}
		p := buf[:n]
		if len(p) < 20 || int(p[0]&0xf)*4+20 > len(p) {
			continue
		}
		src, dst := net.IP(p[12:16]), net.IP(p[16:20])
		l4 := p[int(p[0]&0xf)*4:]
		sport, dport := binary.BigEndian.Uint16(l4[0:]), binary.BigEndian.Uint16(l4[2:])
		seq := uint32(sport)<<16 | uint32(dport)
		reply := segment(dst, src, dport, sport, seq, binary.BigEndian.Uint32(l4[4:])+1, synFlag|ackFlag)
		addr := &syscall.SockaddrInet4{}
		copy(addr.Addr[:], src)
		if err := syscall.Sendto(send, reply, 0, addr); err != nil {
			failed.Add(1)
			continue
		}
		answered.Add(1)
	}
}

// openCapture opens a packet socket that receives IPv4 packets matching filter, on the interface with address
// local, or on every interface when local is nil.
func openCapture(local net.IP, filter []syscall.SockFilter) (int, error) {
	fd, err := syscall.Socket(syscall.AF_PACKET, syscall.SOCK_DGRAM, int(htons(ethPIP)))
	if err != nil {
		return 0, fmt.Errorf("packet socket: %w", err)
	}
	// Attach the filter before binding, so no unfiltered packet queues in between.
	if err := syscall.AttachLsf(fd, filter); err != nil {
		return 0, fmt.Errorf("attach filter: %w", err)
	}
	syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUFFORCE, 64<<20)
	index := 0
	if local != nil {
		if index, err = interfaceOf(local); err != nil {
			return 0, err
		}
	}
	if err := syscall.Bind(fd, &syscall.SockaddrLinklayer{Protocol: htons(ethPIP), Ifindex: index}); err != nil {
		return 0, fmt.Errorf("bind packet socket: %w", err)
	}
	return fd, nil
}

func interfaceOf(ip net.IP) (int, error) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return 0, err
	}
	for _, iface := range ifaces {
		addrs, _ := iface.Addrs()
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok && n.IP.Equal(ip) {
				return iface.Index, nil
			}
		}
	}
	return 0, fmt.Errorf("no interface has %s", ip)
}

// Classic BPF over a packet that starts at its IPv4 header (a SOCK_DGRAM packet socket).
const (
	bpfLdWAbs  = 0x00 | 0x00 | 0x20
	bpfLdBAbs  = 0x00 | 0x10 | 0x20
	bpfLdHInd  = 0x00 | 0x08 | 0x40
	bpfLdBInd  = 0x00 | 0x10 | 0x40
	bpfLdxBMsh = 0x01 | 0x10 | 0xa0
	bpfAndK    = 0x04 | 0x50
	bpfJeqK    = 0x05 | 0x10
	bpfJgtK    = 0x05 | 0x20
	bpfJgeK    = 0x05 | 0x30
	bpfRetK    = 0x06
)

// clientFilter accepts SYN-ACKs from dst to src whose source port is in first to last.
func clientFilter(src, dst net.IP, first, last uint16) []syscall.SockFilter {
	return []syscall.SockFilter{
		{Code: bpfLdWAbs, K: 12},
		{Code: bpfJeqK, K: binary.BigEndian.Uint32(dst), Jf: 12},
		{Code: bpfLdWAbs, K: 16},
		{Code: bpfJeqK, K: binary.BigEndian.Uint32(src), Jf: 10},
		{Code: bpfLdBAbs, K: 9},
		{Code: bpfJeqK, K: syscall.IPPROTO_TCP, Jf: 8},
		{Code: bpfLdxBMsh, K: 0},
		{Code: bpfLdHInd, K: 0},
		{Code: bpfJgeK, K: uint32(first), Jf: 5},
		{Code: bpfJgtK, K: uint32(last), Jt: 4},
		{Code: bpfLdBInd, K: 13},
		{Code: bpfAndK, K: synFlag | rstFlag | ackFlag},
		{Code: bpfJeqK, K: synFlag | ackFlag, Jf: 1},
		{Code: bpfRetK, K: 0xffff},
		{Code: bpfRetK, K: 0},
	}
}

// serverFilter accepts SYNs from peer to a destination port in first to last.
func serverFilter(peer net.IP, first, last uint16) []syscall.SockFilter {
	return []syscall.SockFilter{
		{Code: bpfLdWAbs, K: 12},
		{Code: bpfJeqK, K: binary.BigEndian.Uint32(peer), Jf: 10},
		{Code: bpfLdBAbs, K: 9},
		{Code: bpfJeqK, K: syscall.IPPROTO_TCP, Jf: 8},
		{Code: bpfLdxBMsh, K: 0},
		{Code: bpfLdHInd, K: 2},
		{Code: bpfJgeK, K: uint32(first), Jf: 5},
		{Code: bpfJgtK, K: uint32(last), Jt: 4},
		{Code: bpfLdBInd, K: 13},
		{Code: bpfAndK, K: synFlag | rstFlag | ackFlag},
		{Code: bpfJeqK, K: synFlag, Jf: 1},
		{Code: bpfRetK, K: 0xffff},
		{Code: bpfRetK, K: 0},
	}
}

// segment builds an IPv4 packet with a 20-byte TCP header and no payload. The kernel fills in the IP checksum,
// total length and ID.
func segment(src, dst net.IP, sport, dport uint16, seq, ack uint32, flags byte) []byte {
	p := make([]byte, 40)
	p[0], p[8], p[9] = 0x45, 64, syscall.IPPROTO_TCP
	binary.BigEndian.PutUint16(p[2:], 40)
	copy(p[12:], src.To4())
	copy(p[16:], dst.To4())
	l4 := p[20:]
	binary.BigEndian.PutUint16(l4[0:], sport)
	binary.BigEndian.PutUint16(l4[2:], dport)
	binary.BigEndian.PutUint32(l4[4:], seq)
	binary.BigEndian.PutUint32(l4[8:], ack)
	l4[12] = 5 << 4
	l4[13] = flags
	binary.BigEndian.PutUint16(l4[14:], 64240)
	binary.BigEndian.PutUint16(l4[16:], tcpChecksum(src.To4(), dst.To4(), l4))
	return p
}

func tcpChecksum(src, dst net.IP, segment []byte) uint16 {
	var sum uint32
	add := func(b []byte) {
		for i := 0; i+1 < len(b); i += 2 {
			sum += uint32(binary.BigEndian.Uint16(b[i:]))
		}
		if len(b)%2 == 1 {
			sum += uint32(b[len(b)-1]) << 8
		}
	}
	add(src)
	add(dst)
	sum += syscall.IPPROTO_TCP + uint32(len(segment))
	add(segment)
	for sum > 0xffff {
		sum = sum&0xffff + sum>>16
	}
	return ^uint16(sum)
}

// sourceFor returns the local address the kernel would send to dst from.
func sourceFor(dst net.IP) (net.IP, error) {
	c, err := net.Dial("udp4", net.JoinHostPort(dst.String(), "9"))
	if err != nil {
		return nil, fmt.Errorf("no route to %s: %w", dst, err)
	}
	defer c.Close()
	return c.LocalAddr().(*net.UDPAddr).IP.To4(), nil
}

func htons(v uint16) uint16 {
	return v<<8 | v>>8
}

func parsePorts(s string) (int, int, error) {
	a, b, ok := strings.Cut(s, "-")
	if !ok {
		b = a
	}
	first, err := strconv.Atoi(a)
	if err != nil {
		return 0, 0, err
	}
	last, err := strconv.Atoi(b)
	if err != nil || last < first || last > 65535 {
		return 0, 0, fmt.Errorf("bad range %q", s)
	}
	return first, last, nil
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "hold: "+format+"\n", args...)
	os.Exit(1)
}
