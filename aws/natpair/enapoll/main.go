// enapoll samples an ENA interface's allowance counters and packet counters at a fixed interval and writes one CSV
// row per interface per sample. It reads the counters with the ethtool ioctl, the call `ethtool -S` makes, without
// starting a process per read, and records how long each read took.
//
// Usage:
//
//	enapoll -i auto -interval 10ms -duration 60s -out samples.csv -cpu cpu.csv -procs conntrackd,natpair
//	enapoll -i ens5 -bench 2000   # time 2000 back-to-back reads, print a JSON summary
//
// -i auto samples every ENA interface and checks for new ones each second, so a NAT that gains or loses the shared
// ENI during a handover keeps sampling it. -cpu writes the per-CPU jiffies from /proc/stat and the named processes'
// user and system jiffies once a second, the numbers mpstat and pidstat compute from.
package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	siocEthtool     = 0x8946
	ethtoolGStrings = 0x1b
	ethtoolGStats   = 0x1d
	ethtoolGSSet    = 0x37
	ethSSStats      = 1
	ethGStringLen   = 32
)

// allowanceNames are the ENA counters of packets AWS queued or dropped at the instance's limits.
var allowanceNames = []string{
	"bw_in_allowance_exceeded",
	"bw_out_allowance_exceeded",
	"pps_allowance_exceeded",
	"conntrack_allowance_exceeded",
	"linklocal_allowance_exceeded",
	// A gauge, not a count: how many more connections AWS will track before conntrack_allowance_exceeded moves.
	"conntrack_allowance_available",
}

var sysNames = []string{"rx_packets", "tx_packets", "rx_bytes", "tx_bytes"}

func main() {
	ifaces := flag.String("i", "", "comma-separated interfaces")
	interval := flag.Duration("interval", 10*time.Millisecond, "time between samples")
	duration := flag.Duration("duration", 60*time.Second, "how long to sample")
	out := flag.String("out", "-", "CSV output file, - for stdout")
	bench := flag.Int("bench", 0, "time this many back-to-back reads of the first interface instead of sampling")
	cpuOut := flag.String("cpu", "", "CSV file for CPU samples once a second, empty for none")
	procs := flag.String("procs", "", "comma-separated process names whose CPU time -cpu also samples")
	flag.Parse()

	if *ifaces == "" {
		fail("-i is required")
	}
	auto := *ifaces == "auto"
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0)
	if err != nil {
		fail("socket: %v", err)
	}
	readers := map[string]*reader{}
	names := strings.Split(*ifaces, ",")
	if auto {
		names = enaInterfaces()
	}
	for _, name := range names {
		r, err := newReader(fd, name)
		if err != nil {
			fail("%s: %v", name, err)
		}
		readers[name] = r
	}

	if *bench > 0 {
		if len(names) == 0 {
			fail("no interface to read")
		}
		runBench(readers[names[0]], *bench)
		return
	}

	if *cpuOut != "" {
		go sampleCPU(*cpuOut, strings.Split(*procs, ","), *duration)
	}

	w := os.Stdout
	if *out != "-" {
		w, err = os.Create(*out)
		if err != nil {
			fail("create %s: %v", *out, err)
		}
	}
	bw := bufio.NewWriterSize(w, 1<<20)
	fmt.Fprintf(bw, "t_ns,iface,read_ns,%s,%s\n", strings.Join(sysNames, ","), strings.Join(allowanceNames, ","))

	// SIGTERM or SIGINT ends sampling early, keeping the rows so far: run.sh stops a burst run this way.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	ticker := time.NewTicker(*interval)
	defer ticker.Stop()
	deadline := time.Now().Add(*duration)
	lastScan := time.Now()
	for now := time.Now(); now.Before(deadline) && len(stop) == 0; now = <-ticker.C {
		if auto && now.Sub(lastScan) >= time.Second {
			lastScan = now
			for _, name := range enaInterfaces() {
				if readers[name] != nil {
					continue
				}
				if r, err := newReader(fd, name); err == nil {
					readers[name] = r
				}
			}
		}
		for _, name := range sortedKeys(readers) {
			r := readers[name]
			start := time.Now()
			if err := r.read(); err != nil {
				// A detached shared ENI disappears. Keep sampling the others.
				if !auto {
					fail("%s: %v", r.name, err)
				}
				r.close()
				delete(readers, name)
				continue
			}
			took := time.Since(start)
			fmt.Fprintf(bw, "%d,%s,%d", start.UnixNano(), r.name, took.Nanoseconds())
			for _, f := range r.sysFiles {
				fmt.Fprintf(bw, ",%d", readSys(f))
			}
			for _, idx := range r.allowanceIdx {
				if idx < 0 {
					bw.WriteString(",")
					continue
				}
				fmt.Fprintf(bw, ",%d", r.stat(idx))
			}
			bw.WriteString("\n")
		}
	}
	if err := bw.Flush(); err != nil {
		fail("write: %v", err)
	}
	if w != os.Stdout {
		if err := w.Close(); err != nil {
			fail("close: %v", err)
		}
	}
}

