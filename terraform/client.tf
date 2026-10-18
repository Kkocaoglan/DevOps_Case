resource "local_sensitive_file" "client_ovpn" {
  filename        = "${path.module}/client1.ovpn"
  file_permission = "0600"
  content         = <<EOT
client
dev tun
proto udp
remote ${aws_instance.vpn.public_ip} 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
data-ciphers AES-256-GCM:AES-128-GCM
verb 3
<ca>
${tls_self_signed_cert.ca.cert_pem}</ca>
<cert>
${tls_locally_signed_cert.client.cert_pem}</cert>
<key>
${tls_private_key.client.private_key_pem}</key>
<tls-crypt>
${local.tls_crypt_key}
</tls-crypt>
EOT
}
