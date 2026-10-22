# CI/CD kurulum rehberi (GitHub Actions)

**Hedef:** `app/` klasöründe bir değişiklik yapıp `git push` dediğinde, yeni sürüm birkaç dakika içinde **internete kapalı** private sunucuda yayında olsun. Kimse SSH yapmasın, hiçbir port açılmasın.

## Akış
```
 git push (main, app/ değişti)
     │
     ▼
 GitHub Actions runner (GitHub'ın makinesi, internette), job: environment "production"
     │ 1. production environment secret'larındaki access key ile AWS'ye giriş
     │ 2. case1-app:<kısa sha> ECR'da zaten var mı? (tag'ler IMMUTABLE; varsa 3-4 atlanır)
     │ 3. docker build app/   (index.html'e commit SHA'sı yazılır)
     │ 4. docker push → ECR   ve push edilen imajın digest'i alınır (sha256:...)
     │ 5. Tarama kapısı: ECR taraması beklenir, CRITICAL bulgu varsa burada durulur
     │ 6. scripts/deploy.sh <digest>:
     │      Name=case1-app tag'li sunucuyu bul
     │      SSM send-command, doküman: case1-deploy-app, parametre: ImageDigest
     │        → ECR login → digest ile pull → eski container'ı sil → yenisini başlat → curl sağlık kontrolü
     │      Sonucu 10 sn arayla en fazla ~5 dk sorgula, Success değilse kırmızı
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
- **En az yetki:** Kullanıcı sadece `case1-app` ECR deposuna push edebiliyor ve sadece uygulama sunucusunda, sadece `case1-deploy-app` SSM dokümanını çalıştırabiliyor. `AWS-RunShellScript` yetkisi yok.
- **Sızarsa ne olur (dürüst sınır):** Saldırgan ECR'a kendi imajını yükleyip bu dokümanla uygulama sunucusuna deploy edebilir, yani sunucuda kendi container'ını çalıştırabilir. Sunucuda keyfi bir komut çalıştıramaz (doküman sadece digest kabul ediyor), container'dan rolün anahtarlarına ulaşamaz (IMDS hop limit 1), S3'e, başka sunuculara, IAM'e dokunamaz. Kanıtı TESTS.md'deki S10c, S10d, S10e testleri.
- **Sadece GitHub Secrets'ta:** Kodda ya da logda görünmüyor, GitHub loglarda otomatik maskeliyor. Secret'lar `production` environment'ında, bu environment'a sadece `main` branch'inden çalışan job'lar erişebiliyor.
- **Fork'lara kapalı:** GitHub, fork'lardan açılan PR'ların workflow'larına secret vermiyor.
- **Sadece main:** Workflow `push: branches: [main]` ile tetikleniyor, ayrıca `if: github.ref == 'refs/heads/main'` koşulu ve environment'ın deployment branch kuralı var.
- **Son kullanma tarihi yok:** Anahtar kendiliğinden geçersiz olmuyor. Kullanıcı ve anahtar Terraform'da tanımlı; sadece `destroy` + `apply` ile siliniyor ve yenisi üretiliyor. Düzenli rotation için anahtarı elle yenilemek gerekir: `terraform apply -replace=aws_iam_access_key.github`, sonra secret'ları güncelle.

**Kabul edilen risk:** Anahtar `terraform.tfstate` dosyasında da duruyor (TESTS.md, B1 ve B1b).

> Alternatif olarak AWS CodePipeline + CodeBuild da denendi. O yolda AWS kodu GitHub'dan kendisi çektiği için hiç anahtar gerekmiyor. GitHub Actions'ın ekosistemi ve görünürlüğü tercih edildiği için bu yolda kalındı.

## Terraform kaynakları (`terraform/cicd.tf`)
- **`aws_ecr_repository.app`:** İmaj deposu. Tag'ler `IMMUTABLE` (push edilen bir tag başka imaja taşınamaz), `scan_on_push` açık, `force_delete` açık (sadece lab için).
- **`aws_ssm_document.deploy`:** `case1-deploy-app` deploy dokümanı. Tek parametresi `ImageDigest`, `^sha256:[a-f0-9]{64}$` ile doğrulanıyor. Repo adresi dokümana gömülü. Container'ı `-p 80:8080` ile başlatıyor (imaj `nginx-unprivileged`, 8080'i dinliyor). Sağlık kontrolü geçerse bu repodan sadece en yeni 2 imajı (çalışan + bir önceki) bırakıp eskileri siliyor.
- **`aws_iam_role.app` + `aws_iam_instance_profile.app`:** Nginx sunucusunun "çalışan kartı".
  - `AmazonSSMManagedInstanceCore` (managed): SSM agent'ın çalışması için. İçindeki `ssm:GetParameter*` yetkisi `*` üzerinde; kalan risk olarak README'de ve TESTS.md B18'de yazıyor.
  - `case1-app-ecr-pull` (inline): Sadece `case1-app` deposundan imaj çekebilir, yükleyemez, başka depoları göremez.
- **`aws_iam_user.github`:** `case1-github-actions` kullanıcısı. `force_destroy = false`: `true` olunca Terraform destroy'da login profile'ı silmeye çalışıyor ve bu hesaptaki SCP `iam:*LoginProfile*` işlemlerini yasakladığı için hata veriyor. Access key ayrı bir kaynak olduğu için destroy'da zaten siliniyor. Konsol şifresi yok, sadece programatik erişim.
- **`aws_iam_user_policy.github`:** Dar yetkiler:
  - `ecr:GetAuthorizationToken` (`*`, kaynak seviyesinde kısıtlanamıyor)
  - ECR push yetkileri, `ecr:DescribeImages` (tag var mı kontrolü) ve `ecr:DescribeImageScanFindings` (tarama kapısı) sadece `case1-app` deposunda
  - `ec2:DescribeInstances` (`*`, sunucuyu tag'iyle bulmak için; kaynak seviyesinde kısıtlanamıyor)
  - `ssm:SendCommand` sadece `case1-deploy-app` dokümanı + uygulama sunucusu
  - `ssm:GetCommandInvocation` (`*`): Bu API kaynak seviyesinde yetkilendirmeyi desteklemiyor (AWS Service Authorization Reference'ta resource type tanımlı değil). Sadece komut sonucunu okuyor.
- **`aws_iam_access_key.github`:** Anahtar. Değerleri `sensitive` output, yani sadece `terraform output -raw ...` ile görülebiliyor.

Diğer dosyalar:
- **`.github/workflows/deploy.yml`:** Pipeline.
- **`.github/dependabot.yml`:** Sabitlenmiş action SHA'larını ve `app/` base imajını haftalık kontrol edip güncellemeyi PR olarak açar.
- **`scripts/deploy.sh`:** SSM deploy ve sonucu bekleme.
- **`app/`:** Dockerfile ve sayfa.

---

## Adım adım kurulum

### 1. Altyapıyı kur
```bash
aws login
cd ~/devops-case1/terraform
terraform init
terraform validate
terraform plan
terraform apply
```

### 2. Sunucunun SSM'e kaydolmasını bekle (4-5 dk)
```bash
aws ssm describe-instance-information \
  --query "InstanceInformationList[].{Id:InstanceId,Ping:PingStatus}" --output table
