# Test planı, bulgular ve iyileştirmeler

Bu dosya üç soruyu cevaplıyor:
1. **Bu sistemde ne yanlış ya da zayıf?** (Bulgular)
2. **Gerçekten iddia ettiğimiz gibi çalışıyor mu? Kırılınca ne oluyor?** (Testler)
3. **Gerçek bir şirkette neyi farklı yapardık?** (Yol haritası)

Testlerin çoğu VPN bağlıyken, `terraform/` klasöründen çalıştırılıyor. Kolaylık için:
```bash
cd ~/devops-case1/terraform
VPN_IP=$(terraform output -raw vpn_public_ip)
VPN_PRIV=$(terraform output -raw vpn_private_ip)
APP_IP=$(terraform output -raw app_private_ip)
```

---

## 1. Bulgular (kendi sistemime eleştirel bakış)

Önem seviyeleri: 🔴 yüksek · 🟠 orta · 🟡 düşük · ✅ bu sürümde düzeltildi

### 🔴 B1: Private key'ler state'te ve user_data'da
- **Sorun:** CA, sunucu ve client private key'leri `terraform.tfstate` dosyasında düz metin olarak duruyor. Sunucu key'i ayrıca EC2 user_data'sında. `ec2:DescribeInstanceAttribute` yetkisi olan herkes bu key'leri okuyabilir.
- **Kanıt:** Test S7 ve S8.
- **Çözüm:**
  - State'i S3 backend'e taşı: KMS ile şifreleme ve `use_lockfile = true`.
  - Sertifikaları Secrets Manager'a koy. user_data sadece "secret'ı IAM rolüyle çek" komutunu içersin.

### 🔴 B1b: CI/CD için kalıcı access key
- **Sorun:** OIDC bu hesapta SCP ile yasak olduğu için GitHub Actions bir IAM kullanıcısının kalıcı access key'iyle giriyor. Anahtar GitHub Secrets'ta ve Terraform state'inde duruyor. Sızarsa, süresi dolmadığı için kullanılabilir.
- **Kanıt ve sınırı:** Test S10c. Yetki çok dar, sadece tek bir ECR deposuna push ve tek bir sunucuda SSM komutu.
- **Çözüm:**
  - OIDC'ye izin veren bir hesapta OIDC'ye geç.
  - Ya da AWS-native CI/CD kullan (CodePipeline + CodeBuild). O yolda kalıcı anahtar yok.
  - Bu yapıda kalınacaksa anahtarı düzenli döndür (rotate). Burada her destroy/apply bunu kendiliğinden yapıyor.
  - IAM'de "Access key last used" bilgisini ve CloudTrail'i izle.

### 🔴 B2: Sertifika iptal edilemiyor, herkes aynı sertifikayı kullanıyor
- **Sorun:** Tek bir `client1` sertifikası var. Laptop çalınırsa ya da dosya sızarsa o sertifikayı iptal etmenin yolu yok, CRL tanımlı değil. Kimin bağlandığı da ayırt edilemiyor.
- **Çözüm:**
  - Kişi başına ayrı sertifika üret.
  - Sunucuya `crl-verify` ekle.
  - Kısa geçerlilik süresi kullan.
  - Daha iyisi: MFA ya da SSO. Bunun için AWS Client VPN + IAM Identity Center ya da OpenVPN'in MFA eklentisi kullanılabilir.

### 🟠 B3: VPN'e bağlanan herkes VPC'nin tamamına ulaşabiliyor
- **Sorun:** `push "route 10.0.0.0/16"` + IP forwarding ayarı, VPN kullanıcılarını tüm VPC'ye açıyor. VPC'ye yeni bir veritabanı eklenirse ona da ağ seviyesinde erişebilirler. Şimdilik sadece Security Group'lar koruyor.
- **Çözüm:**
  - VPN sunucusunda `iptables` FORWARD zincirini varsayılan DROP yap.
  - Sadece `APP_IP:80` ve `APP_IP:22`'ye izin ver.
  - Kullanıcı gruplarına göre farklı tünel IP havuzları kullan.

