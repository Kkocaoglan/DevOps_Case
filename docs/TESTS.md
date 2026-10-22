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
APP_ID=$(terraform output -raw app_instance_id)
```
Komutlar macOS için yazıldı. macOS'taki `nc`'de bağlantı zaman aşımı `-G` ile verilir (`-w` cevap gelmeyen bağlantıda beklemeyi kesmez); Linux'ta `-G` yerine `-w` kullan.

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
- **Sorun:** OIDC bu hesapta SCP ile yasak olduğu için GitHub Actions bir IAM kullanıcısının kalıcı access key'iyle giriyor. Anahtar GitHub Secrets'ta ve Terraform state'inde duruyor. Son kullanma tarihi yok; sızarsa, elle iptal edilene ya da `destroy` + `apply` yapılana kadar kullanılabilir.
- **Etki alanı (B16 düzeltmesinden sonra):** Sızan anahtarla saldırgan `case1-app` deposuna kendi imajını yükleyip `case1-deploy-app` dokümanıyla uygulama sunucusuna deploy edebilir. Yani sunucuda kendi container'ını çalıştırabilir ve sunucunun ağ erişimini kullanabilir. Sunucuda keyfi komut çalıştıramaz, container'dan rol anahtarlarına ulaşamaz (B4), başka kaynaklara dokunamaz.
- **Kanıt ve sınırı:** Test S10c, S10d, S10e.
- **Çözüm:**
  - OIDC'ye izin veren bir hesapta OIDC'ye geç.
  - Ya da AWS-native CI/CD kullan (CodePipeline + CodeBuild). O yolda kalıcı anahtar yok.
  - Bu yapıda kalınacaksa anahtarı düzenli olarak elle döndür: `terraform apply -replace=aws_iam_access_key.github` ve secret'ları güncelle.
  - IAM'de "Access key last used" bilgisini ve CloudTrail'i izle.
  - Deploy öncesi imaj imzası doğrulaması (ör. cosign/Notation) ile yabancı imajların deploy edilmesini engelle.

### 🔴 B2: Sertifika iptal edilemiyor, herkes aynı sertifikayı kullanıyor
- **Sorun:** Tek bir `client1` sertifikası var. Laptop çalınırsa ya da dosya sızarsa o sertifikayı iptal etmenin yolu yok, CRL tanımlı değil. Kimin bağlandığı da ayırt edilemiyor.
- **Çözüm:**
  - Kişi başına ayrı sertifika üret.
  - Sunucuya `crl-verify` ekle.
  - Kısa geçerlilik süresi kullan.
  - Daha iyisi: MFA ya da SSO. Bunun için AWS Client VPN + IAM Identity Center ya da OpenVPN'in MFA eklentisi kullanılabilir.

### ✅ B3: VPN'e bağlanan herkes VPC'nin tamamına ulaşabiliyordu (bu sürümde düzeltildi)
- **Sorun:** `push "route 10.0.0.0/16"` + IP forwarding ayarı, VPN kullanıcılarını tüm VPC'ye açıyordu. VPC'ye yeni bir veritabanı eklenirse ona da ağ seviyesinde erişebilirlerdi. Sadece Security Group'lar koruyordu.
- **Çözüm (uygulandı):** VPN sunucusunda `iptables` FORWARD zinciri varsayılan DROP. Tünelden sadece private subnet'e (`aws_subnet.private.cidr_block`) TCP 22/80 ve ICMP geçiyor, dönüş trafiği ESTABLISHED/RELATED ile kabul ediliyor. Client'lar birbirine de ulaşamıyor. Kurallar `netfilter-persistent` ile kalıcı.
- **Kanıt:** Test S12, S13.
- **Kalan iyileştirme:** Kullanıcı gruplarına göre farklı tünel IP havuzları ve gruba özel kurallar.

### ✅ B4: Container'lar EC2 rolünün kimlik bilgilerini alabiliyordu (bu sürümde düzeltildi)
- **Sorun:** Ubuntu imajında IMDSv2 zorunluydu, ama `http_put_response_hop_limit = 2` idi. Bu ayar Docker container'larının da metadata servisine ulaşıp sunucunun IAM rolünün geçici anahtarlarını almasına izin veriyordu. Nginx'te bir açık bulunursa saldırgan ECR ve SSM yetkilerini ele geçirebilirdi.
- **Çözüm (uygulandı):** İki `aws_instance`'a da:
  ```hcl
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  ```
  Host üzerindeki süreçler (SSM agent, deploy dokümanındaki `aws ecr get-login-password`) 1 hop'ta olduğu için çalışmaya devam ediyor. Docker bridge'deki container'lar ve VPN client'ları 2. hop'ta kaldığı için token alamıyor.
- **Kanıt:** Test S9, S12.

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

### 🟠 B8: Deploy otomatik rollback yapmıyor (kısmen iyileştirildi)
- **Sorun:** Deploy dokümanı bir `curl` sağlık kontrolü yapıyor, bozuk bir sürümde pipeline kırmızı oluyor. Ama eski container önceden silindiği için site kapalı kalıyor, otomatik geri dönüş yok.
- **Bu sürümde düzeltilenler:**
  - Eski komut listesinde sağlık kontrolü `curl ... && echo OK` biçimindeydi ve arkasından `docker image prune -af` geliyordu. `&&` listesindeki hata `set -e`'yi tetiklemediği için başarısız bir sağlık kontrolü bile `Success` dönebiliyordu. Artık `curl` ayrı satırda, hata script'i durduruyor.
  - `docker image prune -af` bir önceki imajı da siliyordu. Artık bu repodan en yeni 2 imaj (çalışan + önceki) tutuluyor; önceki digest ile doküman tekrar çağrılınca rollback ECR'a gitmeden saniyeler içinde bitiyor.
- **Kanıt:** Test C3, C4.
- **Kalan çözüm:**
  - Yeni container'ı önce farklı bir portta başlat, sağlık kontrolü geçerse trafiği ona çevir (blue/green).
  - Kontrol başarısız olursa önceki digest'e otomatik geri dön.
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
  - ECR tag'leri değiştirilebilir (mutable). Deploy artık digest ile yapıldığı için sunucuya giden imaj tag değişikliğinden etkilenmiyor, ama tag'ler yine de güvenilir bir sürüm kaydı değil.
  - GitHub Actions eylemleri: B24.
- **Çözüm:**
  - Base imajı digest ile sabitle.
  - ECR'da `image_tag_mutability = "IMMUTABLE"` kullan.
  - Dependabot'u aç (Docker base imajı ve eylem sürümleri için).

### 🟡 B14: Diğer küçük bulgular
- SSH anahtarı parolasız oluşturuldu (`-N ""`).
- Uygulama sunucusundaki user_data'da `until apt-get update` sonsuz döngü. NAT bozuksa makine sonsuza kadar bekler. Bir zaman aşımı eklenmeli.
- Nginx sadece HTTP konuşuyor. Trafik laptop ile VPN sunucusu arasında şifreli, ama VPN sunucusu ile uygulama arasında VPC içinde düz metin gidiyor.
- Region, CIDR'lar ve instance tipi koda gömülü. `variables.tf` ve modüllere bölünmeli.
- ECR'daki `force_delete = true` sadece lab ortamı için uygun.

### ✅ B15: AMI kayması (bu sürümde düzeltildi)
- **Sorun:** `data "aws_ami"` sorgusu `most_recent = true` ile yapılıyor. Canonical yeni bir Ubuntu imajı yayınladığında bir sonraki `apply` iki sunucuyu da **silip yeniden oluşturuyordu**. VPN sunucusunun IP'si değişiyor, herkesin bağlantısı kopuyordu.
- **Çözüm:** İki instance'a da `lifecycle { ignore_changes = [ami] }` eklendi. İmaj güncellemesi artık bilinçli olarak yapılıyor: `terraform apply -replace=aws_instance.app`

### ✅ B16: Sızan CI anahtarıyla sunucuda root olarak keyfi komut (bu sürümde düzeltildi)
- **Sorun:** GitHub kullanıcısının `ssm:SendCommand` yetkisi `AWS-RunShellScript` dokümanı üzerindeydi. Anahtar sızarsa uygulama sunucusunda root olarak istenen her komut çalıştırılabilirdi.
- **Çözüm (uygulandı):**
  - `case1-deploy-app` adında özel bir SSM dokümanı. Tek parametresi `ImageDigest`, `^sha256:[a-f0-9]{64}$` ile doğrulanıyor. ECR repo adresi Terraform'dan dokümana gömülü. Doküman sadece ECR login → digest ile pull → container'ı yenile → sağlık kontrolü yapıyor.
  - `ssm:SendCommand` yetkisi sadece bu dokümanın ve uygulama sunucusunun ARN'inde.
  - Pipeline tag yerine digest ile deploy ediyor.
  - `ssm:GetCommandInvocation` hâlâ `*` üzerinde: bu API kaynak seviyesinde yetkilendirmeyi desteklemiyor (AWS Service Authorization Reference'ta resource type tanımlı değil). Sadece komut sonucunu okuyabiliyor. Kullanılmayan `ssm:ListCommandInvocations` kaldırıldı.
- **Kanıt:** Test S10d, S10e.

### ✅ B17: VPN client'ı VPN sunucusunun metadata servisine ulaşabiliyordu (bu sürümde düzeltildi)
- **Sorun:** FORWARD zinciri açıktı. Bir client kendi tarafında `169.254.169.254` için tünele route ekleyerek VPN sunucusunun IMDS'ine ulaşabilir, user_data'yı (içinde sunucunun private key'i ve tls-crypt anahtarı var) okuyabilirdi.
- **Çözüm (uygulandı):** İki katman:
  - `iptables`: tünelden `169.254.0.0/16`'ya giden trafik açıkça DROP, FORWARD varsayılan politikası DROP (B3).
  - IMDS hop limit 1 (B4): IMDSv2 token cevabı bir hop'tan öteye, yani tünele geçemiyor.
- **Kanıt:** Test S12.

### 🟡 B18: Uygulama sunucusunun IAM yetkileri (kısmen düzeltildi)
- ✅ **ECR:** `AmazonEC2ContainerRegistryReadOnly` hesaptaki bütün ECR depolarına okuma veriyordu. Yerine sadece `case1-app` deposundan pull yetkisi veren inline policy (`case1-app-ecr-pull`) geldi.
- **Kalan risk:** `AmazonSSMManagedInstanceCore` SSM agent için gerekli, ama içindeki `ssm:GetParameter*` yetkisi `*` üzerinde. Sunucu ele geçirilirse hesaptaki (KMS ile korunmayan) Parameter Store değerleri okunabilir. Şu an Parameter Store kullanılmıyor.
- **Çözüm:** Parameter Store kullanılmaya başlanırsa managed policy yerine agent'ın ihtiyaç duyduğu `ssm`/`ssmmessages`/`ec2messages` yetkileriyle özel bir policy yaz ve parametre yetkisini belirli bir path'e daralt.

### 🟠 B19: Sertifikalar 1 yıl geçerli, yenileme mekanizması yok
- **Sorun:** CA, sunucu ve client sertifikalarının `validity_period_hours = 8760`. Bir yıl sonra bütün VPN bağlantıları aynı anda kopar. Süreyi izleyen ya da yenileyen bir mekanizma yok.
- **Çözüm:**
  - Client sertifikalarını kısa ömürlü yap ve düzenli yenile, CA'yı daha uzun tut.
  - `tls_locally_signed_cert`'in `early_renewal_hours` ayarıyla süre dolmadan önce `apply`'da yenilenmesini sağla.
  - Sertifika bitiş tarihleri için alarm kur.

### 🟡 B20: Herkes aynı tls-crypt anahtarını kullanıyor
- **Sorun:** `ta.key` bütün client'larda aynı. Bir client'ın dosyası sızarsa tls-crypt koruması (port taramasına görünmezlik, el sıkışmanın şifrelenmesi) herkes için düşer ve anahtarı değiştirmek bütün client'ları etkiler.
- **Çözüm:** `tls-crypt-v2`: her client'a sunucu anahtarıyla sarılmış ayrı bir anahtar verilir, tek bir client'ın anahtarı diğerlerini etkilemez.

### 🟡 B21: Default security group ve NACL yönetilmiyor
- **Sorun:** VPC'nin default security group'u (kendi içinde her şeye izin veren) ve default NACL'i (her şeye izin veren) Terraform'da tanımlı değil. Yanlışlıkla default SG'ye bağlanan bir kaynak beklenmedik erişim kazanabilir, drift de görünmez.
- **Çözüm:** `aws_default_security_group` ile default SG'nin bütün kurallarını boşalt; `aws_default_network_acl` ile default NACL'i kod altına al.

### 🟡 B22: Container root olarak çalışıyor
- **Sorun:** `nginx:alpine` master süreci container içinde root olarak çalışıyor. Container kaçışı gerektiren bir açıkta etki daha büyük olur.
- **Çözüm:** `nginxinc/nginx-unprivileged` (8080'i dinler, root değil) kullan, port eşlemesini `-p 80:8080` yap. Ek olarak `--read-only`, `--cap-drop ALL`, `--security-opt no-new-privileges`.

### 🟠 B23: Branch protection ve environment koruması eksikti
- **Sorun:** `main`'e doğrudan push ve force-push açıktı. AWS secret'ları repo seviyesindeydi; repo'ya yazma yetkisi olan biri secret'ları okuyan bir workflow ekleyebilirdi.
- **Kısmen düzeltildi:** Deploy job'u `environment: production`'a bağlandı.
- **Elle yapılması gereken (GitHub ayarı):** `main` için PR zorunluluğu ve force-push yasağı; `production` environment'ında deployment branch kuralı (sadece `main`), istenirse required reviewer; secret'ların repo secret'tan environment secret'a taşınması. Adımlar: CICD.md, 3. ve 4. adım.

### 🟡 B24: GitHub Actions eylemleri tag ile sabitlenmiş
- **Sorun:** `actions/checkout@v4`, `aws-actions/configure-aws-credentials@v4`, `aws-actions/amazon-ecr-login@v2` tag ile çağrılıyor. Tag'ler taşınabilir; eylemin deposu ele geçirilirse kötü amaçlı kod, AWS anahtarlarına erişimi olan job'da çalışır.
- **Çözüm:** Eylemleri tam commit SHA'sıyla sabitle (yanına sürüm yorumu yaz), Dependabot ile güncelle.

### ✅ B25: Provider sürümleri üstten sınırsızdı (bu sürümde düzeltildi)
- **Sorun:** `>= 6.23.0` gibi kısıtlar `terraform init -upgrade`'de bir sonraki major sürümün (kırıcı değişikliklerle) gelmesine izin veriyordu.
- **Çözüm (uygulandı):** `~> 6.23`, `~> 4.0`, `~> 3.5`, `~> 2.4`. Lock dosyası `darwin_arm64` ve `linux_amd64` hash'leriyle commit'li. `.gitignore`'a `*.tfvars`, `*.key`, crash logları eklendi.

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
  Beklenen: `open|filtered`. `tls-crypt` sayesinde sunucu yabancı paketlere hiç cevap vermiyor, nmap portun açık olduğundan bile emin olamıyor (port taramasına karşı görünmezlik).

- **S3. NAT Gateway'e içeriden bağlantı denemesi:**
  ```bash
  NAT_IP=$(aws ec2 describe-nat-gateways --filter Name=tag:Name,Values=case1-nat \
    --query "NatGateways[0].NatGatewayAddresses[0].PublicIp" --output text)
  nc -vz -G 5 $NAT_IP 80
  nc -vz -G 5 $NAT_IP 22
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
  nc -vz -G 3 $APP_IP 80     # başarılı olmalı
  nc -vz -G 3 $APP_IP 8080   # zaman aşımı olmalı (SG izin vermiyor)
  nc -vz -G 3 $APP_IP 443    # zaman aşımı olmalı
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
  - Beklenen (B4 düzeltmesinden sonra): İlk komut boş dönmeli (token cevabı container'a ulaşmıyor), ikinci komut `401` / boş dönmeli.
  - Düzeltmeden önceki durum: Rol adı (`case1-app-ec2-role`) dönüyordu, yani bir container rolün geçici anahtarlarına ulaşabiliyordu.
  - Karşı kontrol, host'un kendisi hâlâ erişebilmeli: `TOKEN=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token) && curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/` rol adını dönmeli.

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

- **S10c. Sızan anahtarın etki alanı (least privilege testi):** GitHub kullanıcısının anahtarıyla yetkisi olmayan şeyler dene. S10d ve S10e de aynı oturumda çalıştırılıyor, `unset` en sonda:
  ```bash
  export AWS_ACCESS_KEY_ID=$(terraform output -raw github_access_key_id)
  export AWS_SECRET_ACCESS_KEY=$(terraform output -raw github_secret_access_key)
  export AWS_DEFAULT_REGION=eu-north-1
  aws sts get-caller-identity                # case1-github-actions kullanıcısı görünmeli
  aws s3 ls                                  # AccessDenied olmalı
  aws ec2 terminate-instances --instance-ids $APP_ID --dry-run   # UnauthorizedOperation olmalı
  aws ecr describe-repositories              # AccessDenied olmalı
  aws ssm describe-instance-information      # AccessDenied olmalı
  ```
  Bu test anahtarın sadece deploy için gereken yetkilere sahip olduğunu gösteriyor. Sınırı: anahtar `case1-app`'e imaj push edip `case1-deploy-app` ile deploy edebiliyor (B1b).

- **S10d. Sızan anahtarla keyfi komut denemesi (B16'nın kanıtı):** S10c'deki oturumda:
  ```bash
  aws ssm send-command --instance-ids $APP_ID --document-name AWS-RunShellScript \
    --parameters 'commands=["id"]'
  ```
  Beklenen: `AccessDeniedException ... is not authorized to perform: ssm:SendCommand on resource: arn:aws:ssm:eu-north-1::document/AWS-RunShellScript`.

- **S10e. Özel dokümana geçersiz digest (parametre doğrulaması):** S10c'deki oturumda:
  ```bash
  aws ssm send-command --instance-ids $APP_ID --document-name case1-deploy-app \
    --parameters 'ImageDigest=latest'
  aws ssm send-command --instance-ids $APP_ID --document-name case1-deploy-app \
    --parameters '{"ImageDigest":["sha256:0000000000000000000000000000000000000000000000000000000000000000; id"]}'
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
  ```
  Beklenen: İkisi de `InvalidParameters` hatası vermeli, komut sunucuya hiç gönderilmemeli. İkinci deneme, digest'in arkasına komut eklemenin (enjeksiyon) regex'e takıldığını gösteriyor.

  **Sonuç (2026-10-22):** S10c, S10d ve S10e beklendiği gibi: S3/EC2/ECR `AccessDenied`, `AWS-RunShellScript` `AccessDeniedException`, geçersiz ve enjeksiyonlu digest `InvalidParameters`. Kanıt: [`screenshots/leaked-key-tests.png`](screenshots/leaked-key-tests.png) (hesap numarası maskeli).

- **S10b. OIDC yasağının kanıtı (README'deki tasarım kararının gerekçesi):**
  ```bash
  aws iam list-open-id-connect-providers
  ```
  - Beklenen: Listeleme bile `explicit deny in a service control policy` hatası verebilir ya da boş dönebilir. Bu hesapta identity provider kullanılamadığının kanıtı. README'deki tasarım değişikliğinin gerekçesi bu.

- **S12. VPN client'ından VPN sunucusunun IMDS'ine ulaşma (B17'nin kanıtı):** VPN bağlıyken macOS'ta. Önce tünel arayüzünü bul (macOS `10.0.0.0/16` route'unu `10/16` olarak gösteriyor, son sütun `utunX`):
  ```bash
  netstat -rn -f inet | grep utun
  sudo route -n add -host 169.254.169.254 -interface utunX
  curl -s -m 5 -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token; echo "exit=$?"
  sudo route -n delete -host 169.254.169.254
  ```
  - Beklenen (düzeltmeden sonra): `curl` zaman aşımına uğramalı (`exit=28`), token dönmemeli.
  - Düzeltmeden önce: Bir token dönebiliyordu; o token ile `http://169.254.169.254/latest/user-data` okunup sunucu private key'i alınabiliyordu.
  - Route'u silmeyi unutma.

  **Sonuç (2026-10-22):** `utun6` üzerinden PUT isteği 5 sn'de zaman aşımına uğradı (`exit=28`), token dönmedi. Geçti.

- **S13. VPN FORWARD kuralları:**
  ```bash
  ssh -i ~/.ssh/case1 ubuntu@$VPN_PRIV "sudo iptables -S FORWARD"
  nc -vz -G 3 $APP_IP 80          # başarılı olmalı
  ping -c 2 $APP_IP               # cevap vermeli
  ssh -i ~/.ssh/case1 ubuntu@$VPN_PRIV true && echo "VPN sunucusuna SSH OK"   # INPUT etkilenmemeli
  # İzin verilmeyen hedef: public subnet. DROP politikasının sayacı artmalı.
  ssh -i ~/.ssh/case1 ubuntu@$VPN_PRIV "sudo iptables -L FORWARD -v -n | head -1"
  nc -vz -G 3 10.0.1.10 80        # zaman aşımı (macOS'ta bağlantı süresi -G ile sınırlanır, -w yetmez)
  ssh -i ~/.ssh/case1 ubuntu@$VPN_PRIV "sudo iptables -L FORWARD -v -n | head -1"
  ```
  Beklenen: `iptables -S` çıktısında `-P FORWARD DROP`, `169.254.0.0/16 ... DROP` ve sadece private subnet için 22/80/ICMP `ACCEPT` kuralları olmalı. `Chain FORWARD (policy DROP N packets ...)` satırındaki paket sayısı `nc` denemesinden sonra artmalı, yani paket VPN sunucusunda düşürülmüş olmalı. R1'den (reboot) sonra da aynı kurallar gelmeli.

  **Sonuç (2026-10-22):** Kurallar beklendiği gibi (`-P FORWARD DROP`, 169.254/16 DROP, sadece `10.0.2.0/24` için 22/80/ICMP; çıkış arayüzü `ens5`, dinamik bulunuyor). `$APP_IP:80` ve ping başarılı. Public subnet denemesinden sonra DROP politikası sayacı 0 → 10 paket. Geçti.

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
  - Beklenen: Deploy dokümanındaki `curl` sağlık kontrolü başarısız olur, SSM durumu `Failed` olur ve pipeline **kırmızı** biter. Logda `SAGLIK_KONTROLU_OK` görünmemeli. Ama eski container o sırada silinmiş olduğu için **site kapanır.** Yani hata görünür hale geliyor, ama otomatik rollback yok (B8).
  - Sunucuda önceki imaj hâlâ durmalı: `sudo docker images --digests` en az iki `case1-app` imajı göstermeli (temizlik sadece başarılı deploy'dan sonra yapılıyor).
  - Geri almak için satırı silip tekrar push et ya da C4'ü uygula.
- **C4. Eski sürüme dönüş (rollback):**
  ```bash
  PREV=$(aws ecr describe-images --repository-name case1-app \
    --query "sort_by(imageDetails,&imagePushedAt)[-2].imageDigest" --output text)
  time bash ../scripts/deploy.sh "$PREV"
  ```
  - Beklenen: Önceki imaj sunucuda zaten olduğu için `docker pull` hemen biter, site eski sürümle geri gelir.
  - Rollback'in ne kadar sürdüğünü ölç. Bu süre, otomatik rollback'in (B8) neden gerekli olduğunu gösteriyor.

---

## 3. İyileştirme yol haritası (öncelik sırasıyla)
1. **Hemen ve ucuz:**
   - ~~IMDS hop limit 1 (B4)~~ ✅
   - ~~Özel SSM deploy dokümanı, digest ile deploy (B16)~~ ✅
   - Branch protection + `production` environment ayarları (B23, GitHub'da elle)
   - EBS şifreleme (B5)
   - VPN için Elastic IP (B10)
   - `source_dest_check = true` (B11)
   - Otomatik rollback (B8)
   - Default SG'yi boşaltmak (B21), container'ı root olmayan kullanıcıyla çalıştırmak (B22), eylemleri SHA ile sabitlemek (B24)
2. **Kısa vadede:**
   - Remote state: S3 + KMS + lockfile (B1)
   - Secrets Manager (B1)
   - Kişi başı sertifika ve CRL (B2)
   - ~~iptables ile VPN segmentasyonu (B3)~~ ✅
   - Sertifika yenileme mekanizması (B19), tls-crypt-v2 (B20)
   - Terraform PR pipeline'ı (B9)
3. **Orta vadede:**
   - VPC Flow Logs, CloudWatch, alarmlar, CloudTrail (B7)
   - VPC endpoint'leri ile NAT'ı kaldırmak (B12)
   - İmaj ve eylemleri sabitleme (B13)
4. **Ölçek ve erişilebilirlik:**
   - Çoklu AZ, ASG + internal ALB (B6)
   - AWS Client VPN + SSO/MFA ile OpenVPN sunucusunu tamamen yönetilen bir servise bırakmak