type reader struct {
	fd           int
	name         string
	statsBuf     []byte
	allowanceIdx []int
	sysFiles     []*os.File
}

func newReader(fd int, name string) (*reader, error) {
	setInfo := make([]byte, 20)
	binary.LittleEndian.PutUint32(setInfo[0:], ethtoolGSSet)
	binary.LittleEndian.PutUint64(setInfo[8:], 1<<ethSSStats)
	if err := ethtool(fd, name, setInfo); err != nil {
		return nil, fmt.Errorf("ETHTOOL_GSSET_INFO: %w", err)
	}
	count := int(binary.LittleEndian.Uint32(setInfo[16:]))

	strs := make([]byte, 12+count*ethGStringLen)
	binary.LittleEndian.PutUint32(strs[0:], ethtoolGStrings)
	binary.LittleEndian.PutUint32(strs[4:], ethSSStats)
	binary.LittleEndian.PutUint32(strs[8:], uint32(count))
	if err := ethtool(fd, name, strs); err != nil {
		return nil, fmt.Errorf("ETHTOOL_GSTRINGS: %w", err)
	}
	statNames := make([]string, count)
	for i := range statNames {
		raw := strs[12+i*ethGStringLen : 12+(i+1)*ethGStringLen]
		statNames[i] = strings.TrimRight(string(raw), "\x00")
	}

	r := &reader{fd: fd, name: name, statsBuf: make([]byte, 8+count*8)}
	for _, want := range allowanceNames {
		r.allowanceIdx = append(r.allowanceIdx, slices.Index(statNames, want))
	}
	for _, s := range sysNames {
		f, err := os.Open("/sys/class/net/" + name + "/statistics/" + s)
		if err != nil {
			return nil, err
		}
		r.sysFiles = append(r.sysFiles, f)
	}
	return r, nil
}

func (r *reader) close() {
	for _, f := range r.sysFiles {
		f.Close()
	}
}

func (r *reader) read() error {
	binary.LittleEndian.PutUint32(r.statsBuf[0:], ethtoolGStats)
	binary.LittleEndian.PutUint32(r.statsBuf[4:], uint32((len(r.statsBuf)-8)/8))
	return ethtool(r.fd, r.name, r.statsBuf)
}

func (r *reader) stat(idx int) uint64 {
	return binary.LittleEndian.Uint64(r.statsBuf[8+idx*8:])
}

// ethtool issues SIOCETHTOOL with an ifreq whose data pointer is buf.
func ethtool(fd int, name string, buf []byte) error {
	var ifr [40]byte
	copy(ifr[:15], name)
	*(*uintptr)(unsafe.Pointer(&ifr[16])) = uintptr(unsafe.Pointer(&buf[0]))
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), siocEthtool, uintptr(unsafe.Pointer(&ifr[0])))
	runtime.KeepAlive(buf)
	if errno != 0 {
		return errno
	}
	return nil
}

