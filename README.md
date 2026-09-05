# 🏥 PACS Gateway - Unified VFS Cache Architecture

Bu repo, hastane PACS verilerini **Huawei Cloud OBS**'ye taşıyan, **tek SMB path** üzerinden şeffaf cache-first erişim sağlayan, **izlenebilir** (Grafana dashboard'ı otomatik deploy edilir) ve **alarmlı** bir gateway sisteminin kurulumunu otomatikleştirir.

> **v2 → v3 değişikliği:** Önceki sürümde `PACS_Local` (yazma) / `PACS_Archive` (salt okunur) diye iki ayrı SMB share, bir inotify upload-watcher ve ayrı bir cleanup cron job'ı vardı. Bu, local diskin OBS ile aynı boyuta çıkmasını zorunlu kılıyordu ve kullanıcıların hangi share'e bağlanacağını manuel bilmesini gerektiriyordu. v3'te tek bir **rclone VFS cache mount** var: kullanıcı tek path'e bağlanır, rclone dosyanın local cache'te mi OBS'te mi olduğuna arka planda kendisi karar verir.
>
> **v3 → v3.1 (bu sürüm) değişikliği:** Grafana artık **boş** açılmıyor. Önceki sürümde `docker-compose.yml` var olmayan bir `./provisioning` klasörünü mount ediyordu ve dashboard'ı elle import etmeniz gerekiyordu. Bu sürümde Prometheus datasource'u ve VFS cache dashboard'ı (JSON) `deploy.sh` çalıştığı anda **otomatik** olarak provision edilir. Ayrıca `node-exporter`'a eksik olan `--path.rootfs` bayrağı eklendi — bu bayrak olmadan cache disk doluluk alarmları (`CacheDiskSpaceWarning`/`Critical`) hiçbir zaman gerçek durumu yansıtmıyordu, çünkü metrik etiketleri container-içi path'e göre geliyordu.

---

## 📌 Özellikler

- ✅ **Tek path, tek SMB share** — okuma da yazma da aynı yerden
- ✅ **Rclone VFS cache mount** — local disk sınırlı bir cache, OBS source-of-truth
- ✅ **Prometheus + Grafana** ile gerçek zamanlı izleme (gerçek mount metrikleri)
- ✅ **Grafana dashboard'ı otomatik deploy edilir** — kurulumdan hemen sonra "PACS Gateway" klasöründe hazır bekler, elle import gerekmez
- ✅ **Alertmanager** ile e-posta alarmı
- ✅ **Tek script** ile sıfırdan kurulum

---

## 🏗️ Mimari

**1. Host'ta (Systemd) Çalışan Servisler**
- **`rclone-mount-obs.service`** → OBS bucket'ını **tek** bir SMB path'e (`MOUNT_PATH`) VFS cache ile bağlar; cache'in fiziksel dosyaları ayrı bir `CACHE_DIR`'de tutulur. Mount'un kendi `--rc` arayüzü aynı zamanda Prometheus'un okuduğu metrikleri (`:5572`) üretir.
- **`smbd`** → `MOUNT_PATH`'i Windows SMB ile paylaşır (okuma + yazma).

