#!/bin/bash
set -e

echo "=============================================="
echo "PACS Gateway v3 - Unified VFS Cache Architecture"
echo "=============================================="
echo "   ██████╗██╗      ██████╗ ██╗   ██╗███████╗"
echo "  ██╔════╝██║     ██╔═══██╗██║   ██║██╔════╝"
echo "  ██║     ██║     ██║   ██║██║   ██║███████╗"
echo "  ██║     ██║     ██║   ██║██║   ██║╚════██║"
echo "  ╚██████╗███████╗╚██████╔╝╚██████╔╝███████║"
echo "   ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚══════╝"
echo ""
echo "Mimari: Windows/Fuji <-SMB-> tek path (rclone VFS cache) <-> Huawei OBS"
echo "        rclone; cache'te varsa local'den, yoksa OBS'ten şeffaf sunar."
echo "        Yazma önce cache'e düşer, arkaplanda OBS'e gönderilir."
echo "=============================================="

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================
# 0. PUBLIC ve PRIVATE IP'Yİ AL
# ============================================
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null)
if [[ -z "$PUBLIC_IP" ]]; then
    read -p "Public IP adresini manuel girin: " PUBLIC_IP
fi
PRIVATE_IP=$(hostname -I | awk '{print $1}')

# ============================================
# 1. DOCKER, DOCKER COMPOSE, ENVSUBST, SAMBA KURULUMU
# ============================================
if ! command -v docker &> /dev/null; then
    echo "Docker kurulu değil, kuruluyor..."
    sudo apt update
    sudo apt install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable docker
    sudo systemctl start docker
    echo "Docker kurulumu tamamlandı."
else
    echo "Docker zaten kurulu."
fi

if ! command -v envsubst &> /dev/null; then
    echo "gettext-base (envsubst) kurulu değil, kuruluyor..."
    sudo apt update
    sudo apt install -y gettext-base
fi

if ! command -v smbpasswd &> /dev/null; then
    echo "Samba (smbd/smbpasswd) kurulu değil, kuruluyor..."
    sudo apt update
    sudo apt install -y samba samba-common-bin
fi

if ! command -v rclone &> /dev/null; then
    echo "❌ rclone kurulu değil. Kurulum: curl https://rclone.org/install.sh | sudo bash"
    exit 1
fi

# ============================================
# 2. KULLANICIDAN BİLGİLERİ AL (ZORUNLU)
# ============================================
while [[ -z "$ACCESS_KEY" ]]; do
    read -p "Huawei OBS Access Key: " ACCESS_KEY
done

while [[ -z "$SECRET_KEY" ]]; do
    read -sp "Huawei OBS Secret Key: " SECRET_KEY
    echo
done

echo ""
echo "📍 OBS Region seçin:"
echo "  1) tr-west-1 (Istanbul)"
echo "  2) eu-west-1 (Ireland)"
echo "  3) eu-west-2 (London)"
echo "  4) eu-west-3 (Paris)"
echo "  5) eu-west-4 (Frankfurt)"
echo "  6) ap-southeast-1 (Singapore)"
echo "  7) ap-southeast-2 (Tokyo)"
echo "  8) ap-southeast-3 (Seoul)"
echo "  9) cn-north-1 (Beijing)"
echo "  10) us-east-1 (Virginia)"
echo "  11) us-west-1 (California)"
read -p "Seçiminiz (1-11): " REGION_CHOICE

case $REGION_CHOICE in
    1) ENDPOINT="obs.tr-west-1.myhuaweicloud.com" ;;
    2) ENDPOINT="obs.eu-west-1.myhuaweicloud.com" ;;
    3) ENDPOINT="obs.eu-west-2.myhuaweicloud.com" ;;
    4) ENDPOINT="obs.eu-west-3.myhuaweicloud.com" ;;
    5) ENDPOINT="obs.eu-west-4.myhuaweicloud.com" ;;
    6) ENDPOINT="obs.ap-southeast-1.myhuaweicloud.com" ;;
    7) ENDPOINT="obs.ap-southeast-2.myhuaweicloud.com" ;;
    8) ENDPOINT="obs.ap-southeast-3.myhuaweicloud.com" ;;
    9) ENDPOINT="obs.cn-north-1.myhuaweicloud.com" ;;
    10) ENDPOINT="obs.us-east-1.myhuaweicloud.com" ;;
    11) ENDPOINT="obs.us-west-1.myhuaweicloud.com" ;;
    *) echo "Geçersiz seçim, varsayılan tr-west-1 kullanılıyor."; ENDPOINT="obs.tr-west-1.myhuaweicloud.com" ;;
