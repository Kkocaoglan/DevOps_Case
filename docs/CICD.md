# CI/CD kurulum rehberi (GitHub Actions)

**Hedef:** `app/` klasöründe bir değişiklik yapıp `git push` dediğinde, yeni sürüm birkaç dakika içinde **internete kapalı** private sunucuda yayında olsun. Kimse SSH yapmasın, hiçbir port açılmasın.

## Akış
```
 git push (main, app/ değişti)
     │
     ▼
 GitHub Actions runner (GitHub'ın makinesi, internette)
     │ 1. GitHub Secrets'taki access key ile AWS'ye giriş
     │ 2. docker build app/   (index.html'e commit SHA'sı yazılır)
     │ 3. docker push → ECR   (case1-app:<sha>)
     │ 4. scripts/deploy.sh:
     │      Name=case1-app tag'li sunucuyu bul
     │      SSM send-command → ECR login → pull → eski container'ı sil → yenisini başlat → curl sağlık kontrolü
     ▼
 Private EC2 (SSM agent NAT üzerinden AWS'ye dışarıya doğru bağlı, gelen port yok)
```

## Kimlik doğrulama: neden OIDC değil?
GitHub Actions'ın AWS'ye girmesinin en iyi yolu **OIDC**: GitHub her çalışmada birkaç dakikalık bir kimlik belgesi üretir, ortada saklanan bir anahtar olmaz. İlk tasarım buydu. Ama `terraform apply` şu hatayı verdi:
```
AccessDenied ... iam:CreateOpenIDConnectProvider ... with an explicit deny in a service control policy
```
Bu hesap AWS'nin yeni kayıt deneyimiyle açıldı. Üstündeki değiştirilemeyen SCP, `iam:*Provider*` işlemlerini yasaklıyor ve bu yasak Paid plan'de de var.

GitHub Actions'ta kalmak için kalan yol bir **IAM kullanıcısı + access key.** Kalıcı bir anahtar olduğu için riski şöyle küçülttük:
- **En az yetki:** Kullanıcı sadece `case1-app` ECR deposuna push edebiliyor ve sadece Nginx sunucusunda `AWS-RunShellScript` çalıştırabiliyor. Anahtar sızsa bile S3'e, başka sunuculara, IAM'e ya da faturaya dokunamaz. Kanıtı TESTS.md'deki S10c testi.
- **Sadece GitHub Secrets'ta:** Kodda ya da logda görünmüyor, GitHub loglarda otomatik maskeliyor.
- **Fork'lara kapalı:** GitHub, fork'lardan açılan PR'ların workflow'larına secret vermiyor.
- **Sadece main:** Workflow `push: branches: [main]` ile tetikleniyor, ayrıca `if: github.ref == 'refs/heads/main'` koşulu var.
- **Kısa ömür:** Kullanıcı ve anahtar Terraform'da tanımlı. Her `destroy`'da siliniyor, her `apply`'da yenisi üretiliyor. Bu kendiliğinden bir rotation demek.

**Kabul edilen risk:** Anahtar `terraform.tfstate` dosyasında da duruyor (TESTS.md, B1 ve B1b).

> Alternatif olarak AWS CodePipeline + CodeBuild da denendi. O yolda AWS kodu GitHub'dan kendisi çektiği için hiç anahtar gerekmiyor. GitHub Actions'ın ekosistemi ve görünürlüğü tercih edildiği için bu yolda kalındı. Mülakatta iki yolu da anlatabilirsin.

## Terraform kaynakları (`terraform/cicd.tf`)
- **`aws_ecr_repository.app`:** İmaj deposu. `scan_on_push` açık, `force_delete` açık (sadece lab için).
- **`aws_iam_role.app` + 2 managed policy + `aws_iam_instance_profile.app`:** Nginx sunucusunun "çalışan kartı".
  - `AmazonSSMManagedInstanceCore`: SSM'den komut alabilir.
  - `AmazonEC2ContainerRegistryReadOnly`: ECR'dan imaj çekebilir, yükleyemez.