// readSys returns a /sys counter, or 0 when the interface went away between the ioctl and this read.
func readSys(f *os.File) uint64 {
	var b [32]byte
	n, _ := f.ReadAt(b[:], 0)
	v, _ := strconv.ParseUint(strings.TrimSpace(string(b[:n])), 10, 64)
	return v
}

// enaInterfaces lists the interfaces the ENA driver runs.
func enaInterfaces() []string {
	links, _ := filepath.Glob("/sys/class/net/*/device/driver")
	var names []string
	for _, link := range links {
		target, err := os.Readlink(link)
		if err == nil && filepath.Base(target) == "ena" {
			names = append(names, filepath.Base(filepath.Dir(filepath.Dir(link))))
		}
	}
	slices.Sort(names)
	return names
}

func sortedKeys(m map[string]*reader) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

// sampleCPU writes, once a second, each /proc/stat cpu line (jiffies: user nice system idle iowait irq softirq steal)
// and each named process's user and system jiffies, summed over its processes.
func sampleCPU(path string, procs []string, duration time.Duration) {
	f, err := os.Create(path)
	if err != nil {
		fail("create %s: %v", path, err)
	}
	w := bufio.NewWriter(f)
	fmt.Fprintln(w, "t_ns,name,user,nice,system,idle,iowait,irq,softirq,steal")
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	deadline := time.Now().Add(duration)
	for now := time.Now(); now.Before(deadline); now = <-ticker.C {
		t := time.Now().UnixNano()
		stat, err := os.ReadFile("/proc/stat")
		if err != nil {
			fail("read /proc/stat: %v", err)
		}
		for _, line := range strings.Split(string(stat), "\n") {
			fields := strings.Fields(line)
			if len(fields) < 9 || !strings.HasPrefix(fields[0], "cpu") {
				continue
			}
			fmt.Fprintf(w, "%d,%s,%s\n", t, fields[0], strings.Join(fields[1:9], ","))
		}
		for _, name := range procs {
			if name == "" {
				continue
			}
			user, system := procTime(name)
			fmt.Fprintf(w, "%d,proc:%s,%d,,%d,,,,,\n", t, name, user, system)
		}
		w.Flush()
	}
	f.Close()
}

// procTime sums utime and stime, in jiffies, over the processes whose comm is name.
func procTime(name string) (user, system uint64) {
	comms, _ := filepath.Glob("/proc/[0-9]*/comm")
	for _, commPath := range comms {
		comm, err := os.ReadFile(commPath)
		if err != nil || strings.TrimSpace(string(comm)) != name {
			continue
		}
		stat, err := os.ReadFile(filepath.Join(filepath.Dir(commPath), "stat"))
		if err != nil {
			continue
		}
		// Fields after the parenthesized comm: state is field 3, utime 14, stime 15.
		rest := strings.Fields(string(stat[strings.LastIndexByte(string(stat), ')')+1:]))
		if len(rest) < 13 {
			continue
		}
		u, _ := strconv.ParseUint(rest[11], 10, 64)
		s, _ := strconv.ParseUint(rest[12], 10, 64)
		user += u
		system += s
	}
	return user, system
}

func runBench(r *reader, n int) {
	took := make([]int64, n)
	for i := range took {
		start := time.Now()
		if err := r.read(); err != nil {
			fail("%s: %v", r.name, err)
		}
		took[i] = time.Since(start).Nanoseconds()
	}
	slices.Sort(took)
	pct := func(p float64) int64 { return took[int(p*float64(n-1))] }
	summary := map[string]any{
		"iface": r.name, "reads": n,
		"min_us": float64(took[0]) / 1e3, "p50_us": float64(pct(0.5)) / 1e3,
		"p90_us": float64(pct(0.9)) / 1e3, "p99_us": float64(pct(0.99)) / 1e3, "max_us": float64(took[n-1]) / 1e3,
	}
	if err := json.NewEncoder(os.Stdout).Encode(summary); err != nil {
		fail("encode: %v", err)
	}
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "enapoll: "+format+"\n", args...)
	os.Exit(1)
}