terraform output app_instance_id
```
İki ID eşleşmeli, `Ping` sütunu **Online** olmalı.

### 3. GitHub'da `production` environment'ını ve branch korumasını kur
1. Repo → **Settings → Environments → New environment** → ad: `production`.
2. **Deployment branches and tags** → **Selected branches and tags** → **Add deployment branch or tag rule** → `main`.
3. İsteğe bağlı: **Required reviewers** ile her deploy'dan önce onay iste.
4. Repo → **Settings → Branches → Add branch ruleset** (ya da classic branch protection), hedef `main`:
   - **Require a pull request before merging**
   - **Block force pushes**
   - **Restrict deletions**

### 4. Anahtarı environment secret olarak koy
Değerleri al:
```bash
cd ~/devops-case1/terraform
terraform output -raw github_access_key_id; echo
terraform output -raw github_secret_access_key; echo
```
GitHub'da:
1. Repo → **Settings → Environments → production → Environment secrets → Add environment secret**
   - Name: `AWS_ACCESS_KEY_ID`, Value: ilk çıktı
2. Tekrar **Add environment secret**
   - Name: `AWS_SECRET_ACCESS_KEY`, Value: ikinci çıktı
3. Repo → **Settings → Secrets and variables → Actions → Repository secrets** altında aynı isimde eski secret'lar varsa sil. Environment secret'ı aynı isimdeki repo secret'ını zaten geçersiz kılıyor, ama repo secret'ı kalırsa environment'a bağlı olmayan bir workflow da onu okuyabilir.

> **`gh` CLI kuruluysa** bunu terminalden de yapabilirsin. Anahtar ekranda hiç görünmez:
> ```bash
> cd ~/devops-case1/terraform
> gh secret set AWS_ACCESS_KEY_ID --env production --repo Kkocaoglan/DevOps_Case --body "$(terraform output -raw github_access_key_id)"
> gh secret set AWS_SECRET_ACCESS_KEY --env production --repo Kkocaoglan/DevOps_Case --body "$(terraform output -raw github_secret_access_key)"
> gh secret delete AWS_ACCESS_KEY_ID --repo Kkocaoglan/DevOps_Case
> gh secret delete AWS_SECRET_ACCESS_KEY --repo Kkocaoglan/DevOps_Case
> ```

> ⚠️ **Her `destroy` + `apply` sonrası anahtar değişir.** Bu iki secret'ı tekrar güncellemek gerekir, yoksa pipeline `InvalidClientTokenId` hatası verir.

### 5. Push et ve izle
```bash
cd ~/devops-case1
git status          # tfstate / .ovpn / .pem OLMAMALI
git push
```
GitHub'da **Actions** sekmesini aç ve **Build and Deploy** çalışmasını izle. Son adımın logunda şunlar olmalı:
- `Tarama sonucu (önem seviyesine göre): ...` ve `CRITICAL açık yok, deploy'a geçiliyor.`
- `Doküman: case1-deploy-app` ve `Digest: sha256:...`
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
`app/index.html` dosyasındaki başlığı değiştir, sonra (branch koruması açıksa PR üzerinden):
```bash
cd ~/devops-case1
git commit -am "Başlık güncellendi"
git push
```
1-2 dakika içinde sayfa yeni başlıkla ve yeni SHA ile açılmalı.