### 🟠 B4: Container'lar EC2 rolünün kimlik bilgilerini alabiliyor (IMDS hop limit 2)
- **Sorun:** Ubuntu imajında IMDSv2 zorunlu (iyi), ama `http_put_response_hop_limit = 2`. Bu ayar Docker container'larının da metadata servisine ulaşıp sunucunun IAM rolünün geçici anahtarlarını almasına izin veriyor. Nginx'te bir açık bulunursa saldırgan ECR ve SSM yetkilerini ele geçirebilir.
- **Kanıt:** Test S9.
- **Çözüm:** `aws_instance`'a şunu ekle:
  ```hcl
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  ```
  Bu ayardan sonra sunucunun kendisi metadata servisine erişmeye devam eder, container'lar erişemez.

### 🟠 B5: EBS diskleri şifreli değil
- **Sorun:** Plan çıktısında `encrypted = false` görünüyor.
- **Çözüm:** `root_block_device { encrypted = true }` ekle ya da hesap genelinde "EBS encryption by default" ayarını aç.

### 🟠 B6: Tek nokta arızası (SPOF)
- **Sorun:** Tek AZ, tek NAT, tek VPN sunucusu, tek uygulama sunucusu. AZ ya da makine çökerse servis durur.
- **Çözüm:**
  - İki AZ kullan, her AZ'ye bir NAT koy.
  - Uygulama için Auto Scaling Group ve iç load balancer (internal ALB) kullan.
  - VPN için ikinci bir sunucu ya da yönetilen AWS Client VPN kullan.
  - Bunların hepsi maliyeti artırır, karar ihtiyaca göre verilmeli.

### 🟠 B7: Logging ve monitoring yok
- **Sorun:** VPC Flow Logs, CloudWatch logları ve alarm yok. Bir saldırı ya da arıza olursa geriye dönük bakılacak bir kayıt yok.
- **Çözüm:**
  - VPC Flow Logs'u aç, CloudWatch'a ya da S3'e gönder.
  - OpenVPN'e `status` ve `log` dosyalarını ekle, CloudWatch agent ile topla.
  - CPU, disk ve StatusCheckFailed için alarm kur.
  - CloudTrail'i aç.

### 🟠 B8: Deploy rollback yapmıyor
- **Sorun:** `deploy.sh` bir `curl` sağlık kontrolü yapıyor, bozuk bir sürümde pipeline kırmızı oluyor. Ama eski container önceden silindiği için site kapalı kalıyor, otomatik geri dönüş yok.
- **Kanıt:** Test C3.
- **Çözüm:**
  - Yeni container'ı önce farklı bir portta başlat, sağlık kontrolü geçerse trafiği ona çevir (blue/green).
  - Kontrol başarısız olursa önceki tag'e otomatik geri dön.
  - Dockerfile'a `HEALTHCHECK` ekle.

### 🟠 B9: Altyapı kodu için CI yok
- **Sorun:** Terraform değişiklikleri kimse incelemeden, otomatik bir kontrolden geçmeden uygulanıyor.
- **Çözüm:** PR açıldığında çalışan ayrı bir workflow:
  - `terraform fmt -check`
  - `terraform validate`
  - `tflint`
  - `checkov` / `trivy config`
  - `terraform plan` çıktısını PR'a yorum olarak ekle.
  - `apply` sadece onaydan sonra.

### 🟡 B10: VPN public IP'si sabit değil
- **Sorun:** VPN sunucusu her yeniden oluşturulduğunda IP değişiyor ve bütün kullanıcıların `.ovpn` dosyası bozuluyor.
- **Çözüm:** VPN sunucusuna bir Elastic IP bağla. Maliyeti zaten ödenen public IP ile aynı. Bir de DNS kaydı ekle: `vpn.sirket.com`.

### 🟡 B11: `source_dest_check = false` gereksiz
- **Sorun:** MASQUERADE kullandığımız için paketler zaten VPN sunucusunun kendi IP'siyle çıkıyor. Kontrolü kapatmak gereksiz bir yetki.
- **Çözüm:** `true` yap ve test et. NAT'sız, saf yönlendirmeye geçilirse tekrar kapatmak gerekir.