esac
echo "✅ Seçilen endpoint: $ENDPOINT"

while [[ -z "$BUCKET_NAME" ]]; do
    read -p "OBS Bucket Adı: " BUCKET_NAME
done

while [[ -z "$SMB_USER" ]]; do
    read -p "Samba Kullanıcı Adı (örn: pacsuser): " SMB_USER
done

while [[ -z "$SMB_PASS" ]]; do
    read -sp "Samba Şifresi: " SMB_PASS
    echo
done

while [[ -z "$SMTP_MAIL" ]]; do
    read -p "SMTP Mail Adresi: " SMTP_MAIL
done

while [[ -z "$SMTP_PASS" ]]; do
    read -sp "SMTP Uygulama Şifresi: " SMTP_PASS
    echo
done

while [[ -z "$ALERT_MAIL" ]]; do
    read -p "Alert E-posta Adresi: " ALERT_MAIL
done

while [[ -z "$RC_USER" ]]; do
    read -p "Rclone RC Kullanıcı Adı: " RC_USER
done
while [[ -z "$RC_PASS" ]]; do
    read -sp "Rclone RC Şifresi: " RC_PASS
    echo
done

echo ""
echo "📁 İki farklı dizin soracağız:"
echo "   1) SMB/Windows'un göreceği tek path (rclone FUSE mount noktası)"
echo "   2) VFS cache'in FİZİKSEL olarak diskte tutulacağı yer (disk doluluk"
echo "      alarmları ve boyut sınırı BURAYA göre çalışır, FUSE mount'a değil)"
read -p "SMB Mount Path [varsayılan: /mnt/pacs-gateway]: " MOUNT_PATH
MOUNT_PATH=${MOUNT_PATH:-/mnt/pacs-gateway}
read -p "VFS Cache Dizini (fiziksel disk) [varsayılan: /var/lib/pacs-cache]: " CACHE_DIR
CACHE_DIR=${CACHE_DIR:-/var/lib/pacs-cache}

echo ""
echo "🗄️  Local cache'in ne kadar süre/boyut tutulacağını belirle."
echo "   max-age: son erişimden bu yana geçen süre bazlı LRU eviction (yaş garantisi DEĞİL)."
echo "   max-size: SERT üst sınır - CACHE_DIR'in bulunduğu diskin boyutuna göre belirle,"
echo "             disk kapasitesinin tamamını verme, ~%15 pay bırak."
read -p "VFS Cache Max Age [varsayılan: 2160h = 90 gün]: " VFS_CACHE_AGE
VFS_CACHE_AGE=${VFS_CACHE_AGE:-2160h}
while [[ -z "$VFS_CACHE_SIZE" ]]; do
    read -p "VFS Cache Max Size (ZORUNLU, örn: 2T, 500G): " VFS_CACHE_SIZE
done
read -p "VFS Cache Min Free Space [varsayılan: 100G]: " VFS_CACHE_MIN_FREE
VFS_CACHE_MIN_FREE=${VFS_CACHE_MIN_FREE:-100G}
read -p "VFS Write-Back gecikmesi [varsayılan: 15s]: " VFS_WRITE_BACK
VFS_WRITE_BACK=${VFS_WRITE_BACK:-15s}

# ============================================
# 3. PORT KONTROLLERİ
# ============================================
echo ""
echo "🔍 Port kontrolleri yapılıyor..."
REQUIRED_PORTS=(139 445 3000 5572 9090 9100 9393)
PORT_ERROR=0

