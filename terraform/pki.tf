# ---------- CA (noter) ----------
resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 8760 # 1 yıl
  allowed_uses          = ["cert_signing", "crl_signing"]

  subject {
    common_name = "case1-ca"
  }
}

# ---------- Sunucu sertifikası ----------
resource "tls_private_key" "server" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "server" {
  private_key_pem = tls_private_key.server.private_key_pem
  subject {
    common_name = "server"
  }
}

resource "tls_locally_signed_cert" "server" {
  cert_request_pem      = tls_cert_request.server.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 8760
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}

# ---------- Client sertifikası ----------
resource "tls_private_key" "client" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "client" {
  private_key_pem = tls_private_key.client.private_key_pem
  subject {
    common_name = "client1"
  }
}

resource "tls_locally_signed_cert" "client" {
  cert_request_pem      = tls_cert_request.client.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 8760
  allowed_uses          = ["digital_signature", "client_auth"]
}

# ---------- tls-crypt anahtarı (ta.key) ----------
# OpenVPN formatı: 256 rastgele bayt, 16 satır x 32 hex karakter
resource "random_id" "tls_crypt" {
  byte_length = 256
}

locals {
  tls_crypt_key = join("\n", concat(
    ["-----BEGIN OpenVPN Static key V1-----"],
    [for i in range(16) : substr(random_id.tls_crypt.hex, i * 32, 32)],
    ["-----END OpenVPN Static key V1-----"]
  ))
}