### 🟡 B12: Giden trafik tamamen açık
- **Sorun:** İki Security Group'ta da egress `0.0.0.0/0`, yani her port her yere açık.
- **Çözüm:** Uygulama sunucusunda egress'i 443'e (ECR, SSM, apt) ve DNS'e daralt. Daha da iyisi VPC endpoint'leri kullanmak (ECR, SSM, S3), böylece NAT'a bile gerek kalmaz.

### 🟡 B13: Tedarik zinciri
- **Sorun:**
  - `nginx:alpine` imajı bir tag'e değil "son sürüm"e bağlı.
  - GitHub Actions eylemleri SHA ile değil tag ile sabitlenmiş.
  - ECR tag'leri değiştirilebilir (mutable).
- **Çözüm:**
  - Base imajı digest ile sabitle.
  - GitHub Actions eylemlerini (`actions/checkout@v4` gibi) commit SHA'sıyla sabitle.
  - Dependabot ile eylem sürümlerini takip et.
  - ECR'da `image_tag_mutability = "IMMUTABLE"` kullan.
  - Dependabot'u aç.

### 🟡 B14: Diğer küçük bulgular
- SSH anahtarı parolasız oluşturuldu (`-N ""`).
- Uygulama sunucusundaki user_data'da `until apt-get update` sonsuz döngü. NAT bozuksa makine sonsuza kadar bekler. Bir zaman aşımı eklenmeli.
- Nginx sadece HTTP konuşuyor. Trafik laptop ile VPN sunucusu arasında şifreli, ama VPN sunucusu ile uygulama arasında VPC içinde düz metin gidiyor.
- Region, CIDR'lar ve instance tipi koda gömülü. `variables.tf` ve modüllere bölünmeli.
- ECR'daki `force_delete = true` sadece lab ortamı için uygun.

### ✅ B15: AMI kayması (bu sürümde düzeltildi)
- **Sorun:** `data "aws_ami"` sorgusu `most_recent = true` ile yapılıyor. Canonical yeni bir Ubuntu imajı yayınladığında bir sonraki `apply` iki sunucuyu da **silip yeniden oluşturuyordu**. VPN sunucusunun IP'si değişiyor, herkesin bağlantısı kopuyordu.
- **Çözüm:** İki instance'a da `lifecycle { ignore_changes = [ami] }` eklendi. İmaj güncellemesi artık bilinçli olarak yapılıyor: `terraform apply -replace=aws_instance.app`

---

## 2. Testler

Her testin bir **beklenen sonucu** var. Sonuç beklenenden farklıysa bir bulgu daha bulmuşsun demektir.

### A. Fonksiyonel testler (çalışıyor mu?)
- **F1. VPN bağlantısı:** OpenVPN Connect "Connected" göstermeli. `ping -c 3 10.8.0.1` cevap vermeli.
- **F2. Uygulamaya erişim:** `curl -s http://$APP_IP` HTML dönmeli.
- **F3. Tünel üzerinden yönetim:** `ssh -i ~/.ssh/case1 ubuntu@$VPN_PRIV` ve `ssh -i ~/.ssh/case1 ubuntu@$APP_IP` bağlanmalı.
- **F4. Private sunucunun dışarı çıkışı:** Uygulama sunucusunda `curl -sI https://www.google.com | head -1` komutu `HTTP/2 200` dönmeli. NAT çalışıyor demek.
- **F5. Tekrarlanabilirlik:**
  - `terraform destroy` ve ardından `time terraform apply` çalıştır.
  - Apply ~3 dakika sürmeli, kurulum için de ~4 dakika beklemek gerekiyor.
  - Elle hiçbir adım yapmadan sistem çalışır hale gelmeli.
  - Süreyi README'ye yaz.

### B. Güvenlik ve negatif testler (saldırgan gözüyle)
**Ön hazırlık:** `brew install nmap`