for port in "${REQUIRED_PORTS[@]}"; do
    if sudo ss -tlnp | grep -q ":$port "; then
        echo "⚠️  Port $port zaten kullanımda!"
        PORT_ERROR=1
    else
        echo "✅ Port $port kullanıma uygun."
    fi
done

if [[ $PORT_ERROR -eq 1 ]]; then
    echo ""
    echo "❌ Bazı portlar zaten kullanımda!"
    read -p "Devam etmek istiyor musunuz? (y/N): " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        echo "Kurulum iptal edildi."
        exit 1
    fi
fi

if command -v ufw &> /dev/null && sudo ufw status | grep -q "Status: active"; then
    echo ""
    echo "🔒 UFW aktif. Gerekli portlar açılıyor..."
    sudo ufw allow 139,445/tcp comment 'SMB'
    sudo ufw allow 3000/tcp comment 'Grafana'
    sudo ufw allow 5572/tcp comment 'Rclone RC/Metrics'
    sudo ufw allow 9090/tcp comment 'Prometheus'
    sudo ufw allow 9100/tcp comment 'Node-Exporter'
    sudo ufw allow 9393/tcp comment 'Alertmanager'
fi

# ============================================
# 4. DİZİNLERİ OLUŞTUR
# ============================================
echo ""
echo "📁 Dizinler oluşturuluyor..."
sudo mkdir -p /etc/rclone /opt/pacs-gateway/{prometheus,alertmanager,grafana/dashboards,grafana/provisioning/datasources,grafana/provisioning/dashboards,logs}
sudo mkdir -p "$MOUNT_PATH" "$CACHE_DIR"

# ============================================
# 5. RCLONE CONFIG
# ============================================
echo "📝 Rclone config oluşturuluyor..."
cat > /tmp/rclone.conf <<EOF
[obs]
type = s3
provider = HuaweiOBS
access_key_id = $ACCESS_KEY
secret_access_key = $SECRET_KEY
endpoint = $ENDPOINT
acl = private
bucket_acl = private
EOF
sudo cp /tmp/rclone.conf /etc/rclone/rclone.conf
sudo chmod 600 /etc/rclone/rclone.conf
rm -f /tmp/rclone.conf

# ============================================
# 6. SAMBA KULLANICISI OLUŞTUR
# ============================================
echo "👤 Samba kullanıcısı oluşturuluyor..."
sudo useradd -M -s /sbin/nologin "$SMB_USER" 2>/dev/null || true
echo -e "$SMB_PASS\n$SMB_PASS" | sudo smbpasswd -a -s "$SMB_USER"

SMB_UID=$(id -u "$SMB_USER")
SMB_GID=$(id -g "$SMB_USER")

sudo chown -R "$SMB_USER:$SMB_USER" "$CACHE_DIR"

sudo tee /etc/samba/smb.conf > /dev/null <<EOF
[global]
   server min protocol = SMB2
   server max protocol = SMB3
   client min protocol = SMB2
   client max protocol = SMB3
   workgroup = PACS
   interfaces = 0.0.0.0/0
   bind interfaces only = no

[PACS]
   path = ${MOUNT_PATH}
   browseable = yes
   read only = no
   guest ok = no
   valid users = $SMB_USER
   force user = $SMB_USER
   force group = $SMB_USER
   create mask = 0664
   directory mask = 0775
   oplocks = no
   level2 oplocks = no
   kernel oplocks = no
   strict locking = no
EOF

sudo systemctl enable smbd
sudo systemctl restart smbd

# ============================================
# 7. PROMETHEUS / ALERTMANAGER / GRAFANA CONFIG (envsubst ile repo template'lerinden)
# ============================================
echo "📝 İzleme config'leri envsubst ile üretiliyor..."
export RC_USER RC_PASS SMTP_MAIL SMTP_PASS ALERT_MAIL CACHE_DIR

envsubst '${RC_USER} ${RC_PASS}' < "$REPO_DIR/prometheus/prometheus.yml" > /opt/pacs-gateway/prometheus/prometheus.yml
sed "s|__CACHE_DIR__|${CACHE_DIR}|g" "$REPO_DIR/prometheus/alert.rules.yml" > /opt/pacs-gateway/prometheus/alert.rules.yml

