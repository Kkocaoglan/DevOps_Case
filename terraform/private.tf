resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "case1-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "case1-nat" }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = { Name = "case1-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "app" {
  name        = "case1-app-sg"
  description = "Private app server - only from VPN"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SSH from VPN server"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.vpn.id]
  }

  ingress {
    description     = "HTTP from VPN server"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.vpn.id]
  }

  ingress {
    description     = "Ping from VPN server"
    from_port       = -1
    to_port         = -1
    protocol        = "icmp"
    security_groups = [aws_security_group.vpn.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "case1-app-sg" }
}

locals {
  app_user_data = <<EOT
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

until apt-get update; do sleep 5; done
apt-get install -y docker.io
systemctl enable --now docker

# AWS CLI: CI/CD'de ECR'a login olmak için
snap install aws-cli --classic
ln -sf /snap/bin/aws /usr/local/bin/aws

# İlk açılışta geçici sayfa (CI/CD ilk deploy'da bunu ECR imajıyla değiştirecek)
mkdir -p /opt/site
cat > /opt/site/index.html <<'EOF'
<!doctype html>
<html>
<head><meta charset="utf-8"><title>Case 1</title></head>
<body style="font-family:sans-serif;text-align:center;margin-top:15%">
  <h1>Kayahan - DevOps Case 1</h1>
  <p>Private subnet'teki EC2 üzerinde Docker + Nginx</p>
  <p>Sadece VPN üzerinden erişilebilir.</p>
  <p><small>Terraform + user_data ile otomatik kuruldu.</small></p>
</body>
</html>
EOF

docker run -d --name web --restart unless-stopped \
  -p 80:80 -v /opt/site:/usr/share/nginx/html:ro nginx:alpine
EOT
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = aws_key_pair.case1.key_name
  iam_instance_profile   = aws_iam_instance_profile.app.name

  user_data                   = local.app_user_data
  user_data_replace_on_change = true

  depends_on = [aws_route_table_association.private]

  # Yeni Ubuntu AMI çıkınca makine kendiliğinden yeniden oluşturulmasın
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = "case1-app" }
}

output "app_private_ip" {
  value = aws_instance.app.private_ip
}
