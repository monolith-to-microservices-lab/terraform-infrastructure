#!/bin/bash
# NAT instance bootstrap (Amazon Linux 2023). Mirrors the AWS documentation
# procedure for building a NAT AMI; runs once at first boot.
set -euo pipefail

dnf install -y iptables-services
systemctl enable --now iptables

cat >/etc/sysctl.d/90-nat.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/90-nat.conf

IFACE="$(ip route show default | awk '{print $5; exit}')"
iptables -t nat -A POSTROUTING -o "${IFACE}" -j MASQUERADE
iptables -F FORWARD
service iptables save
