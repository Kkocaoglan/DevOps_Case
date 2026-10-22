# DevOps Case 1: VPN arkasında private uygulama (AWS + Terraform)

Bir e-ticaret şirketinin iç uygulamasını, **internetten hiçbir şekilde erişilemeyen** bir private subnet'te çalıştıran ve sadece **OpenVPN ile kimliği doğrulanmış kullanıcıların** erişebildiği altyapı.

Bütün altyapı **Terraform** ile tanımlı. Tek bir `terraform apply` ile VPN sunucusu, sertifikalar ve uygulama sunucusu dahil her şey sıfırdan, yaklaşık 5 dakikada kuruluyor. Elle yapılan bir adım yok.

---

## Mimari

![Mimari](docs/architecture.png)

<details>
<summary>Mermaid kaynağı (GitHub otomatik çizer)</summary>

```mermaid
flowchart LR
    dev["Geliştirici laptopu<br/>OpenVPN client"]
    net(("İnternet"))
    gh["GitHub Actions"]
    subgraph aws["AWS eu-north-1"]
        iam["IAM kullanıcısı<br/>dar yetki"]
        ecr["ECR"]
        ssm["SSM Run Command"]
        subgraph vpc["VPC 10.0.0.0/16"]
            igw["Internet Gateway"]
            subgraph pub["Public subnet 10.0.1.0/24"]
                vpn["EC2 OpenVPN<br/>SG: sadece UDP 1194"]
                nat["NAT Gateway"]
            end
            subgraph priv["Private subnet 10.0.2.0/24"]
                app["EC2 Docker + Nginx<br/>public IP yok"]
            end
        end
    end
    dev -- "UDP 1194 tünel" --> net --> igw --> vpn
    vpn -- "HTTP 80 / SSH 22" --> app
    app -- "sadece çıkış" --> nat --> igw
    gh -- "access key (GitHub Secrets)" --> iam
    gh -- "docker push" --> ecr
    gh -- "send-command<br/>(sadece case1-deploy-app)" --> ssm
    ssm -.- app
    app -.-> ecr
```
</details>

### Bileşenler
- **VPC `10.0.0.0/16`:** Uygulamanın yaşadığı izole ağ.
- **Public subnet `10.0.1.0/24`:** Route table'ında `0.0.0.0/0 → Internet Gateway` yolu var. Burada sadece iki şey duruyor: VPN sunucusu ve NAT Gateway.
- **Private subnet `10.0.2.0/24`:** IGW'ye giden yolu yok, sadece `0.0.0.0/0 → NAT Gateway` yolu var. Makineler public IP almıyor.
- **OpenVPN sunucusu (EC2):** İnternete açık **tek kapı**, UDP 1194. VPN istemcilerinden gelen trafiği private subnet'e iletiyor (IP forwarding + NAT/MASQUERADE). `iptables` FORWARD zinciri sadece private subnet'e SSH/HTTP/ICMP'ye izin veriyor.
- **Uygulama sunucusu (EC2):** Docker içinde Nginx çalışıyor. Sadece VPN sunucusunun Security Group'undan gelen trafiği kabul ediyor.
- **NAT Gateway:** Private sunucunun **dışarıya** çıkabilmesi için var: paket kurulumu, `docker pull`, SSM. İçeriye doğru bağlantı kabul etmiyor.
- **CI/CD:** GitHub Actions imajı build edip **ECR**'a push ediyor, sonra private sunucuya **SSM Run Command** ile, sadece bu iş için yazılmış `case1-deploy-app` dokümanını kullanarak imaj digest'iyle deploy ediyor.

### Bir isteğin yolculuğu (laptop → Nginx)
1. Laptopta tarayıcıya `http://10.0.2.x` yazılıyor. OpenVPN'in eklediği route, `10.0.0.0/16` trafiğini tünele yönlendiriyor.
2. Paket şifrelenip UDP 1194 üzerinden VPN sunucusunun public IP'sine gidiyor (IGW → VPN SG kontrolü).
3. VPN sunucusu paketi açıyor. `iptables` FORWARD kuralları hedefin private subnet ve portun 22/80 (ya da ICMP) olduğunu kontrol ediyor. Paket IP forwarding ile private subnet'e iletiliyor, iletirken MASQUERADE ile kaynak adresi VPN sunucusunun private IP'sine çevriliyor.
4. Uygulama sunucusunun Security Group'u paketin VPN SG'sinden geldiğini görüyor ve 80 numaralı porta izin veriyor.
5. Nginx cevap veriyor. Cevap aynı yoldan tünele, oradan laptopa dönüyor.

