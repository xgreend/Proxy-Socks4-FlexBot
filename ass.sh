#!/bin/bash
set -e

PROXY_HOST="nodes-1.ddns.net"
PROXY_PORT="1080"
PROXY_USER="proxyuser"
PROXY_PASS="Yua2003@#"
REDSOCKS_PORT="12345"
DOCKER_SUBNET="172.18.0.0/16"

# ─────────────────────────────────────────────
echo ">>> [1/5] Cài đặt packages..."
# ─────────────────────────────────────────────
apt-get install -y redsocks iptables-persistent dnsutils curl

# ─────────────────────────────────────────────
echo ">>> [2/5] Resolve IP proxy server..."
# ─────────────────────────────────────────────
PROXY_IP=$(dig +short "$PROXY_HOST" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
if [ -z "$PROXY_IP" ]; then
    echo "    [!] dig thất bại, thử getent..."
    PROXY_IP=$(getent hosts "$PROXY_HOST" | awk '{print $1}' | head -1)
fi
if [ -z "$PROXY_IP" ]; then
    echo "    [!] getent thất bại, thử nslookup..."
    PROXY_IP=$(nslookup "$PROXY_HOST" 2>/dev/null | awk '/^Address: /{print $2}' | grep -v '#' | head -1)
fi
if [ -z "$PROXY_IP" ]; then
    echo "    [ERROR] Không thể resolve IP cho $PROXY_HOST. Thoát."
    exit 1
fi
echo "    Proxy IP: $PROXY_IP"

# ─────────────────────────────────────────────
echo ">>> [3/5] Ghi cấu hình redsocks..."
# ─────────────────────────────────────────────
cat > /etc/redsocks.conf << EOF
base {
    log_debug = off;
    log_info = on;
    log = "file:/var/log/redsocks.log";
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 0.0.0.0;
    local_port = $REDSOCKS_PORT;
    ip = $PROXY_HOST;
    port = $PROXY_PORT;
    type = socks5;
    login = "$PROXY_USER";
    password = "$PROXY_PASS";
}
EOF

# ─────────────────────────────────────────────
echo ">>> [4/5] Dọn iptables cũ & cấu hình mới..."
# ─────────────────────────────────────────────

# Hàm xóa tất cả rule trong 1 chain trỏ tới REDSOCKS (an toàn, không dùng pipe+subshell)
clean_redsocks_rules() {
    local TABLE="nat"
    local CHAIN="$1"
    # Lặp ngược từ cuối lên đầu để số thứ tự không bị lệch khi xóa
    while true; do
        local LINENUM
        LINENUM=$(iptables -t "$TABLE" -L "$CHAIN" --line-numbers -n 2>/dev/null \
            | awk '/REDSOCKS/{print $1}' | tail -1)
        [ -z "$LINENUM" ] && break
        iptables -t "$TABLE" -D "$CHAIN" "$LINENUM" 2>/dev/null || break
    done
}

clean_redsocks_rules PREROUTING
clean_redsocks_rules OUTPUT

# Flush và xóa chain REDSOCKS cũ nếu tồn tại
if iptables -t nat -L REDSOCKS -n &>/dev/null; then
    iptables -t nat -F REDSOCKS
    iptables -t nat -X REDSOCKS
fi

# Tạo chain REDSOCKS mới
iptables -t nat -N REDSOCKS

# Bỏ qua proxy server (tránh loop)
iptables -t nat -A REDSOCKS -d "$PROXY_IP"      -j RETURN

# Bỏ qua private / reserved ranges
iptables -t nat -A REDSOCKS -d 0.0.0.0/8        -j RETURN
iptables -t nat -A REDSOCKS -d 10.0.0.0/8       -j RETURN
iptables -t nat -A REDSOCKS -d 127.0.0.0/8      -j RETURN
iptables -t nat -A REDSOCKS -d 169.254.0.0/16   -j RETURN
iptables -t nat -A REDSOCKS -d 172.16.0.0/12    -j RETURN
iptables -t nat -A REDSOCKS -d 192.168.0.0/16   -j RETURN
iptables -t nat -A REDSOCKS -d 224.0.0.0/4      -j RETURN
iptables -t nat -A REDSOCKS -d 240.0.0.0/4      -j RETURN

# Redirect TCP còn lại qua redsocks
iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports "$REDSOCKS_PORT"

# Áp dụng cho traffic từ Docker containers (pterodactyl subnet)
iptables -t nat -A PREROUTING -s "$DOCKER_SUBNET" -p tcp -j REDSOCKS

# Đảm bảo MASQUERADE tồn tại (idempotent)
iptables -t nat -C POSTROUTING -s "$DOCKER_SUBNET" ! -o pterodactyl0 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$DOCKER_SUBNET" ! -o pterodactyl0 -j MASQUERADE

# ─────────────────────────────────────────────
echo ">>> [5/5] Khởi động redsocks & lưu iptables..."
# ─────────────────────────────────────────────
systemctl enable redsocks
systemctl restart redsocks

# Xác nhận redsocks bind đúng 0.0.0.0
sleep 1
if ss -tlnp | grep -q "$REDSOCKS_PORT"; then
    echo "    ✅ redsocks đang listen trên port $REDSOCKS_PORT"
    ss -tlnp | grep "$REDSOCKS_PORT"
else
    echo "    ❌ redsocks KHÔNG listen được! Xem log:"
    journalctl -u redsocks --no-pager -n 20
    exit 1
fi

netfilter-persistent save

# ─────────────────────────────────────────────
echo ""
echo "✅ Hoàn tất! Đang kiểm tra kết nối từ container..."
sleep 2

CONTAINER_ID=$(docker ps -q | head -1)
if [ -z "$CONTAINER_ID" ]; then
    echo "    [!] Không có container nào đang chạy — bỏ qua test."
else
    echo "    Test từ container $CONTAINER_ID:"
    RESULT=$(docker exec "$CONTAINER_ID" sh -c \
        "curl -4 --max-time 10 -s -o /dev/null -w '%{http_code}' https://api.minecraftservices.com/publickeys 2>&1")
    if [ "$RESULT" = "200" ]; then
        echo "    ✅ Kết nối thành công! HTTP $RESULT"
    else
        echo "    ❌ Kết nối thất bại! HTTP $RESULT"
        docker exec "$CONTAINER_ID" sh -c \
            "curl -4 --max-time 10 https://api.minecraftservices.com/publickeys 2>&1 | tail -5"
    fi
fi