- **S1. İnternetten port taraması (VPN kapalıyken):**
  ```bash
  sudo nmap -Pn -sS --top-ports 1000 $VPN_IP
  ```
  Beklenen: Bütün TCP portları `filtered`. SSH dahil hiçbir TCP portu görünmemeli.

- **S2. VPN portunun görünürlüğü:**
  ```bash
  sudo nmap -Pn -sU -p 1194 $VPN_IP
  ```
  Beklenen: `open|filtered`. `tls-crypt` sayesinde sunucu yabancı paketlere hiç cevap vermiyor, nmap portun açık olduğundan bile emin olamıyor. Bunu README'de "port taramasına karşı görünmezlik" olarak anlatabilirsin.

- **S3. NAT Gateway'e içeriden bağlantı denemesi:**
  ```bash
  NAT_IP=$(aws ec2 describe-nat-gateways --filter Name=tag:Name,Values=case1-nat \
    --query "NatGateways[0].NatGatewayAddresses[0].PublicIp" --output text)
  nc -vz -w 5 $NAT_IP 80
  nc -vz -w 5 $NAT_IP 22
  ```
  Beklenen: İkisi de zaman aşımı. NAT gelen bağlantı kabul etmiyor.

- **S4. Sertifika olmadan bağlanma:**
  - `client1.ovpn` dosyasını `bad.ovpn` olarak kopyala.
  - Kopyadan `<tls-crypt>...</tls-crypt>` bloğunu sil.
  - Bu dosyayla bağlanmayı dene.
  - Beklenen: Bağlantı kurulamamalı ("TLS key negotiation failed").
  - Sunucu logunda reddedilen paketleri görebilirsin:
    ```bash
    ssh -i ~/.ssh/case1 ubuntu@$VPN_PRIV \
      "sudo journalctl -u openvpn-server@server -n 30 --no-pager"
    ```
    Bu komutu normal VPN bağlantısıyla çalıştır.

- **S5. VPN içinden izin verilmeyen portlar:**
  ```bash
  nc -vz -w 3 $APP_IP 80     # başarılı olmalı
  nc -vz -w 3 $APP_IP 8080   # zaman aşımı olmalı (SG izin vermiyor)
  nc -vz -w 3 $APP_IP 443    # zaman aşımı olmalı
  ```

- **S6. Uygulama sunucusunun public IP'si yok:**
  ```bash
  aws ec2 describe-instances --filters Name=tag:Name,Values=case1-app \
    --query "Reservations[].Instances[].PublicIpAddress"
  ```
  Beklenen: `[]` ya da `null`.

- **S7. user_data'dan key sızıntısı (B1'in kanıtı):**
  ```bash
  VPN_ID=$(aws ec2 describe-instances --filters Name=tag:Name,Values=case1-vpn Name=instance-state-name,Values=running \
    --query "Reservations[0].Instances[0].InstanceId" --output text)
  aws ec2 describe-instance-attribute --instance-id $VPN_ID --attribute userData \
    --query "UserData.Value" --output text | base64 --decode | grep -c "PRIVATE KEY"
  ```
  Beklenen: `0`'dan büyük bir sayı. Hesaba okuma yetkisiyle giren biri sunucunun private key'ini görebiliyor. Bulgu B1 bu.

- **S8. State dosyasında key'ler:**
  ```bash
  grep -c "PRIVATE KEY" terraform.tfstate
  ```
  Beklenen: `0`'dan büyük bir sayı. State dosyasının neden Git'e konmadığının kanıtı.

- **S9. Container'dan IAM kimlik bilgisi çalma (B4'ün kanıtı):** Uygulama sunucusunda (SSH ile):
  ```bash
  TOKEN=$(sudo docker run --rm curlimages/curl -s -X PUT \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token)
  sudo docker run --rm curlimages/curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/
  ```
  - Beklenen (şu anki durum): Rol adı (`case1-app-ec2-role`) dönüyor. Yani bir container rolün geçici anahtarlarına ulaşabiliyor.
  - B4'teki düzeltmeden sonra: İlk komut boş dönmeli.

