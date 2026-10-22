# ============================================================
# CI/CD: GitHub Actions → ECR → SSM
#
# Neden OIDC değil de IAM kullanıcısı + access key?
#   Bu hesap AWS'nin "yeni deneyim" hesabı. Üstündeki değiştirilemeyen
#   SCP, iam:*Provider* işlemlerini (OIDC provider oluşturmayı) yasaklıyor.
#   GitHub Actions'ın AWS'ye girebilmesinin kalan yolu bir access key.
#   Riski küçültmek için:
#     - kullanıcının yetkisi dar: bu ECR deposuna push + uygulama sunucusunda
#       SADECE case1-deploy-app SSM dokümanını çalıştırma (keyfi komut yok)
#     - anahtar sadece GitHub Secrets'ta duruyor, fork PR'ları secret göremiyor
#     - anahtarın son kullanma tarihi YOK; sadece destroy/apply ile yenileniyor
#   Bilerek kabul edilmiş bir trade-off. Anahtar Terraform state'inde de duruyor.
# ============================================================

# ---------- ECR: Docker imajlarının deposu ----------
resource "aws_ecr_repository" "app" {
  name                 = "case1-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # destroy'da içindeki imajlarla birlikte silinsin (lab için)

  image_scanning_configuration {
    scan_on_push = true # her push'ta güvenlik taraması
  }
}

# ---------- Nginx sunucusunun IAM rolü ("çalışan kartı") ----------
resource "aws_iam_role" "app" {
  name = "case1-app-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # SSM'den komut alabilsin
}

resource "aws_iam_role_policy_attachment" "app_ecr" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly" # imaj çekebilsin, yükleyemesin
}

resource "aws_iam_instance_profile" "app" {
  name = "case1-app-profile"
  role = aws_iam_role.app.name
}

# ---------- GitHub Actions için IAM kullanıcısı ----------
resource "aws_iam_user" "github" {
  name          = "case1-github-actions"
  path          = "/ci/"
  force_destroy = false # login profile silme denemesi SCP ile yasak; access key zaten ayrı kaynak olarak siliniyor
}

# En az yetki: sadece deploy için gerekenler
resource "aws_iam_user_policy" "github" {
  name = "case1-github-deploy"
  user = aws_iam_user.github.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPushOnlyThisRepo"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage"
        ]
        Resource = aws_ecr_repository.app.arn
      },
      {
        Sid      = "FindAppInstance"
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
      {
        # Sadece özel deploy dokümanı + sadece uygulama sunucusu.
        # AWS-RunShellScript yetkisi yok: anahtar sızsa bile sunucuda keyfi komut çalıştırılamaz.
        Sid    = "DeployOnlyWithCustomDocument"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          aws_ssm_document.deploy.arn,
          aws_instance.app.arn
        ]
      },
      {
        # GetCommandInvocation kaynak seviyesinde yetkilendirmeyi desteklemiyor
        # (Service Authorization Reference'ta resource type tanımlı değil), bu yüzden "*".
        # Sadece komut sonucunu okur, bir şey değiştiremez.
        # ListCommandInvocations kullanılmadığı için kaldırıldı.
        Sid      = "ReadCommandResult"
        Effect   = "Allow"
        Action   = "ssm:GetCommandInvocation"
        Resource = "*"
      }
    ]
  })
}

# ---------- Deploy için özel SSM dokümanı ----------
# GitHub kullanıcısı sunucuda SADECE bu dokümanı çalıştırabilir.
# Tek parametre imaj digest'i ve regex ile doğrulanıyor; repo adresi Terraform'dan
# gömülü olduğu için kullanıcıdan alınmıyor. Yani dışarıdan gelen hiçbir değer
# kabuğa serbest metin olarak girmiyor (komut enjeksiyonu yok).
#
# Eski imajların temizliği: "docker image prune -af" artık yok. O komut çalışan
# container'ın imajı dışında her şeyi siliyordu, bir önceki sürüm sunucuda
# kalmıyordu. Şimdi bu repodan sadece en yeni 2 imaj tutuluyor (çalışan + bir
# önceki). Böylece önceki digest ile bu doküman tekrar çağrıldığında imaj
# lokalde hazır, rollback ECR'a ve NAT'a bağlı kalmadan saniyeler içinde biter.
# Temizlik sadece sağlık kontrolü geçtikten sonra yapılıyor.
#
# Not: Komutlarda "{{ }}" sadece SSM parametresi için kullanılıyor; docker'ın
# Go template'leri (--format '{{...}}') SSM sözdizimiyle çakışacağı için bilerek yok.
data "aws_region" "current" {}

locals {
  ecr_registry = split("/", aws_ecr_repository.app.repository_url)[0]
  ecr_image    = "${aws_ecr_repository.app.repository_url}@{{ ImageDigest }}"
}

resource "aws_ssm_document" "deploy" {
  name            = "case1-deploy-app"
  document_type   = "Command"
  document_format = "YAML"

  # Komutlar tek bir literal blokta (|): SSM bunları tek bir script olarak çalıştırır,
  # "set -eu" bütün satırlar için geçerli olur.
  content = <<-EOT
    schemaVersion: "2.2"
    description: "case1-app imajini ECR'dan digest ile ceker ve web container'ini yeniler"
    parameters:
      ImageDigest:
        type: String
        description: "Deploy edilecek imajin digest'i (sha256:<64 hex>)"
        allowedPattern: "^sha256:[a-f0-9]{64}$"
    mainSteps:
      - action: aws:runShellScript
        name: deploy
        inputs:
          timeoutSeconds: "240"
          runCommand:
            - |
              set -eu
              aws ecr get-login-password --region ${data.aws_region.current.region} | docker login --username AWS --password-stdin ${local.ecr_registry}
              docker pull ${local.ecr_image}
              docker rm -f web || true
              docker run -d --name web --restart unless-stopped -p 80:80 ${local.ecr_image}
              sleep 3
              # Ayri satir: basarisiz olursa set -e script'i burada durdurur ("curl && echo" durdurmazdi)
              curl -fsS -o /dev/null --retry 5 --retry-connrefused --retry-delay 2 http://localhost
              echo SAGLIK_KONTROLU_OK
              # En yeni 2 imaj kalsin (calisan + onceki), eskiler silinsin. Kullanimdaki imaj silinemez, hata yutulur.
              docker images --digests --no-trunc ${aws_ecr_repository.app.repository_url} | awk 'NR>3 {print $4}' | xargs -r docker rmi || true
  EOT
}

# Access key. Değerleri sadece "terraform output" ile görülebilir (sensitive).
resource "aws_iam_access_key" "github" {
  user = aws_iam_user.github.name
}

# ---------- Çıktılar ----------
output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "deploy_document_name" {
  value = aws_ssm_document.deploy.name
}

output "app_instance_id" {
  value = aws_instance.app.id
}

output "github_access_key_id" {
  value     = aws_iam_access_key.github.id
  sensitive = true
}

output "github_secret_access_key" {
  value     = aws_iam_access_key.github.secret
  sensitive = true
}