envsubst '${SMTP_MAIL} ${SMTP_PASS} ${ALERT_MAIL}' < "$REPO_DIR/alertmanager/alertmanager.yml" \
    | sed "s|YOUR_SMTP_EMAIL|${SMTP_MAIL}|g; s|YOUR_SMTP_APP_PASSWORD|${SMTP_PASS}|g; s|YOUR_ALERT_EMAIL|${ALERT_MAIL}|g" \
    > /opt/pacs-gateway/alertmanager/alertmanager.yml

sed "s|YOUR_SMTP_MAIL|${SMTP_MAIL}|g; s|YOUR_SMTP_PASS|${SMTP_PASS}|g" "$REPO_DIR/grafana/grafana.ini" \
    > /opt/pacs-gateway/grafana/grafana.ini

cp "$REPO_DIR/docker-compose.yml" /opt/pacs-gateway/docker-compose.yml

# ---- Grafana dashboard'ının OTOMATİK deploy edilmesi (provisioning) ----
echo "📊 Grafana dashboard'ı (JSON) otomatik provisioning için hazırlanıyor..."
cp "$REPO_DIR/grafana/provisioning/datasources/datasource.yml" \
    /opt/pacs-gateway/grafana/provisioning/datasources/datasource.yml
cp "$REPO_DIR/grafana/provisioning/dashboards/dashboard.yml" \
    /opt/pacs-gateway/grafana/provisioning/dashboards/dashboard.yml

# Dashboard JSON'undaki __CACHE_DIR__ yer tutucusunu alert.rules.yml ile
# BİREBİR aynı gerçek CACHE_DIR değeriyle doldur, aksi halde panel sorguları
# node_exporter'ın mountpoint label'ıyla eşleşmez ve grafikler boş kalır.
sed "s|__CACHE_DIR__|${CACHE_DIR}|g" \
    "$REPO_DIR/grafana/dashboards/pacs-gateway-overview.json" \
    > /opt/pacs-gateway/grafana/dashboards/pacs-gateway-overview.json

# ============================================
# 8. SYSTEMD: UNIFIED RCLONE MOUNT (envsubst ile repo template'inden)
# ============================================
echo "📝 Unified rclone mount systemd servisi oluşturuluyor..."
export BUCKET_NAME MOUNT_PATH CACHE_DIR SMB_UID SMB_GID VFS_CACHE_AGE VFS_CACHE_SIZE VFS_CACHE_MIN_FREE VFS_WRITE_BACK

envsubst '${BUCKET_NAME} ${MOUNT_PATH} ${CACHE_DIR} ${SMB_UID} ${SMB_GID} ${VFS_CACHE_AGE} ${VFS_CACHE_SIZE} ${VFS_CACHE_MIN_FREE} ${VFS_WRITE_BACK} ${RC_USER} ${RC_PASS}' \
    < "$REPO_DIR/systemd/rclone-mount-obs.service" | sudo tee /etc/systemd/system/rclone-mount-obs.service > /dev/null

sudo systemctl daemon-reload
sudo systemctl enable rclone-mount-obs
sudo systemctl start rclone-mount-obs
sleep 3

# ============================================
# 9. DOCKER COMPOSE BAŞLAT
# ============================================
echo "🐳 Docker Compose başlatılıyor..."
cd /opt/pacs-gateway && sudo docker compose up -d

# ============================================
# 10. KURULUM SONRASI KONTROLLER
# ============================================
echo ""
echo "🔍 Kurulum sonrası kontroller yapılıyor..."

if mount | grep -q "$MOUNT_PATH"; then
    echo "✅ Unified rclone mount başarılı: $MOUNT_PATH"
else
    echo "❌ Mount başarısız! sudo journalctl -u rclone-mount-obs -f"
fi

if curl -s -u ${RC_USER}:${RC_PASS} http://localhost:5572/metrics > /dev/null 2>&1; then
    echo "✅ Rclone RC/metrics API çalışıyor (mount'un kendisinden)."