- **`aws_iam_user.github`:** `case1-github-actions` kullanıcısı. `force_destroy = true` ile destroy'da anahtarıyla birlikte siliniyor. Konsol şifresi yok, sadece programatik erişim.
- **`aws_iam_user_policy.github`:** Dar yetkiler, yukarıdaki listedeki gibi.
- **`aws_iam_access_key.github`:** Anahtar. Değerleri `sensitive` output, yani sadece `terraform output -raw ...` ile görülebiliyor.

Diğer dosyalar:
- **`.github/workflows/deploy.yml`:** Pipeline.
- **`scripts/deploy.sh`:** SSM deploy ve sağlık kontrolü.
- **`app/`:** Dockerfile ve sayfa.

---

## Adım adım kurulum

### 0. Eski CodePipeline denemesini temizle (bir kez)
Önce **eski dosyalar yerindeyken** destroy et, ki Terraform CodePipeline kaynaklarını da silsin:
```bash
cd ~/devops-case1/terraform
terraform destroy
```
CodeConnections bağlantısını Console'dan onayladıysan GitHub'daki uygulamayı da kaldır: GitHub → **Settings → Applications → Installed GitHub Apps → AWS Connector for GitHub → Uninstall**.

### 1. Dosyaları yerleştir
```bash
cd ~/devops-case1
rm -f buildspec.yml
unzip -o ~/Downloads/case1-cicd-v3.zip -d ~/devops-case1
git status
```
`buildspec.yml` listede olmamalı. `.github/workflows/deploy.yml` ve `scripts/deploy.sh` olmalı.

### 2. Altyapıyı kur
```bash
aws login
cd ~/devops-case1/terraform
terraform init -upgrade
terraform validate
terraform plan        # ... to add, 0 to change, 0 to destroy
terraform apply
```

### 3. Sunucunun SSM'e kaydolmasını bekle (4-5 dk)
```bash
aws ssm describe-instance-information \
  --query "InstanceInformationList[].{Id:InstanceId,Ping:PingStatus}" --output table
terraform output app_instance_id
```
İki ID eşleşmeli, `Ping` sütunu **Online** olmalı.

### 4. Anahtarı GitHub Secrets'a koy
Değerleri al:
```bash
cd ~/devops-case1/terraform
terraform output -raw github_access_key_id; echo
terraform output -raw github_secret_access_key; echo
```
GitHub'da:
1. Repo → **Settings → Secrets and variables → Actions**
2. **Secrets** sekmesi (Variables değil) → **New repository secret**
   - Name: `AWS_ACCESS_KEY_ID`, Value: ilk çıktı
3. Tekrar **New repository secret**
   - Name: `AWS_SECRET_ACCESS_KEY`, Value: ikinci çıktı
4. Daha önce `AWS_ROLE_ARN` diye bir **variable** eklediysen sil, artık kullanılmıyor.

> **`gh` CLI kuruluysa** (`brew install gh`, sonra `gh auth login`) bunu terminalden de yapabilirsin. Anahtar ekranda hiç görünmez:
> ```bash
> cd ~/devops-case1/terraform
> gh secret set AWS_ACCESS_KEY_ID --repo Kkocaoglan/DevOps_Case --body "$(terraform output -raw github_access_key_id)"
> gh secret set AWS_SECRET_ACCESS_KEY --repo Kkocaoglan/DevOps_Case --body "$(terraform output -raw github_secret_access_key)"
> ```

> ⚠️ **Her `destroy` + `apply` sonrası anahtar değişir.** Bu iki secret'ı tekrar güncellemen gerekir, yoksa pipeline `InvalidClientTokenId` hatası verir. Bu kısa ömrün bedeli.

