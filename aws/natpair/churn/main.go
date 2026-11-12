// churn opens a new TCP connection for every small request, like a client sending many small S3 PUTs, to load a
// NAT with connection setup and teardown instead of long flows.
//
// Server: churn -serve -ports 6000-6063
// Client: churn -target 10.50.0.10 -ports 6000-6063 -rate 5000 -duration 60s -bind 10.40.1.10,10.40.1.11 -out c.json
//
// The server reads -size bytes, answers with 64 bytes and closes. The client starts connections at -rate a second
// in total, spread over its source addresses and the server's ports, and writes a JSON summary: connections started,
// completed, failed by error, and request latency percentiles.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	serve := flag.Bool("serve", false, "run the server")
	target := flag.String("target", "", "server address")
	portRange := flag.String("ports", "6000-6063", "server ports, first-last")
	rate := flag.Int("rate", 1000, "new connections a second, in total")
	duration := flag.Duration("duration", 60*time.Second, "how long to run")
	bind := flag.String("bind", "", "comma-separated source addresses, empty for the default")
	size := flag.Int("size", 4096, "request bytes")
	maxInFlight := flag.Int("max-in-flight", 20000, "most connections open at once; more are counted as skipped")
	out := flag.String("out", "-", "JSON summary file, - for stdout")
	flag.Parse()

	first, last, err := parsePorts(*portRange)
	if err != nil {
		fail("-ports: %v", err)
	}
	if *serve {
		runServer(first, last, *size)
		return
	}
	if *target == "" {
		fail("-target is required")
	}
	var sources []string
	if *bind != "" {
		sources = strings.Split(*bind, ",")
	}
	summary := runClient(*target, first, last, *rate, *duration, sources, *size, *maxInFlight)
	w := os.Stdout
	if *out != "-" {
		if w, err = os.Create(*out); err != nil {
			fail("create %s: %v", *out, err)
		}
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", " ")
	if err := enc.Encode(summary); err != nil {
		fail("write: %v", err)
	}
}

func runServer(first, last, size int) {
	for port := first; port <= last; port++ {
		ln, err := net.Listen("tcp", ":"+strconv.Itoa(port))
		if err != nil {
			fail("listen %d: %v", port, err)
		}
		go func() {
			for {
				conn, err := ln.Accept()
				if err != nil {
					continue
				}
				go serveConn(conn, size)
			}
		}()
	}
	select {}
}

func serveConn(conn net.Conn, size int) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := io.CopyN(io.Discard, conn, int64(size)); err != nil {
		return
	}
	conn.Write(make([]byte, 64))
}

type summary struct {
	Target         string         `json:"target"`
	Sources        []string       `json:"sources"`
	RatePerSecond  int            `json:"rate_per_second"`
	Seconds        float64        `json:"seconds"`
	Started        int64          `json:"started"`
	Completed      int64          `json:"completed"`
	Skipped        int64          `json:"skipped"`
	Failed         map[string]int `json:"failed"`
	CompletedPerS  float64        `json:"completed_per_second"`
	LatencyMsP50   float64        `json:"latency_ms_p50"`
	LatencyMsP90   float64        `json:"latency_ms_p90"`
	LatencyMsP99   float64        `json:"latency_ms_p99"`
	LatencyMsMax   float64        `json:"latency_ms_max"`
	LatencySamples int            `json:"latency_samples"`
}

func runClient(target string, first, last, rate int, duration time.Duration, sources []string, size, maxInFlight int) summary {
	var started, completed, skipped, inFlight atomic.Int64
	var mu sync.Mutex
	failed := map[string]int{}
	var latencies []time.Duration
	payload := make([]byte, size)

	dialers := []*net.Dialer{{Timeout: 5 * time.Second}}
	if len(sources) > 0 {
		dialers = nil
		for _, s := range sources {
			dialers = append(dialers, &net.Dialer{Timeout: 5 * time.Second, LocalAddr: &net.TCPAddr{IP: net.ParseIP(s)}})
		}
	}

	one := func(n int64) {
		defer inFlight.Add(-1)
		d := dialers[n%int64(len(dialers))]
		port := first + int(n/int64(len(dialers)))%(last-first+1)
		begin := time.Now()
		err := request(d, net.JoinHostPort(target, strconv.Itoa(port)), payload)
		took := time.Since(begin)
		mu.Lock()
		defer mu.Unlock()
		if err != nil {
			failed[errorKind(err)]++
			return
		}
		completed.Add(1)
		// Keep at most a million samples, which is plenty for percentiles.
		if len(latencies) < 1_000_000 {
			latencies = append(latencies, took)
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()
	begin := time.Now()
	// Start connections in 1 ms batches, so the rate stays even without a timer per connection.
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	var wg sync.WaitGroup
	for done := false; !done; {
		select {
		case <-ctx.Done():
			done = true
		case now := <-ticker.C:
			due := int64(now.Sub(begin).Seconds() * float64(rate))
			for started.Load() < due {
				n := started.Add(1) - 1
				if inFlight.Load() >= int64(maxInFlight) {
					skipped.Add(1)
					continue
				}
				inFlight.Add(1)
				wg.Add(1)
				go func() {
					defer wg.Done()
					one(n)
				}()
			}
		}
	}
	elapsed := time.Since(begin)
	wg.Wait()

	slices.Sort(latencies)
	pct := func(p float64) float64 {
		if len(latencies) == 0 {
			return 0
		}
		return float64(latencies[int(p*float64(len(latencies)-1))].Microseconds()) / 1000
	}
	return summary{
		Target: target, Sources: sources, RatePerSecond: rate, Seconds: elapsed.Seconds(),
		Started: started.Load(), Completed: completed.Load(), Skipped: skipped.Load(), Failed: failed,
		CompletedPerS: float64(completed.Load()) / elapsed.Seconds(),
		LatencyMsP50:  pct(0.5), LatencyMsP90: pct(0.9), LatencyMsP99: pct(0.99), LatencyMsMax: pct(1),
		LatencySamples: len(latencies),
	}
}

// request connects, sends the payload, reads the 64-byte answer and closes normally, leaving TIME_WAIT behind as an
// HTTP client would.
func request(d *net.Dialer, addr string, payload []byte) error {
	conn, err := d.Dial("tcp", addr)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := conn.Write(payload); err != nil {
		return fmt.Errorf("write: %w", err)
	}
	if _, err := io.ReadFull(conn, make([]byte, 64)); err != nil {
		return fmt.Errorf("read: %w", err)
	}
	return nil
}

func errorKind(err error) string {
	msg := err.Error()
	for _, kind := range []string{"timeout", "connection refused", "connection reset", "address already in use", "cannot assign requested address", "EOF"} {
		if strings.Contains(msg, kind) {
			return strings.SplitN(msg, ":", 2)[0] + ": " + kind
		}
	}
	return msg
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
	if err != nil || last < first {
		return 0, 0, fmt.Errorf("bad range %q", s)
	}
	return first, last, nil
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "churn: "+format+"\n", args...)
	os.Exit(1)
}
