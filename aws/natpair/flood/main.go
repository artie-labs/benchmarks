// flood sends 64-byte UDP datagrams or TCP SYNs to one address at a fixed packet rate, from random source ports to
// random destination ports, through a raw socket. The bench uses it to load a NAT's own address from outside the
// VPC while the NAT forwards worker traffic. It needs root.
//
// flood -target 10.40.0.116 -mode syn -pps 1000000 -duration 60s -workers 4 -out flood.json
package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand/v2"
	"net"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	ringSize   = 8192
	packetSize = 64
	batch      = 256
)

func main() {
	target := flag.String("target", "", "destination IPv4 address")
	mode := flag.String("mode", "udp", "udp or syn")
	pps := flag.Int("pps", 100000, "packets a second, in total")
	duration := flag.Duration("duration", 60*time.Second, "how long to send")
	workers := flag.Int("workers", runtime.NumCPU(), "sending threads")
	out := flag.String("out", "-", "JSON summary file, - for stdout")
	flag.Parse()

	dst := net.ParseIP(*target).To4()
	if dst == nil || (*mode != "udp" && *mode != "syn") || *pps <= 0 || *workers <= 0 {
		fmt.Fprintln(os.Stderr, "flood: need -target IPv4, -mode udp|syn, -pps > 0, -workers > 0")
		os.Exit(2)
	}
	src, err := sourceFor(dst)
	if err != nil {
		fmt.Fprintln(os.Stderr, "flood:", err)
		os.Exit(1)
	}
	ring := buildRing(*mode, src, dst)
	addr := &syscall.SockaddrInet4{}
	copy(addr.Addr[:], dst)

	var sent, failed atomic.Int64
	start := time.Now()
	deadline := start.Add(*duration)
	perWorker := float64(*pps) / float64(*workers)
	var wg sync.WaitGroup
	for w := 0; w < *workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			runtime.LockOSThread()
			fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_RAW)
			if err != nil {
				fmt.Fprintln(os.Stderr, "flood: raw socket:", err)
				os.Exit(1)
			}
			defer syscall.Close(fd)
			n, i := 0, w*ringSize/(*workers)
			for {
				now := time.Now()
				if now.After(deadline) {
					return
				}
				// Send ahead of schedule by at most one batch, then wait for the schedule to catch up.
				due := int(now.Sub(start).Seconds()*perWorker) + batch
				if n >= due {
					time.Sleep(time.Duration(float64(n-due+1) / perWorker * float64(time.Second)))
					continue
				}
				for k := 0; k < batch; k++ {
					if err := syscall.Sendto(fd, ring[i], 0, addr); err != nil {
						failed.Add(1)
					} else {
						sent.Add(1)
					}
					i = (i + 1) % ringSize
				}
				n += batch
			}
		}(w)
	}
	wg.Wait()
	seconds := time.Since(start).Seconds()
	summary := map[string]any{
		"mode": *mode, "target": *target, "source": src.String(), "pps_target": *pps, "workers": *workers,
		"seconds": seconds, "sent": sent.Load(), "failed": failed.Load(), "sent_pps": float64(sent.Load()) / seconds,
	}
	f := os.Stdout
	if *out != "-" {
		if f, err = os.Create(*out); err != nil {
			fmt.Fprintln(os.Stderr, "flood:", err)
			os.Exit(1)
		}
		defer f.Close()
	}
	json.NewEncoder(f).Encode(summary)
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

// buildRing returns ringSize 64-byte IPv4 packets with random source and destination ports. The kernel fills in
// the IP header checksum and total length.
func buildRing(mode string, src, dst net.IP) [][]byte {
	ring := make([][]byte, ringSize)
	for i := range ring {
		p := make([]byte, packetSize)
		p[0], p[8] = 0x45, 64
		binary.BigEndian.PutUint16(p[2:], packetSize)
		copy(p[12:], src)
		copy(p[16:], dst)
		l4 := p[20:]
		binary.BigEndian.PutUint16(l4[0:], uint16(1024+rand.IntN(64000)))
		binary.BigEndian.PutUint16(l4[2:], uint16(1+rand.IntN(65535)))
		if mode == "udp" {
			p[9] = syscall.IPPROTO_UDP
			binary.BigEndian.PutUint16(l4[4:], uint16(len(l4)))
			// A zero UDP checksum means none, which IPv4 allows.
		} else {
			p[9] = syscall.IPPROTO_TCP
			binary.BigEndian.PutUint32(l4[4:], rand.Uint32())
			l4[12] = 5 << 4 // 20-byte header
			l4[13] = 0x02   // SYN
			binary.BigEndian.PutUint16(l4[14:], 64240)
			binary.BigEndian.PutUint16(l4[16:], tcpChecksum(src, dst, l4))
		}
		ring[i] = p
	}
	return ring
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