else
    echo "❌ Rclone RC API çalışmıyor! sudo journalctl -u rclone-mount-obs -f"
fi

if sudo systemctl is-active --quiet smbd; then
    echo "✅ Samba servisi çalışıyor."
else
    echo "❌ Samba servisi çalışmıyor! sudo journalctl -u smbd -f"
fi

for c in pacs-prometheus pacs-grafana pacs-alertmanager pacs-node-exporter; do
    if docker ps | grep -q "$c"; then
        echo "✅ $c çalışıyor."
    else
        echo "❌ $c çalışmıyor! docker logs $c"
    fi
done

echo ""
echo "🔍 Grafana dashboard provisioning kontrolü..."
sleep 5
if curl -s -u admin:admin http://localhost:3000/api/search?query=PACS 2>/dev/null | grep -q "pacs-gateway-overview"; then
    echo "✅ 'PACS Gateway - VFS Cache Overview' dashboard'ı otomatik yüklendi."
else
    echo "⚠️  Dashboard henüz API'de görünmüyor (Grafana yeni başlamış olabilir)."
    echo "    30sn sonra tekrar dene: curl -u admin:admin http://localhost:3000/api/search?query=PACS"
fi

# ============================================
# 11. KURULUM TAMAMLANDI
# ============================================
echo ""
echo "=============================================="
echo "✅ Kurulum tamamlandı!"
echo "=============================================="
echo ""
echo "📌 Erişim Bilgileri:"
echo "   Private IP: $PRIVATE_IP"
echo "   Public IP: $PUBLIC_IP"
echo ""
echo "   📤📥 Tek SMB paylaşımı (okuma+yazma): \\\\$PUBLIC_IP\\PACS"
echo "   SMB Kullanıcı: $SMB_USER"
echo "   Windows'tan bağlanmak için:"
echo "   net use Z: \\\\$PUBLIC_IP\\PACS /user:$SMB_USER \"SIFRENIZ\" /persistent:yes"
echo ""
echo "   Grafana: http://$PUBLIC_IP:3000 (admin/admin)"
echo "     -> 'PACS Gateway' klasöründe 'VFS Cache Overview' dashboard'ı otomatik provision edildi"
echo "   Prometheus: http://$PUBLIC_IP:9090"
echo "   Rclone Web GUI / RC: http://$PUBLIC_IP:5572 ($RC_USER/****)"
echo "   Alertmanager: http://$PUBLIC_IP:9393"
echo ""
echo "📋 Servis Yönetimi:"
echo "   sudo systemctl status rclone-mount-obs smbd"
echo "   cd /opt/pacs-gateway && docker compose ps"
echo ""
echo "📁 SMB mount noktası:  $MOUNT_PATH"
echo "📁 VFS cache (fiziksel disk): $CACHE_DIR"
echo "🗄️  Cache politikası: max-age=${VFS_CACHE_AGE}, max-size=${VFS_CACHE_SIZE}, min-free=${VFS_CACHE_MIN_FREE}"
echo ""
echo "📝 HATA KONTROLÜ (Loglar):"
echo "   Mount:  tail -f /opt/pacs-gateway/logs/rclone-mount.log"
echo "   Samba:  sudo journalctl -u smbd -f"
echo "   Cache manuel forget: curl -u $RC_USER:PASS -X POST http://localhost:5572/vfs/forget -d 'file=RELATIVE/PATH'"
echo "=============================================="
echo "   ██████╗██╗      ██████╗ ██╗   ██╗███████╗"
echo "  ██╔════╝██║     ██╔═══██╗██║   ██║██╔════╝"
echo "  ██║     ██║     ██║   ██║██║   ██║███████╗"
echo "  ██║     ██║     ██║   ██║██║   ██║╚════██║"
echo "  ╚██████╗███████╗╚██████╔╝╚██████╔╝███████║"
echo "   ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚══════╝"
echo "=============================================="
echo "   🚀 Developed by Furkan YIGIT | Cloud Solution Architect | Clous Cloud"
echo "=============================================="