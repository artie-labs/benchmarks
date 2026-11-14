// The smallest native XDP program: passes every packet to the kernel. Built by ../scripts/build.sh into
// box/bin/xdp_pass.o. No headers, so it builds with any clang that has the BPF target.
__attribute__((section("xdp"), used)) int xdp_pass(void *ctx) { return 2; /* XDP_PASS */ }
char _license[] __attribute__((section("license"), used)) = "GPL";