---

## Güvenlik kararları ve gerekçeleri

1. **Private sunucunun public IP'si ve IGW yolu yok.** İnternetten erişimi engelleyen asıl şey routing. Security Group bunun üstüne ikinci bir katman.
2. **İnternete açık tek port UDP 1194.** SSH internete kapalı. Sunuculara yönetim erişimi sadece VPN tünelinin içinden yapılıyor (`ssh ubuntu@<vpn_private_ip>`). Tünelden gelen trafik VPN sunucusunun içinde açıldığı için Security Group'a uğramıyor.
3. **Karşılıklı sertifika doğrulaması (mutual TLS).** Hem sunucu hem client, aynı CA tarafından imzalanmış sertifika gösteriyor. `remote-cert-tls server` ayarı, geçerli bir client sertifikasıyla sahte sunucu kurulmasını engelliyor.
4. **`tls-crypt`.** Doğru paylaşılan anahtarı göstermeyen paketlere sunucu hiç cevap vermiyor. Port taramalarına karşı UDP 1194 "kapalı" gibi görünüyor, el sıkışma da şifreli gidiyor.
5. **Security Group'lar IP yerine birbirine referans veriyor.** Uygulama SG'si "VPN SG'sinden gelen" trafiğe izin veriyor. VPN sunucusunun IP'si değişse bile kural geçerliliğini koruyor.
6. **OpenVPN root yetkilerini bırakıyor.** `user nobody` / `group nogroup` ayarı sayesinde servis başladıktan sonra yetkisiz kullanıcıya geçiyor.
7. **Split tunnel.** Tünelden sadece `10.0.0.0/16` trafiği geçiyor. Kullanıcının normal internet trafiği şirkete taşınmıyor.
8. **SSH anahtarı lokalde üretiliyor.** Private key bilgisayardan hiç çıkmıyor, AWS'ye sadece public key yükleniyor.
9. **CI/CD anahtarı dar yetkili.** GitHub Actions bir IAM kullanıcısının access key'iyle giriyor (OIDC bu hesapta SCP ile yasak, aşağıda trade-off'lar bölümüne bak). Anahtar sadece GitHub Secrets'ta (`production` environment'ında) duruyor, fork PR'ları secret'lara erişemiyor, workflow sadece `main` branch'inde çalışıyor. Anahtarın **son kullanma tarihi yok**; sadece `destroy` + `apply` ile siliniyor ve yenisi üretiliyor.
10. **En az yetki, ama sınırları belli.** GitHub kullanıcısı sadece `case1-app` ECR reposuna push edebiliyor ve sadece uygulama sunucusunda, sadece `case1-deploy-app` SSM dokümanını çalıştırabiliyor. Anahtar sızarsa saldırgan **ECR'a kendi imajını yükleyip bu dokümanla deploy edebilir** (yani uygulama sunucusunda kendi container'ını çalıştırabilir), ama sunucuda keyfi komut çalıştıramaz, başka sunuculara, S3'e ya da IAM'e dokunamaz.
11. **Özel SSM dokümanı.** `AWS-RunShellScript` yetkisi yok. Deploy dokümanının tek parametresi imaj digest'i ve `^sha256:[a-f0-9]{64}$` ile doğrulanıyor; repo adresi Terraform'dan dokümana gömülü. Dışarıdan gelen hiçbir değer kabuğa serbest metin olarak girmiyor.
12. **Tag yerine digest ile deploy.** Sunucuya tam olarak pipeline'ın build ettiği imaj gidiyor; tag sonradan başka bir imaja taşınsa bile deploy edilen imaj değişmiyor. Sunucuda bir önceki imaj da tutuluyor (lokal rollback için).
13. **IMDSv2 zorunlu, hop limit 1 (iki EC2'de de).** Instance metadata'sına sadece makinenin kendisi erişebiliyor. Docker container'ları ve VPN client'ları rolün geçici anahtarlarını alamıyor.
14. **VPN sunucusunda `iptables` FORWARD kısıtı.** Varsayılan politika DROP. Tünelden sadece private subnet'e TCP 22/80 ve ICMP geçiyor; `169.254.0.0/16` (VPN sunucusunun metadata servisi) açıkça engelli. VPN kullanıcıları VPC'nin geri kalanına ve birbirlerine ulaşamıyor.
15. **Uygulama sunucusunun ECR yetkisi daraltılmış.** Sadece `case1-app` deposundan imaj çekebiliyor (managed `AmazonEC2ContainerRegistryReadOnly` yerine inline policy).
16. **SSM ile deploy, port açmadan.** SSM agent NAT üzerinden AWS'ye **dışarıya doğru** bağlanıyor. Deploy için hiçbir gelen port açılmıyor.
17. **ECR taraması ve deploy kapısı.** `scan_on_push` açık; pipeline taramanın bitmesini bekliyor ve imajda CRITICAL açık varsa (ya da tarama başarısızsa) deploy etmiyor.
18. **ECR tag'leri değiştirilemez (IMMUTABLE).** Bir sürümün tag'i sonradan başka bir imaja taşınamaz.
19. **Container root olarak çalışmıyor.** İmaj `nginx-unprivileged` tabanlı (uid 101, port 8080, sunucuda 80 → 8080) ve `HEALTHCHECK` içeriyor.
20. **GitHub Actions eylemleri commit SHA ile sabit.** Dependabot eylem ve base imaj güncellemelerini PR olarak açıyor; `main` korumalı (PR zorunlu, force-push yok).
21. **VPC'nin default security group'u boş.** Terraform'a alındı, bütün kuralları silindi; yanlışlıkla ona bağlanan bir kaynak hiçbir trafik alamaz.
22. **Gizli dosyalar Git'te yok.** `.gitignore` ile state, `.ovpn`, key ve `.tfvars` dosyaları repodan hariç tutuluyor. Provider sürümleri `~>` ile üstten sınırlı, lock dosyası commit'li.

### Bilerek kabul edilen trade-off'lar
- **Sertifika private key'leri Terraform state'inde ve EC2 user_data'sında duruyor.** Bu sayede kurulum tamamen otomatik. Üretim ortamında state şifreli bir remote backend'de (S3 + KMS) tutulmalı, sertifikalar da Secrets Manager'dan IAM rolüyle çekilmeli.
- **CI/CD için kalıcı access key.** İlk tasarım GitHub Actions + OIDC'ydi. Ama bu hesap AWS'nin yeni kayıt deneyimiyle açıldı ve üstündeki değiştirilemeyen SCP `iam:*Provider*` işlemlerini yasaklıyor (`AccessDenied ... explicit deny in a service control policy`). GitHub Actions'ta kalmak için bir IAM kullanıcısının access key'i kullanıldı. Anahtarın son kullanma tarihi yok; sadece `destroy` + `apply` ile yenileniyor. Risk dar yetki (özel SSM dokümanı, tek ECR deposu) ve secret'ların sadece main branch'inden çalışan `production` environment'ında tutulmasıyla sınırlandı. Sızan bir anahtar yine de uygulama sunucusuna saldırganın imajını deploy etmeye yetiyor. OIDC'ye izin veren bir hesapta doğru çözüm OIDC olurdu. Alternatif olarak AWS CodePipeline + CodeBuild de denendi, o yolda kalıcı anahtar hiç gerekmiyor.
- **IAM kullanıcısında `force_destroy = false`.** Bu ayar `true` olduğunda Terraform destroy sırasında kullanıcının login profile'ını da silmeye çalışıyor ve SCP `iam:*LoginProfile*` işlemlerini yasakladığı için hata veriyor. Access key ayrı bir Terraform kaynağı olduğu için destroy'da zaten siliniyor.
- **`AmazonSSMManagedInstanceCore` geniş.** SSM agent için gerekli bu managed policy `ssm:GetParameter*` yetkisini `*` üzerinde veriyor. Uygulama sunucusu ele geçirilirse hesaptaki (KMS ile korunmayan) Parameter Store değerleri okunabilir. Şu an Parameter Store kullanılmıyor; kullanılırsa özel bir policy ile daraltılmalı.
- **Tek AZ, tek NAT, tek VPN sunucusu.** Maliyet için. Yüksek erişilebilirlik gerekirse ikinci bir AZ eklenmeli.
- Tam liste ve iyileştirme önerileri: [docs/TESTS.md](docs/TESTS.md)

---

## Repo yapısı
```
.
├── terraform/
│   ├── main.tf        # provider'lar, VPC, subnet'ler, IGW, public route table
│   ├── pki.tf         # CA, sunucu ve client sertifikaları, tls-crypt anahtarı
│   ├── vpn.tf         # VPN SG + OpenVPN EC2 (user_data ile otomatik kurulum)
│   ├── private.tf     # NAT, private route table, app SG + app EC2
│   ├── client.tf      # client1.ovpn dosyasını lokale üretir
│   └── cicd.tf        # ECR, EC2 IAM rolü, deploy SSM dokümanı, GitHub Actions için dar yetkili IAM kullanıcısı
├── app/
│   ├── Dockerfile
│   └── index.html
├── .github/
│   ├── workflows/deploy.yml
│   └── dependabot.yml # action SHA'ları ve base imaj güncellemeleri
├── scripts/deploy.sh  # SSM (case1-deploy-app) ile digest deploy + sonucu bekleme
└── docs/
    ├── architecture.png / architecture.mmd
    ├── CICD.md        # CI/CD kurulum rehberi
    ├── TESTS.md       # test planı, bulgular, iyileştirmeler
    └── screenshots/
```

---

## Kurulum

### Gereksinimler
- AWS hesabı ve AWS CLI v2.32+ (`aws login` ile giriş)
- Terraform 1.x
- OpenVPN Connect (ya da Tunnelblick)
- SSH anahtarı: `ssh-keygen -t ed25519 -f ~/.ssh/case1`

### Adımlar
```bash
aws login
cd terraform
terraform init
terraform apply
```
1. Apply bitince makinelerin kendi kurulumlarını tamamlaması için **3-4 dakika bekle.**
2. `terraform/client1.ovpn` dosyasını OpenVPN Connect'e yükle ve bağlan.
3. Test et:
   ```bash
   terraform output
   ping -c 3 $(terraform output -raw app_private_ip)
   curl http://$(terraform output -raw app_private_ip)
   ```
4. Yönetim erişimi (VPN bağlıyken):
   ```bash
   ssh -i ~/.ssh/case1 ubuntu@$(terraform output -raw vpn_private_ip)
   ssh -i ~/.ssh/case1 ubuntu@$(terraform output -raw app_private_ip)
   ```

## CI/CD
`app/` klasörüne yapılan her push şu adımları tetikliyor:
```
GitHub Actions (production environment) → access key → docker build → ECR push (IMMUTABLE tag) → tarama kapısı (CRITICAL yoksa) → digest → SSM (case1-deploy-app) ile private sunucuda pull + restart + sağlık kontrolü
```
Kurulum adımları: [docs/CICD.md](docs/CICD.md)

## Doğrulama
- `docs/screenshots/vpn-on.png`: VPN açıkken uygulama açılıyor.
- `docs/screenshots/vpn-off.png`: VPN kapalıyken uygulama açılmıyor.
- `docs/screenshots/actions.png`: Başarılı bir CI/CD çalışması.
- `docs/screenshots/deployed.png`: Deploy edilen versiyon.
- `docs/screenshots/leaked-key-tests.png`: Sızan CI anahtarıyla yetki testleri (S10c/S10d/S10e): keyfi komut `AccessDenied`, geçersiz digest `InvalidParameters`.

## Maliyet (yaklaşık)
- **NAT Gateway:** Saatlik ücret ve işlenen veri başına ücret. Bu altyapıdaki en büyük kalem.
- **Public IPv4:** VPN sunucusu ve NAT'ın Elastic IP'si için saatlik ücret.
- **2 × t3.micro:** Free Tier kapsamında.

Kullanılmadığında `terraform destroy` ile her şey kapatılıyor.

## Temizlik
```bash
cd terraform
terraform destroy
```