**2. Docker Compose ile Çalışan Servisler**
- **Prometheus** → Metrik toplar (gerçek mount'tan, boş bir RC daemon'dan değil)
- **Grafana** → Görselleştirme ve alarm; datasource + dashboard **otomatik provision edilir**
- **Alertmanager** → E-posta alarm yönetimi
- **Node Exporter** → Sistem/disk metrikleri (`--path.rootfs` ile gerçek host path'lerini raporlar)

| Bileşen | Çalışma Ortamı | Başlatma |
|---------|---------------|----------|
| Rclone mount (OBS, RC dahil) | Host | Systemd |
| Samba (SMB) | Host | Systemd |
| Prometheus | Docker | Compose |
| Grafana | Docker | Compose |
| Alertmanager | Docker | Compose |
| Node Exporter | Docker | Compose |

### Veri Akışı

```
Windows/Fuji <--SMB--> \\IP\PACS (MOUNT_PATH)
                            │
                     rclone VFS cache
                    (cache dosyaları: CACHE_DIR)
                            │
                       Huawei OBS (source of truth)
```

Okuma: cache'te varsa direkt local'den, yoksa OBS'ten indirilip cache'e alınır.
Yazma: önce cache'e yazılır, `--vfs-write-back` gecikmesiyle arka planda OBS'e gönderilir.
Eviction: `--vfs-cache-max-age` (LRU, erişim zamanına göre) + `--vfs-cache-max-size` (sert üst sınır) ikilisiyle otomatik yönetilir — **manuel silme/cron yok**.

> ⚠️ `--vfs-cache-max-age`, dosyanın *üretim tarihine* göre değil *son erişimine* göre çalışır. "Kesin 90 gün" garantisi gerekiyorsa (sık açılan eski dosyanın cache'te kalmaması gibi), bunun üzerine ayrı bir politika eklenmesi gerekir — bu repo sadece "sıcak pencere" yaklaşımını otomatikleştirir.

### İzleme, Alarm ve Dashboard Otomasyon Akışı

```
rclone mount --rc (:5572/metrics) ─┐
node-exporter (:9100, --path.rootfs)├─→ Prometheus (scrape) ─→ Grafana (auto-provisioned) ─→ Alertmanager (e-posta)
                                    ┘
```

`deploy.sh` çalıştığında:
1. `grafana/provisioning/datasources/datasource.yml` → Prometheus'u Grafana'ya otomatik datasource olarak tanıtır.
2. `grafana/provisioning/dashboards/dashboard.yml` → Grafana'ya `/var/lib/grafana/dashboards` klasöründeki JSON'ları otomatik yüklemesini söyler.
3. `grafana/dashboards/pacs-gateway-overview.json` → İçindeki `__CACHE_DIR__` yer tutucusu gerçek `$CACHE_DIR` değeriyle doldurulup kopyalanır (tıpkı `alert.rules.yml` ile aynı mantık).

Sonuç: Grafana açıldığında **"PACS Gateway" klasöründe "VFS Cache Overview" dashboard'ı elle hiçbir şey yapmadan hazır bulunur.**

### Klasör Yapısı

```
pacs-gateway/
├── config/
│   └── rclone.conf                        # Rclone yapılandırma şablonu (OBS bağlantısı)
├── prometheus/
│   ├── prometheus.yml
│   └── alert.rules.yml
├── alertmanager/
│   └── alertmanager.yml
├── grafana/
│   ├── grafana.ini
│   ├── dashboards/
│   │   └── pacs-gateway-overview.json     # Dashboard JSON şablonu (__CACHE_DIR__ deploy.sh'ta doldurulur)
│   └── provisioning/
│       ├── datasources/
│       │   └── datasource.yml             # Prometheus'u otomatik datasource yapar
│       └── dashboards/
│           └── dashboard.yml              # Dashboard JSON'larını otomatik yükletir
├── systemd/
│   └── rclone-mount-obs.service           # Unified mount şablonu (envsubst ile dolduruluyor)
├── docker-compose.yml
├── deploy.sh                              # Tek komutla kurulum script'i
└── README.md
```

---

## 📋 Gereksinimler

- Ubuntu **22.04** veya **24.04**
- Root veya sudo erişimi
- `rclone` kurulu olmalı (`curl https://rclone.org/install.sh | sudo bash`)
- Huawei Cloud OBS **Access Key**, **Secret Key**, bucket adı, endpoint
- SMTP mail hesabı (alarm bildirimleri için)

---

## 🚀 Kurulum

```bash
git clone https://github.com/yigitfurkann/pacs-gateway-fixed-v2.git /opt/pacs-gateway-src
cd /opt/pacs-gateway-src
chmod +x deploy.sh
sudo ./deploy.sh
```

Script iki ayrı dizin soracak, ikisini karıştırma:

| Soru | Ne işe yarar |
|------|--------------|
| **SMB Mount Path** (`MOUNT_PATH`) | Windows'un `\\IP\PACS` üzerinden gördüğü tek path (FUSE mount noktası) |
| **VFS Cache Dizini** (`CACHE_DIR`) | Cache dosyalarının fiziksel olarak diskte durduğu yer — disk doluluk alarmları, `--vfs-cache-max-size` VE Grafana dashboard'ındaki cache disk panelleri BURAYA göre çalışır |

`VFS Cache Max Size` zorunlu bir alan — varsayılanı yok, kendi disk kapasitene göre (`CACHE_DIR`'in bulunduğu diskin ~%85'i kadar) elle girmen gerekiyor.

---

## ▶️ Servis Yönetimi

```bash
sudo systemctl status rclone-mount-obs smbd
sudo journalctl -u rclone-mount-obs -f

cd /opt/pacs-gateway
docker compose ps
docker compose logs -f
```

Cache'ten bir dosyayı manuel "unutturup" OBS'ten yeniden çektirmek (test için):

```bash
curl -u $RC_USER:$RC_PASS -X POST http://localhost:5572/vfs/forget -d 'file=RELATIVE/PATH.dcm'
```

---

## 🌐 Erişim Noktaları

| Servis | URL / Bilgi |
|--------|-------------|
| SMB Paylaşımı | `\\<SUNUCU_IP>\PACS` (okuma+yazma) |
| Grafana | `http://<SUNUCU_IP>:3000` (admin/admin) — "PACS Gateway" klasöründe dashboard otomatik hazır |
| Prometheus | `http://<SUNUCU_IP>:9090` |
| Rclone RC/Metrics | `http://<SUNUCU_IP>:5572` |
| Alertmanager | `http://<SUNUCU_IP>:9393` |

---

## 🪟 Windows Makineden Erişim (SMB)

```cmd
net use Z: \\<SUNUCU_IP>\PACS /user:pacsuser "password" /persistent:yes
dir Z:\
```

**Hata 53 (Network path not found):** Huawei Cloud güvenlik grubunda **Inbound TCP 445** (ve 139) açık mı kontrol edin.

**Hata 5 (Access denied):** `sudo pdbedit -L` ile kullanıcıyı doğrulayın, gerekirse `sudo smbpasswd -a pacsuser`.

**Samba config kontrolü:**
```bash
sudo testparm -s /etc/samba/smb.conf
```
Çıktıda tek bir `[PACS]` bloğu olmalı, `[PACS_Local]`/`[PACS_Archive]` artık yok.

---

## ⚠️ Alarm Kuralları

| Alarm | Açıklama |
|-------|----------|
| RcloneServiceDown | Mount'un RC/metrics endpoint'i yanıt vermiyor |
| RcloneTransferStalled | Aktif transfer var ama 5 dakikadır veri akışı 0 B/s |
| CacheDiskSpaceWarning | Cache diski %80 dolu |
| CacheDiskSpaceCritical | Cache diski %90 dolu — yazma hataları başlayabilir |

> Önceki sürümdeki `SambaServiceDown` alarmı kaldırıldı: `up{job="samba"}` diye bir Prometheus hedefi hiç scrape edilmiyordu, yani bu alarm hiçbir zaman gerçek Samba durumunu yansıtmıyordu. Samba'nın kendisini izlemek istersen ayrıca `blackbox_exporter` (445 portu TCP probe) eklemek gerekir — bu repo'da yok.
>
> Cache disk alarmlarının **gerçekten** tetiklenebilmesi için `node-exporter`'ın `--path.rootfs=/rootfs` bayrağıyla çalışması şart (bu sürümde eklendi). Bu bayrak olmadan `node_filesystem_*` metriklerinin `mountpoint` etiketi container-içi bir path olarak gelir ve `alert.rules.yml`'deki gerçek `$CACHE_DIR` değeriyle hiçbir zaman eşleşmez.

---

## 📊 Grafana Dashboard'ı

`deploy.sh` çalıştıktan sonra Grafana'da elle hiçbir işlem yapmadan **"PACS Gateway" klasörü → "VFS Cache Overview"** dashboard'ı hazır bulunur. İçerdiği paneller:

- Rclone mount durumu (UP/DOWN)
- Aktif transfer sayısı
- Cache disk doluluk (gauge + zaman serisi)
- Cache disk boş alan
- Toplam transfer edilen veri
- OBS transfer hızı (B/s)
- Sistem CPU & RAM kullanımı
- Aktif Prometheus alarmları tablosu

---

## 🛠️ Sorun Giderme

```bash
# Mount çalışıyor mu?
sudo systemctl status rclone-mount-obs
sudo journalctl -u rclone-mount-obs -f
mount | grep pacs-gateway

# Samba
sudo systemctl status smbd
smbclient //localhost/PACS -U pacsuser

# Metrikler gerçekten geliyor mu?
curl -u $RC_USER:$RC_PASS http://localhost:5572/metrics
# Prometheus targets sayfası: http://<SUNUCU_IP>:9090/targets

# Dashboard otomatik provision oldu mu?
curl -u admin:admin http://localhost:3000/api/search?query=PACS

# Alarm e-postası gelmiyor
cat /opt/pacs-gateway/alertmanager/alertmanager.yml
docker exec -it pacs-grafana curl -v smtp.gmail.com:587
```

---

## 🧪 Uçtan Uca Test Senaryoları

### Senaryo 1 — VFS Cache davranışı (1 saatlik cache ile)

Bu senaryo, `VFS Cache Max Age = 1h` seçtiğinizde sistemin gerçekten "local'de yoksa OBS'ten çek" davranışını yapıp yapmadığını doğrular. Gerçek 90 günlük prod ayarında da mantık birebir aynıdır, sadece bekleme süresi değişir.

**0) Kurulumu 1 saatlik cache ile yap**

```bash
sudo ./deploy.sh
# Sorulduğunda:
#   VFS Cache Max Age -> 1h
#   VFS Cache Max Size -> test için küçük bir değer girebilirsin, örn. 5G
```

**1) Windows Server'dan path'e bağlan**

