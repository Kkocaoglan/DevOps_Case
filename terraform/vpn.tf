data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_key_pair" "case1" {
  key_name   = "case1-key"
  public_key = file(pathexpand("~/.ssh/case1.pub"))
}

resource "aws_security_group" "vpn" {
  name        = "case1-vpn-sg"
  description = "OpenVPN server"
  vpc_id      = aws_vpc.main.id

  # Internete acik TEK kapi. SSH yok: yonetim VPN tunelinin icinden.
  ingress {
    description = "OpenVPN"
    from_port   = 1194
    to_port     = 1194
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "case1-vpn-sg" }
}

locals {
  vpn_user_data = <<EOT
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

until apt-get update; do sleep 5; done
apt-get install -y openvpn iptables-persistent

mkdir -p /etc/openvpn/server
cat > /etc/openvpn/server/ca.crt <<'EOF'
${tls_self_signed_cert.ca.cert_pem}
EOF
cat > /etc/openvpn/server/server.crt <<'EOF'
${tls_locally_signed_cert.server.cert_pem}
EOF
cat > /etc/openvpn/server/server.key <<'EOF'
${tls_private_key.server.private_key_pem}
EOF
cat > /etc/openvpn/server/ta.key <<'EOF'
${local.tls_crypt_key}
EOF
chmod 600 /etc/openvpn/server/server.key /etc/openvpn/server/ta.key

cat > /etc/openvpn/server/server.conf <<'EOF'
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh none
tls-crypt ta.key
server 10.8.0.0 255.255.255.0
push "route 10.0.0.0 255.255.0.0"
keepalive 10 120
data-ciphers AES-256-GCM:AES-128-GCM
user nobody
group nogroup
persist-key
persist-tun
verb 3
EOF

echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn.conf
sysctl --system
IFACE=$(ip route show default | awk '{print $5}')
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$IFACE" -j MASQUERADE
netfilter-persistent save

systemctl enable --now openvpn-server@server
EOT
}

resource "aws_instance" "vpn" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.vpn.id]
  key_name               = aws_key_pair.case1.key_name
  source_dest_check      = false

  user_data                   = local.vpn_user_data
  user_data_replace_on_change = true

  # Yeni Ubuntu AMI çıkınca VPN sunucusu kendiliğinden yeniden oluşturulmasın
  # (yoksa public IP değişir ve herkesin .ovpn dosyası bozulur)
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = "case1-vpn" }
}

output "vpn_public_ip" {
  value = aws_instance.vpn.public_ip
}

output "vpn_private_ip" {
  value = aws_instance.vpn.private_ip
}
