// Drops IPv4 UDP from the receiver's VPC (10.50.0.0/16), which only the bench's flood sends, and passes everything
// else, so a NAT keeps its own traffic while the bench measures what dropping in XDP costs. Built by
// ../scripts/build.sh into box/bin/xdp_drop.o.
struct xdp_md {
  unsigned int data;
  unsigned int data_end;
  unsigned int data_meta;
  unsigned int ingress_ifindex;
  unsigned int rx_queue_index;
  unsigned int egress_ifindex;
};

__attribute__((section("xdp"), used)) int xdp_drop_flood(struct xdp_md *ctx) {
  unsigned char *p = (unsigned char *)(long)ctx->data;
  unsigned char *end = (unsigned char *)(long)ctx->data_end;
  // Ethernet (14 bytes) and the IPv4 header up to the source address (20 bytes).
  if (p + 34 > end)
    return 2; // XDP_PASS
  if (p[12] == 0x08 && p[13] == 0x00 && p[23] == 17 && p[26] == 10 && p[27] == 50)
    return 1; // XDP_DROP
  return 2;
}
char _license[] __attribute__((section("license"), used)) = "GPL";