### Elle rollback
Sunucuda bir önceki imaj tutuluyor. Önceki digest'i ECR'dan bulup aynı dokümanla deploy et (yönetici kimliğiyle). Not: `nginx-unprivileged` geçişinden önceki imajlar 80'i dinliyor; onlara dönülürse sağlık kontrolü geçmez.
```bash
aws ecr describe-images --repository-name case1-app \
  --query "sort_by(imageDetails,&imagePushedAt)[-2].imageDigest" --output text
bash scripts/deploy.sh sha256:<önceki digest>
```

**Ekran görüntüleri** (`docs/screenshots/`):
- `actions.png`: Yeşil workflow
- `deployed.png`: Tarayıcıda yeni sayfa ve adres çubuğu
- `ecr.png`: ECR'daki imajlar ve tarama sonuçları

---

## Workflow satır satır
- **`on.push.branches: [main]` + `paths`:** Sadece main'de `app/`, `scripts/` ya da workflow dosyası değişince çalışıyor. README'yi düzenlemek deploy tetiklemiyor.
- **`permissions: contents: read`:** Workflow repoya yazamıyor.
- **`concurrency`:** Arka arkaya iki push gelirse deploy'lar üst üste binmiyor, sırayla çalışıyor.
- **`runs-on: ubuntu-24.04`:** `ubuntu-latest` yerine sabit sürüm; runner imajı kendiliğinden değişmiyor.
- **`uses: ...@<commit SHA> # vX.Y.Z`:** Action'lar tag yerine commit SHA ile sabit. Tag taşınsa bile AWS anahtarlarını gören bu job'da değişmiş kod çalışmaz. Güncellemeler Dependabot PR'ı olarak gelir.
- **`if: github.ref == 'refs/heads/main'`:** Elle başka bir branch'ten tetiklense bile job atlanıyor.
- **`environment: production`:** Job, AWS secret'larını bu environment'tan alıyor. Environment'ın deployment branch kuralı sadece `main`'e izin veriyor; required reviewer tanımlıysa deploy onay bekliyor.
- **`configure-aws-credentials`:** Secrets'taki anahtarı ortam değişkenine koyuyor. Sonraki `aws` ve `docker` komutları bununla çalışıyor.
- **`amazon-ecr-login`:** Docker'ı ECR'a login ediyor, registry adresini output olarak veriyor.
- **Build adımı:** Önce `describe-images` ile `case1-app:<kısa sha>` tag'inin ECR'da olup olmadığına bakıyor. Tag'ler IMMUTABLE olduğu için aynı commit tekrar çalıştırılırsa (re-run) push reddedilirdi; bu durumda build/push atlanıp mevcut imajın digest'i kullanılıyor. Yoksa `__VERSION__`'ı kısa SHA ile değiştiriyor, imajı build edip push ediyor ve `docker inspect` ile digest'i alıyor. Digest'in formatını doğrulayıp `$GITHUB_ENV` üzerinden sonraki adımlara aktarıyor.
- **Tarama kapısı:** `aws ecr wait image-scan-complete` ile taramanın bitmesini bekliyor (en fazla ~5 dk), `describe-image-scan-findings` ile önem seviyesine göre bulgu sayılarını yazdırıyor. CRITICAL sayısı 0'dan büyükse adım kırmızı biter ve deploy yapılmaz. Tarama başarısız olursa da deploy yapılmaz (fail-closed).
- **Deploy adımı:** `scripts/deploy.sh` sunucuyu tag'iyle buluyor, `case1-deploy-app` dokümanını digest parametresiyle çağırıyor, sonucu 10 sn arayla en fazla ~5 dk sorguluyor, çıktıyı yazdırıyor. Sonuç `Success` değilse adım kırmızı oluyor.