```powershell
# PowerShell (Admin)
net use Z: \\<SUNUCU_IP>\PACS /user:pacsuser "SIFRE" /persistent:yes
Get-PSDrive Z
```

**2) Test dosyası yaz**

```powershell
"test icerigi $(Get-Date)" | Out-File -Encoding utf8 Z:\test.txt
Get-Content Z:\test.txt
```

Sunucu tarafında hemen kontrol et — dosya önce **local cache diskinde** görünür:

```bash
ls -la $CACHE_DIR   # gerçek cache dosyaları burada (vfs cache içyapısı)
tail -f /opt/pacs-gateway/logs/rclone-mount.log | grep test.txt
```

`--vfs-write-back 15s` sonra arka planda OBS'e gönderilir. Doğrulama:

```bash
rclone lsf obs:${BUCKET_NAME} --config /etc/rclone/rclone.conf | grep test.txt
```

**3) "Cache'ten düşürüp yeniden çektirme" testi (manuel forget ile hızlandırma)**

```bash
curl -u $RC_USER:$RC_PASS -X POST http://localhost:5572/vfs/forget -d 'file=test.txt'
ls -la $CACHE_DIR | grep test.txt   # artık burada görünmemeli
```

Windows tarafında tekrar oku:

```powershell
Get-Content Z:\test.txt
```

