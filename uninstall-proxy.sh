#!/bin/bash
# uninstall-proxy.sh — Gỡ redsocks an toàn, chỉ đụng redsocks, không ảnh hưởng Docker/Pterodactyl

set -e

REDSOCKS_PORT="12345"
DOCKER_SUBNET="172.18.0.0/16"

echo ">>> [1/4] Dừng và disable redsocks service..."
systemctl stop redsocks   2>/dev/null && echo "    ✅ Stopped" || echo "    ⚠️  redsocks không chạy, bỏ qua"
systemctl disable redsocks 2>/dev/null && echo "    ✅ Disabled" || echo "    ⚠️  redsocks không enabled, bỏ qua"

echo ""
echo ">>> [2/4] Dọn iptables — CHỈ rules liên quan redsocks..."

# Hàm xóa toàn bộ rule trong 1 chain có nhắc tới REDSOCKS
# Xóa từ dưới lên để line number không bị lệch
clean_chain() {
    local CHAIN="$1"
    echo "    Dọn chain: $CHAIN"
    while true; do
        local LINENUM
        LINENUM=$(iptables -t nat -L "$CHAIN" --line-numbers -n 2>/dev/null \
            | awk '/REDSOCKS/{print $1}' | tail -1)
        [ -z "$LINENUM" ] && break
        echo "      - Xóa rule #$LINENUM trong $CHAIN"
        iptables -t nat -D "$CHAIN" "$LINENUM" 2>/dev/null || break
    done
    echo "      ✅ $CHAIN sạch"
}

clean_chain PREROUTING
clean_chain OUTPUT

# Flush và xóa chain REDSOCKS nếu tồn tại
if iptables -t nat -L REDSOCKS -n &>/dev/null; then
    echo "    Flush & xóa chain REDSOCKS..."
    iptables -t nat -F REDSOCKS
    iptables -t nat -X REDSOCKS
    echo "    ✅ Chain REDSOCKS đã xóa"
else
    echo "    ℹ️  Chain REDSOCKS không tồn tại, bỏ qua"
fi

echo ""
echo ">>> [3/4] Lưu lại iptables..."
netfilter-persistent save
echo "    ✅ Đã lưu"

echo ""
echo ">>> [4/4] Kiểm tra xác nhận..."

# Kiểm tra không còn rule REDSOCKS nào
REMAIN=$(iptables -t nat -S 2>/dev/null | grep -c 'REDSOCKS' || true)
if [ "$REMAIN" -eq 0 ]; then
    echo "    ✅ Không còn rule REDSOCKS nào trong iptables"
else
    echo "    ❌ Vẫn còn $REMAIN rule REDSOCKS — kiểm tra thủ công:"
    iptables -t nat -S | grep 'REDSOCKS'
fi

# Kiểm tra redsocks không còn listen
if ss -tlnp | grep -q "$REDSOCKS_PORT"; then
    echo "    ❌ Port $REDSOCKS_PORT vẫn còn listen — kiểm tra lại"
    ss -tlnp | grep "$REDSOCKS_PORT"
else
    echo "    ✅ Port $REDSOCKS_PORT đã giải phóng"
fi

# Kiểm tra Docker/Pterodactyl chain còn nguyên
echo ""
echo "    Kiểm tra Docker chains còn nguyên:"
for CHAIN in DOCKER DOCKER-USER POSTROUTING; do
    if iptables -t nat -L "$CHAIN" -n &>/dev/null; then
        COUNT=$(iptables -t nat -L "$CHAIN" -n | tail -n +3 | grep -c '.' || true)
        echo "      ✅ $CHAIN — $COUNT rules còn nguyên"
    else
        echo "      ⚠️  $CHAIN không tồn tại (bình thường nếu Docker chưa khởi động)"
    fi
done

echo ""
echo "✅ Gỡ proxy hoàn tất — không cần reboot, Docker/Pterodactyl không bị ảnh hưởng."