### 5. Push et ve izle
```bash
cd ~/devops-case1
git add .
git status          # tfstate / .ovpn / .pem OLMAMALI
git commit -m "CI/CD: GitHub Actions + ECR + SSM"
git push
```
GitHub'da **Actions** sekmesini aç ve **Build and Deploy** çalışmasını izle. Son adımın logunda şunlar olmalı:
- `SAGLIK_KONTROLU_OK`
- `Durum: Success`

Push yapmadan tetiklemek için: Actions → Build and Deploy → **Run workflow**.

### 6. Doğrula (VPN bağlıyken)
```bash
cd ~/devops-case1/terraform
curl -s http://$(terraform output -raw app_private_ip) | grep -E "deploy|Versiyon"
git log -1 --format=%h
```
Sayfada **"GitHub Actions → ECR → SSM ile deploy edildi."** satırı olmalı, versiyon da son commit'in kısa SHA'sıyla aynı olmalı.

### 7. Gerçek bir değişiklik dene
`app/index.html` dosyasındaki başlığı değiştir, sonra:
```bash
cd ~/devops-case1
git commit -am "Başlık güncellendi"
git push
```
1-2 dakika içinde sayfa yeni başlıkla ve yeni SHA ile açılmalı.

**Ekran görüntüleri** (`docs/screenshots/`):
- `actions.png`: Yeşil workflow
- `deployed.png`: Tarayıcıda yeni sayfa ve adres çubuğu
- `ecr.png`: ECR'daki imajlar ve tarama sonuçları

---

## Workflow satır satır
- **`on.push.branches: [main]` + `paths`:** Sadece main'de `app/`, `scripts/` ya da workflow dosyası değişince çalışıyor. README'yi düzenlemek deploy tetiklemiyor.
- **`permissions: contents: read`:** Workflow repoya yazamıyor.
- **`concurrency`:** Arka arkaya iki push gelirse deploy'lar üst üste binmiyor, sırayla çalışıyor.
- **`if: github.ref == 'refs/heads/main'`:** Elle başka bir branch'ten tetiklense bile job atlanıyor.
- **`configure-aws-credentials`:** Secrets'taki anahtarı ortam değişkenine koyuyor. Sonraki `aws` ve `docker` komutları bununla çalışıyor.
- **`amazon-ecr-login`:** Docker'ı ECR'a login ediyor, registry adresini output olarak veriyor.
- **Build adımı:** `__VERSION__`'ı kısa SHA ile değiştiriyor, imajı build edip push ediyor. İmaj adresini `$GITHUB_ENV` üzerinden bir sonraki adıma aktarıyor.
- **Deploy adımı:** `scripts/deploy.sh` sunucuyu tag'iyle buluyor, SSM'e komutları gönderiyor, bitmesini bekliyor, çıktısını yazdırıyor. Sağlık kontrolü geçmezse adım kırmızı oluyor.

## Sorun giderme
- **`The security token included in the request is invalid` / `InvalidClientTokenId`:** Secret'lar eski ya da yanlış. 4. adımı tekrarla. destroy/apply sonrası bunu yapmak gerekiyor.
- **`Credentials could not be loaded`:** Secret'ların adı yanlış ya da Variables sekmesine eklenmiş. Secrets sekmesinde olmalılar.
- **`AccessDenied ... ecr:...`:** `aws_iam_user_policy.github`'daki ECR ARN'si yanlış.
- **`HATA: Çalışan bir case1-app sunucusu bulunamadı`:** Sunucu kapalı.
- **`InvalidInstanceId`:** Sunucu SSM'e kayıtlı değil. 3. adıma dön. Sunucuda `sudo snap services amazon-ssm-agent` ile agent'ın durumuna bak.
- **SSM `Failed`:** Logdaki "sunucudaki çıktı" bölümüne bak.
  - `aws: command not found` → user_data kurulumu bitmemiş. Sunucuda `sudo tail -50 /var/log/cloud-init-output.log`
  - `curl` adımında hata → container başlamadı. Sunucuda `sudo docker logs web`
- **Job "skipped":** main dışındaki bir branch'ten çalıştırdın. Beklenen davranış.
