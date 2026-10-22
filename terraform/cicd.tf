# ============================================================
# CI/CD: GitHub Actions → ECR → SSM
#
# Neden OIDC değil de IAM kullanıcısı + access key?
#   Bu hesap AWS'nin "yeni deneyim" hesabı. Üstündeki değiştirilemeyen
#   SCP, iam:*Provider* işlemlerini (OIDC provider oluşturmayı) yasaklıyor.
#   GitHub Actions'ın AWS'ye girebilmesinin kalan yolu bir access key.
#   Riski küçültmek için:
#     - kullanıcının yetkisi çok dar (sadece bu ECR deposu + sadece bu sunucu)
#     - anahtar sadece GitHub Secrets'ta duruyor, fork PR'ları secret göremiyor
#     - her destroy'da kullanıcı ve anahtar siliniyor, her apply'da yenisi geliyor
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
        Sid    = "RunCommandOnlyOnAppServer"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          "arn:aws:ssm:eu-north-1::document/AWS-RunShellScript",
          aws_instance.app.arn
        ]
      },
      {
        Sid      = "ReadCommandResult"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      }
    ]
  })
}

# Access key. Değerleri sadece "terraform output" ile görülebilir (sensitive).
resource "aws_iam_access_key" "github" {
  user = aws_iam_user.github.name
}

# ---------- Çıktılar ----------
output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
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