- **S10. Başka bir branch'ten deploy denemesi:**
  ```bash
  git checkout -b test-branch
  echo "<!-- test -->" >> app/index.html
  git commit -am "branch test"
  git push -u origin test-branch
  ```
  - Beklenen: Push workflow'u tetiklememeli, çünkü `on.push.branches` sadece `main`.
  - Actions → Build and Deploy → **Run workflow** de ve branch olarak `test-branch`'i seç. Beklenen: job **skipped** olmalı, çünkü `if: github.ref == 'refs/heads/main'` koşulu tutmuyor.
  - Sonra temizle: `git checkout main && git branch -D test-branch && git push origin --delete test-branch`

- **S10c. Sızan anahtarın etki alanı (least privilege testi):** GitHub kullanıcısının anahtarıyla yetkisi olmayan bir şey dene:
  ```bash
  export AWS_ACCESS_KEY_ID=$(terraform output -raw github_access_key_id)
  export AWS_SECRET_ACCESS_KEY=$(terraform output -raw github_secret_access_key)
  aws s3 ls                                  # AccessDenied olmalı
  aws ec2 terminate-instances --instance-ids $(terraform output -raw app_instance_id) --dry-run   # UnauthorizedOperation olmalı
  aws ecr describe-repositories              # AccessDenied olmalı (sadece push var)
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  ```
  Bu test, anahtar sızsa bile saldırganın neredeyse hiçbir şey yapamayacağını kanıtlıyor. README'deki trade-off'un savunması bu.