Sunucu logunda OBS'ten yeniden indirildiğini gör:

```bash
tail -f /opt/pacs-gateway/logs/rclone-mount.log | grep test.txt
```

**4) Doğal (manuel forget'sız) eviction'ı izleme**

```bash
watch -n 60 'ls -la $CACHE_DIR | grep test.txt'
```

1 saat sonra satırın kaybolduğunu, ardından tekrar okuma yapıldığında yeniden bir OBS indirmesi olduğunu görmelisin.

**Özet tablo**

| Adım | Windows'ta ne yapılır | Sunucuda ne olur |
|------|------------------------|-------------------|
| Yazma | `Out-File Z:\test.txt` | Önce `$CACHE_DIR`'e yazılır, 15s sonra OBS'e gönderilir |
| Sıcak okuma (cache'te) | `Get-Content Z:\test.txt` | Direkt `$CACHE_DIR`'den, hızlı |
| Cache süresi dolunca / manuel forget | (hiçbir şey, path aynı) | Dosya `$CACHE_DIR`'den silinir, OBS'te kalır |
| Soğuk okuma (cache'te yok) | `Get-Content Z:\test.txt` (aynı komut) | OBS'ten indirilir, `$CACHE_DIR`'e tekrar yazılır, sonra sunulur |

---

### Senaryo 2 — Grafana dashboard'ının otomatik deploy testi

Kurulum bitince, elle hiçbir import yapmadan dashboard'ın gerçekten geldiğini doğrula:

```bash
# 1) Grafana ayakta mı?
curl -s http://<SUNUCU_IP>:3000/api/health

# 2) Datasource otomatik eklendi mi?
curl -s -u admin:admin http://<SUNUCU_IP>:3000/api/datasources | grep -i prometheus

# 3) Dashboard otomatik provision oldu mu?
curl -s -u admin:admin http://<SUNUCU_IP>:3000/api/search?query=PACS

# 4) Tarayıcıdan doğrula
# http://<SUNUCU_IP>:3000 -> admin/admin -> Dashboards -> "PACS Gateway" klasörü -> "VFS Cache Overview"
```

Beklenen: 3. adım `pacs-gateway-overview` uid'li bir sonuç döndürmeli. Dönmüyorsa `docker logs pacs-grafana` ile provisioning hatasına bak.

---

### Senaryo 3 — Cache disk alarmının gerçekten tetiklendiğini doğrulama

`--path.rootfs` düzeltmesinin işe yaradığını doğrulamak için:

```bash
# 1) node-exporter'ın doğru mountpoint etiketiyle veri verdiğini kontrol et
curl -s http://<SUNUCU_IP>:9100/metrics | grep node_filesystem_avail_bytes | grep "$CACHE_DIR"
# Bir satır dönmeli; boşsa --path.rootfs mount'u/flag'i hatalı demektir

# 2) Prometheus tarafında aynı sorguyu kontrol et
# Tarayıcı: http://<SUNUCU_IP>:9090/graph
# Sorgu: node_filesystem_avail_bytes{mountpoint="<CACHE_DIR_DEGERINIZ>"}

# 3) Alarmı yapay olarak tetiklemek için CACHE_DIR'i doldur (test/lab ortamında!)
fallocate -l <disk_boyutunun_%85i> $CACHE_DIR/fill_test.tmp

# 4) Alertmanager'da alarmın düştüğünü gör
curl -s http://<SUNUCU_IP>:9393/api/v2/alerts | grep CacheDiskSpace

# 5) Testi temizle
rm -f $CACHE_DIR/fill_test.tmp
```

---

### Senaryo 4 — Rclone servis kesintisi alarmı

```bash
# Mount servisini kasıtlı durdur
sudo systemctl stop rclone-mount-obs

# ~1 dakika sonra Alertmanager'da RcloneServiceDown görünmeli
curl -s http://<SUNUCU_IP>:9393/api/v2/alerts | grep RcloneServiceDown

# Mail kutunuza [PACS-ALERT] RcloneServiceDown başlıklı bir e-posta düşmeli

# Testi bitir, servisi geri aç
sudo systemctl start rclone-mount-obs
```

---

## 📧 Alarm E-postası Örneği

Alertmanager, `alertmanager.yml`'deki `email-admin` receiver'ı üzerinden aşağıdaki formatta bir e-posta gönderir (konu satırı `alertmanager.yml`'de tanımlıdır):

```
Konu: [PACS-ALERT] CacheDiskSpaceCritical

Alarm: CacheDiskSpaceCritical
Severity: critical
Durum: firing
Özet: VFS cache disk %90 dolu!
Açıklama: Disk alanı kritik seviyede. rclone --vfs-cache-min-free-space
          eşiği zorlanıyor olabilir, yazma hataları başlayabilir.
Başlangıç: <timestamp>
```

Alarm koşulu ortadan kalktığında (`send_resolved: true` sayesinde) aynı kanaldan bir **resolved** bildirimi de gelir.

---

## 🗑️ Tamamen Kaldırma

```bash
sudo fusermount -uz $MOUNT_PATH
sudo systemctl disable --now rclone-mount-obs smbd
cd /opt/pacs-gateway && docker compose down -v
sudo rm -rf /opt/pacs-gateway $MOUNT_PATH $CACHE_DIR /etc/rclone
sudo rm -f /etc/systemd/system/rclone-mount-obs.service
sudo systemctl daemon-reload
sudo userdel -r pacsuser 2>/dev/null || true
sudo rm -f /etc/samba/smb.conf
sudo systemctl restart smbd 2>/dev/null || true
```

> Yukarıdaki `pacsuser` satırını kurulumda seçtiğiniz gerçek `SMB_USER` değeriyle değiştirin.

---

## 📄 Lisans
Developed by Furkan YIGIT 
MIT License