## Sorun giderme
- **`The security token included in the request is invalid` / `InvalidClientTokenId`:** Secret'lar eski ya da yanlış. 4. adımı tekrarla. destroy/apply sonrası bunu yapmak gerekiyor.
- **`Credentials could not be loaded`:** Secret'ların adı yanlış, Variables sekmesine eklenmiş ya da secret'lar başka bir environment'ta. `production` environment secret'ı olmalılar.
- **Job "Waiting" durumunda kalıyor:** `production` environment'ında required reviewer var, deploy onay bekliyor.
- **`Branch "..." is not allowed to deploy to production`:** Environment'ın deployment branch kuralı tutmuyor; sadece `main`'den deploy edilebilir.
- **`AccessDenied ... ecr:...`:** `aws_iam_user_policy.github`'daki ECR ARN'si yanlış.
- **`AccessDenied ... ssm:SendCommand`:** Doküman adı yanlış (workflow'daki `DEPLOY_DOCUMENT`) ya da `terraform apply` yapılmadığı için doküman yok.
- **`InvalidParameters`:** Digest formatı yanlış. `sha256:` + 64 küçük harf hex olmalı.
- **`HATA: İmajda N CRITICAL açık var, deploy yapılmıyor.`:** Tarama kapısı çalıştı. Base imajı güncelle (Dependabot PR'ı ya da `docker pull` ile en yeni `alpine` sürümü yeniden build), tekrar push et. Bulgular: ECR konsolu → case1-app → imaj → Vulnerabilities.
- **`Waiter ImageScanComplete failed`:** Tarama `FAILED`/`UNSUPPORTED_IMAGE` döndü ya da 5 dk'da bitmedi. ECR konsolunda imajın tarama durumuna bak; geçici bir sorunsa Re-run.
- **`tag invalid ... already exists ... immutable`:** Normalde olmamalı, build adımı tag'i önceden kontrol ediyor. `ecr:DescribeImages` yetkisi eksikse kontrol başarısız olur ve push denenir; `terraform apply` yapıldığından emin ol.
- **Sağlık kontrolü geçmiyor, container `unhealthy`:** İmaj 8080'i dinlemeli; Dockerfile'da `nginxinc/nginx-unprivileged` tabanını değiştirdiysen port eşlemesini (SSM dokümanında `-p 80:8080`) de güncelle.
- **`HATA: Çalışan bir case1-app sunucusu bulunamadı`:** Sunucu kapalı.
- **`InvalidInstanceId`:** Sunucu SSM'e kayıtlı değil. 2. adıma dön. Sunucuda `sudo snap services amazon-ssm-agent` ile agent'ın durumuna bak.
- **SSM `Failed`:** Logdaki "sunucudaki çıktı" bölümüne bak.
  - `aws: command not found` → user_data kurulumu bitmemiş. Sunucuda `sudo tail -50 /var/log/cloud-init-output.log`
  - `curl` adımında hata → container başlamadı. Sunucuda `sudo docker logs web`
- **Durum `Pending`/`InProgress` iken 5 dk doldu:** Sunucu SSM'e ulaşamıyor olabilir (NAT, agent). Komut ID'siyle konsoldan (Systems Manager → Run Command) durumuna bak.
- **Job "skipped":** main dışındaki bir branch'ten çalıştırdın. Beklenen davranış.