- **S10b. OIDC yasağının kanıtı (README'deki tasarım kararının gerekçesi):**
  ```bash
  aws iam list-open-id-connect-providers
  ```
  - Beklenen: Listeleme bile `explicit deny in a service control policy` hatası verebilir ya da boş dönebilir. Bu hesapta identity provider kullanılamadığının kanıtı. README'deki tasarım değişikliğinin gerekçesi bu.

- **S11. Statik analiz:**
  ```bash
  pip install checkov
  checkov -d terraform --compact
  ```
  - Çıkan uyarıları bu listedeki bulgularla karşılaştır. Bilinen trade-off'lar için `#checkov:skip=...` ile gerekçeli istisna ekleyebilirsin.
  - `brew install tflint && tflint --chdir terraform` da dene.

### C. Dayanıklılık ve "sistemi bozma" testleri
- **R1. VPN sunucusunu yeniden başlat:**
  ```bash
  ssh -i ~/.ssh/case1 ubuntu@$VPN_PRIV "sudo reboot"
  ```
  - Bağlantı kopar.
  - Beklenen: 1-2 dakika içinde OpenVPN Connect kendiliğinden yeniden bağlanmalı. `ping $APP_IP` tekrar çalışmalı.
  - Bu test `systemctl enable` ve `netfilter-persistent` ayarlarının işe yaradığını kanıtlıyor.

- **R2. Uygulama sunucusunu yeniden başlat:**
  ```bash
  ssh -i ~/.ssh/case1 ubuntu@$APP_IP "sudo reboot"
  ```
  Beklenen: 1-2 dakika sonra `curl http://$APP_IP` tekrar çalışmalı. Container'daki `--restart unless-stopped` ayarı bunu sağlıyor.

- **R3. Container çökmesi:** Uygulama sunucusunda:
  ```bash
  sudo docker exec web nginx -s quit
  sleep 5
  sudo docker ps
  sudo docker inspect -f '{{.RestartCount}}' web
  ```
  Beklenen: Container tekrar "Up" durumunda olmalı, RestartCount 1 artmalı.

- **R4. OpenVPN servisini yeniden başlat:**
  ```bash
  ssh -i ~/.ssh/case1 ubuntu@$VPN_PRIV "sudo systemctl restart openvpn-server@server"
  ```
  Beklenen: Client birkaç saniye içinde yeniden bağlanmalı. `keepalive 10 120` ayarı burada devreye giriyor.

- **R5. Drift (elle yapılan değişikliği yakalama):**
  1. Console'da `case1-vpn-sg`'ye elle bir kural ekle: TCP 22, kaynak `0.0.0.0/0`. Bu, "biri acil durumda kapıyı açtı ve kapatmayı unuttu" senaryosu.
  2. `terraform plan` çalıştır. Terraform bu kuralı silmek istemeli.
  3. `terraform apply` ile düzelt.

  Bu test IaC'nin neden önemli olduğunu gösteriyor: altyapının gerçek durumu her zaman koddaki duruma geri getirilebiliyor. Bunu düzenli bir zamanlanmış `plan` ile otomatik yakalamak da bir iyileştirme fikri.

- **R6. NAT yolunu kopar:**
  1. Console'da `case1-private-rt`'den `0.0.0.0/0` route'unu sil.
  2. Uygulama sunucusunda `curl -m 5 -sI https://www.google.com` zaman aşımına uğramalı.
  3. Site çalışmaya devam etmeli, çünkü VPN trafiği NAT'a bağlı değil.
  4. CI/CD deploy'u ise başarısız olmalı, çünkü SSM ve ECR NAT'a bağlı.
  5. `terraform apply` ile geri getir.

  Bu test "hangi parça neye bağlı" sorusunu cevaplıyor.

### D. CI/CD testleri
- **C1. Normal deploy:** `index.html`'i değiştir ve push et. Actions'ta bütün adımlar yeşil olmalı, sayfadaki versiyon yeni SHA'ya dönmeli.
- **C2. Build hatası:**
  - Dockerfile'a `RUN exit 1` satırını ekle ve push et.
  - Beklenen: Pipeline build adımında kırmızı olmalı. Hiçbir şey deploy edilmemeli, site eski sürümle çalışmaya devam etmeli.
  - Sonra satırı geri al.
- **C3. Bozuk ama build olan imaj (sağlık kontrolünün testi):**
  - Dockerfile'a `CMD ["nginx", "-g", "bozuk_ayar;"]` satırını ekle ve push et.
  - Beklenen: `deploy.sh`'teki `curl` sağlık kontrolü başarısız olur ve pipeline **kırmızı** biter. Ama eski container o sırada silinmiş olduğu için **site kapanır.** Yani hata görünür hale geliyor, ama otomatik rollback yok (B8).
  - Geri almak için satırı silip tekrar push et. İstersen ECR'daki eski SHA'yı elle de deploy edebilirsin.
- **C4. Eski sürüme dönüş (rollback):**
  - ECR'da bir önceki imajın tag'ini (SHA) bul.
  - Bu SHA ile SSM'den elle `docker run` çalıştır.
  - Rollback'in elle ne kadar sürdüğünü ölç. Bu süre, otomasyonun neden gerekli olduğunu gösteriyor.

---

## 3. İyileştirme yol haritası (öncelik sırasıyla)
1. **Hemen ve ucuz:**
   - IMDS hop limit 1 (B4)
   - EBS şifreleme (B5)
   - VPN için Elastic IP (B10)
   - `source_dest_check = true` (B11)
   - Deploy sağlık kontrolü ve rollback (B8)
2. **Kısa vadede:**
   - Remote state: S3 + KMS + lockfile (B1)
   - Secrets Manager (B1)
   - Kişi başı sertifika ve CRL (B2)
   - iptables ile VPN segmentasyonu (B3)
   - Terraform PR pipeline'ı (B9)
3. **Orta vadede:**
   - VPC Flow Logs, CloudWatch, alarmlar, CloudTrail (B7)
   - VPC endpoint'leri ile NAT'ı kaldırmak (B12)
   - İmaj ve eylemleri sabitleme (B13)
4. **Ölçek ve erişilebilirlik:**
   - Çoklu AZ, ASG + internal ALB (B6)
   - AWS Client VPN + SSO/MFA ile OpenVPN sunucusunu tamamen yönetilen bir servise bırakmak

Mülakatta bu listeden 3-4 maddeyi, **neden** önemli olduklarıyla birlikte anlatmak, sadece "çalışıyor" demekten çok daha güçlü bir izlenim bırakır.
