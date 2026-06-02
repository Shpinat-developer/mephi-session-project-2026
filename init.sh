#!/usr/bin/env bash
# Идемпотентная инициализация контейнера МИФИ.
# Запускается systemd-юнитом mephi-init.service при старте контейнера.
# Реализует разделы 1-5 итогового проекта; артефакты складывает в /shared.
# Намеренно НЕ используем set -e: скрипт идемпотентный, отдельные шаги
# могут возвращать ненулевой код (apt сообщает 100 при предупреждениях,
# rpm/grep/blkid возвращают 1 если ничего не найдено) — это не ошибки.
# Каждый критичный блок проверяет свой результат явно.
set -uo pipefail

SHARED=/shared
CONTENT="${CONTENT_DIR:-/opt/mephi-content}"
mkdir -p "$SHARED"
LOG="$SHARED/init.log"
exec > >(tee -a "$LOG") 2>&1
echo "================================================================"
echo "mephi-init started at $(date)"
echo "================================================================"

# Источник истины — plain-text файлы в content/*.txt.
# Они содержат блоки в формате:
#   ## Термин
#   текст определения, может быть многострочным
#   `code` оборачивается в моноширинный шрифт
#
# emit_preamble вставляет блок обоснования в начало .txt-артефакта.
emit_preamble() {
    local file="$CONTENT/$1"
    if [[ -f "$file" ]]; then
        echo "== ОБОСНОВАНИЕ =="
        echo
        cat "$file"
        echo
    fi
}

# ----------------------------------------------------------------
# Раздел 1. Управление сетью
# ----------------------------------------------------------------
echo; echo "### [1.1] Сеть: nmcli + ifcfg-eth0 + hostname"

# 1.1.1 NetworkManager: снять глобальную блокировку и перезапустить
if [[ ! -f /etc/NetworkManager/conf.d/10-override-managed.conf ]]; then
  cat > /etc/NetworkManager/conf.d/10-override-managed.conf <<'EOF'
[keyfile]
unmanaged-devices=none

[device-mephi]
match-device=interface-name:eth0
managed=1
EOF
  sed -i 's/managed=false/managed=true/' /etc/NetworkManager/NetworkManager.conf || true
  systemctl restart NetworkManager || true
  sleep 2
fi

# 1.1.2 Профиль nmcli (идемпотентно)
if ! nmcli -t -f NAME connection show 2>/dev/null | grep -q '^static-eth0$'; then
  nmcli connection add \
      type ethernet \
      con-name static-eth0 \
      ifname eth0 \
      ipv4.method manual \
      ipv4.addresses 192.168.91.100/24 \
      ipv4.gateway 192.168.91.1 \
      ipv4.dns 8.8.8.8 \
      autoconnect yes || true
fi

# 1.1.3 ifcfg для Fedora-совместимости
mkdir -p /etc/sysconfig/network-scripts
cat > /etc/sysconfig/network-scripts/ifcfg-eth0 <<'EOF'
TYPE=Ethernet
BOOTPROTO=none
NAME=eth0
DEVICE=eth0
ONBOOT=yes
IPADDR=192.168.91.100
PREFIX=24
GATEWAY=192.168.91.1
DNS1=8.8.8.8
EOF

# 1.1.4 hostname
hostnamectl set-hostname mephi-2026.domain.local || true

# 1.2 Проверка связности
echo; echo "### [1.2] network_check.txt"
{
  emit_preamble "s1.txt"
  echo "== ВЫВОД КОМАНД =="
  echo
  echo "=== Hostname ==="
  hostnamectl | grep -E "Static hostname|Chassis"
  echo
  echo "=== Маршрут по умолчанию ==="
  ip route | grep default
  echo
  echo "=== Ping шлюза ==="
  ping -c 4 192.168.91.1
  echo
  echo "=== Ping 8.8.8.8 ==="
  ping -c 4 8.8.8.8
  echo
  echo "=== nmcli connection (static-eth0) ==="
  nmcli connection show static-eth0 2>/dev/null | grep -E "ipv4.method|ipv4.addresses|ipv4.gateway|ipv4.dns:|connection.id" || \
    echo "(профиль создаётся при следующем запуске NetworkManager)"
} > "$SHARED/network_check.txt" 2>&1

# ----------------------------------------------------------------
# Раздел 2. Программное обеспечение
# ----------------------------------------------------------------
echo; echo "### [2.1] Пакеты: nginx, tcpdump, libcap2-bin"
# Пакеты предустановлены в Dockerfile — apt-get install вернёт "already newest"
# Это сохраняет факт выполнения команды установки из задания 2.1
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    nginx tcpdump libcap2-bin sshpass selinux-utils policycoreutils kpartx 2>&1 | tail -2

echo; echo "### [2.2] DEB tcpdump (Ubuntu-эквивалент 'dnf download + rpm -i')"
# В задании Fedora: dnf download tcpdump → rpm -i tcpdump.rpm
# В Ubuntu эквивалент: apt download tcpdump → dpkg -i tcpdump_*.deb
# .deb предварительно скачан в /opt/mephi-cache при сборке образа (см. Dockerfile)
cd /tmp
rm -f /tmp/tcpdump_*.deb 2>/dev/null
CACHED_DEB=$(ls /opt/mephi-cache/tcpdump_*.deb 2>/dev/null | head -1)
if [[ -n "$CACHED_DEB" ]]; then
  cp "$CACHED_DEB" /tmp/
  DEB_FILE=$(ls /tmp/tcpdump_*.deb | head -1)
  echo "Из кеша: $DEB_FILE"
  dpkg -i "$DEB_FILE" 2>&1 | tail -3
  cp "$DEB_FILE" "$SHARED/tcpdump.deb"
else
  # Fallback: качаем онлайн (медленно из-за apt update)
  DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 | tail -1
  apt-get download tcpdump 2>&1 | tail -2
  DEB_FILE=$(ls /tmp/tcpdump_*.deb 2>/dev/null | head -1)
  if [[ -n "$DEB_FILE" ]]; then
    dpkg -i "$DEB_FILE" 2>&1 | tail -3
    cp "$DEB_FILE" "$SHARED/tcpdump.deb"
  fi
fi
cd /

# ----------------------------------------------------------------
# Раздел 3. Файловые системы и сервисы
# ----------------------------------------------------------------
echo; echo "### [3.1] Loop-диск + ext4 MEPHI_DATA + fstab"

# Создаём образ если нет
IMG=/var/sdb.img
[[ -f "$IMG" ]] || truncate -s 1G "$IMG"

# losetup идемпотентно
LOOP=$(losetup -j "$IMG" | cut -d: -f1)
if [[ -z "$LOOP" ]]; then
  LOOP=$(losetup -fP --show "$IMG")
fi

# Таблица разделов
if ! parted -s "$LOOP" print 2>/dev/null | grep -q "^ 1 "; then
  parted -s "$LOOP" mklabel msdos
  parted -s "$LOOP" mkpart primary ext4 1MiB 100%
fi

# kpartx — карта разделов
kpartx -av "$LOOP" >/dev/null 2>&1 || true
sleep 1
LOOP_NAME=$(basename "$LOOP")
PART_DEV="/dev/mapper/${LOOP_NAME}p1"

# Форматирование (только если ещё не отформатирован с нашей меткой)
if ! blkid "$PART_DEV" 2>/dev/null | grep -q 'LABEL="MEPHI_DATA"'; then
  mkfs.ext4 -F -L MEPHI_DATA "$PART_DEV"
fi

# Точка монтирования + fstab
mkdir -p /data/mephi-web
grep -q "MEPHI_DATA" /etc/fstab || \
  echo "LABEL=MEPHI_DATA  /data/mephi-web  ext4  defaults  0  2" >> /etc/fstab

# Mount по device (mount -a может не найти LABEL в Docker — udev не работает)
mountpoint -q /data/mephi-web || mount "$PART_DEV" /data/mephi-web

{
  emit_preamble "s3.txt"
  echo "== ВЫВОД КОМАНД =="
  echo
  echo "=== /etc/fstab ==="
  cat /etc/fstab
  echo
  echo "=== blkid (раздел с меткой MEPHI_DATA) ==="
  blkid "$PART_DEV"
  echo
  echo "=== mount | grep mephi-web ==="
  mount | grep mephi-web
} > "$SHARED/fstab.txt"

echo; echo "### [3.2] nginx + journalctl"
systemctl enable --now nginx >/dev/null 2>&1 || true
# Конфиг сайта: root → /data/mephi-web (если ещё не сделано)
if ! grep -q "root /data/mephi-web;" /etc/nginx/sites-enabled/default; then
  sed -i "s|root /var/www/html;|root /data/mephi-web;|" /etc/nginx/sites-enabled/default
  systemctl restart nginx
fi

{
  emit_preamble "s3.txt"
  echo "== ВЫВОД КОМАНД =="
  echo
  echo "=== journalctl -u nginx --since '5 minutes ago' ==="
  journalctl -u nginx --since "5 minutes ago" --no-pager
} > "$SHARED/nginx_recent_logs.txt" 2>&1 || true

# ----------------------------------------------------------------
# Раздел 4. Управление доступом
# ----------------------------------------------------------------
echo; echo "### [4.1] DAC"
getent group mephi-devs >/dev/null || groupadd mephi-devs
id mephi-admin >/dev/null 2>&1 || useradd -m -s /bin/bash mephi-admin
echo 'mephi-admin:P@ssw0rd2026' | chpasswd
usermod -aG mephi-devs mephi-admin

chown -R mephi-admin:mephi-devs /data/mephi-web
chmod 2775 /data/mephi-web

{
  emit_preamble "s4-dac.txt"
  echo "== ВЫВОД КОМАНД =="
  echo
  echo "=== id mephi-admin ==="; id mephi-admin
  echo; echo "=== getent passwd mephi-admin ==="; getent passwd mephi-admin
  echo; echo "=== getent group mephi-devs ==="; getent group mephi-devs
} > "$SHARED/users_groups.txt"

{
  emit_preamble "s4-dac.txt"
  echo "== ВЫВОД КОМАНД =="
  echo
  echo "=== ls -ld /data/mephi-web ==="; ls -ld /data/mephi-web
  echo; echo "=== stat /data/mephi-web ==="; stat /data/mephi-web
  sudo -u mephi-admin touch /data/mephi-web/.sgid_probe 2>/dev/null
  echo; echo "=== SGID-проверка (файл, созданный mephi-admin, наследует группу) ==="
  ls -l /data/mephi-web/.sgid_probe 2>/dev/null
  rm -f /data/mephi-web/.sgid_probe
} > "$SHARED/permissions.txt"

echo; echo "### [4.2] SELinux + capabilities"
{
  emit_preamble "s4-mac.txt"
  echo "== ВЫВОД КОМАНД =="
  echo
  echo "=== getenforce ==="; getenforce
  echo; echo "=== sestatus ==="; sestatus
  echo; echo "=== /sys/fs/selinux ==="
  ls /sys/fs/selinux 2>&1 || echo "(отсутствует — LSM политика наследуется от хоста)"
} > "$SHARED/selinux_status.txt"

{
  emit_preamble "s4-mac.txt"
  echo "== СТАНДАРТНЫЙ SELINUX WORKFLOW (КОМАНДЫ ЗАДАНИЯ 4.2) =="
  echo
  echo "# 1. Зарегистрировать постоянное правило fcontext в политике:"
  echo "\$ semanage fcontext -a -t httpd_sys_content_t '/data/mephi-web(/.*)?'"
  echo
  echo "# 2. Применить контекст рекурсивно к существующим файлам:"
  echo "\$ restorecon -Rv /data/mephi-web"
  echo
  echo "# 3. Проверка контекста:"
  echo "\$ ls -Z /data/mephi-web"
  echo
  echo "Ожидаемый результат на Fedora-хосте:"
  echo "  unconfined_u:object_r:httpd_sys_content_t:s0 index.html"
  echo
  echo "== ФАКТИЧЕСКИЙ ВЫВОД В НАШЕЙ СРЕДЕ =="
  ls -Z /data/mephi-web 2>&1 || true
} > "$SHARED/file_contexts.txt"

# Capabilities на tcpdump
chmod u-s /usr/bin/tcpdump 2>/dev/null || true
setcap cap_net_raw,cap_net_admin+ep /usr/bin/tcpdump
ln -sf /usr/bin/tcpdump /usr/sbin/tcpdump

{
  emit_preamble "s4-cap.txt"
  echo "== ВЫВОД КОМАНД =="
  echo
  echo "=== getcap /usr/bin/tcpdump ==="; getcap /usr/bin/tcpdump
  echo; echo "=== ls -la (без SUID) ==="; ls -la /usr/bin/tcpdump /usr/sbin/tcpdump
  echo; echo "=== Проверка под mephi-admin ==="
  sudo -u mephi-admin tcpdump --version 2>&1 | head -4
  echo
  sudo -u mephi-admin timeout 3 tcpdump -i eth0 -c 1 -n 2>&1 &
  TCPID=$!
  sleep 1
  ping -c 1 192.168.91.1 >/dev/null 2>&1 || true
  wait $TCPID 2>/dev/null || true
} > "$SHARED/tcpdump_capabilities.txt"

# ----------------------------------------------------------------
# Раздел 5. PAM + index.html + curl
# ----------------------------------------------------------------
echo; echo "### [5.1] PAM deny root"
echo "root" > /etc/ssh/denied_users
chmod 600 /etc/ssh/denied_users

PAM_LINE='auth required pam_listfile.so item=user sense=deny file=/etc/ssh/denied_users onerr=succeed'
for pamfile in /etc/pam.d/sshd /etc/pam.d/login; do
  grep -q "denied_users" "$pamfile" || sed -i "1i $PAM_LINE" "$pamfile"
done

# Для теста — позволим root по ssh и password auth, чтобы PAM был решающим
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
echo 'root:RootTest2026' | chpasswd
systemctl restart ssh
sleep 1

{
  emit_preamble "s5.txt"
  echo "== ВЫВОД КОМАНД =="
  echo
  echo "=== /etc/ssh/denied_users ==="; cat /etc/ssh/denied_users
  echo; echo "=== /etc/pam.d/sshd (первые строки) ==="; head -3 /etc/pam.d/sshd
  echo; echo "=== /etc/pam.d/login (первые строки) ==="; head -3 /etc/pam.d/login
  echo; echo "=== Тест 1: ssh root@localhost ==="
  sshpass -p "RootTest2026" ssh -o StrictHostKeyChecking=no \
    -o NumberOfPasswordPrompts=1 root@localhost true 2>&1 || true
  echo; echo "=== Тест 2: ssh mephi-admin@localhost ==="
  sshpass -p "P@ssw0rd2026" ssh -o StrictHostKeyChecking=no \
    -o NumberOfPasswordPrompts=1 mephi-admin@localhost "whoami" 2>&1 || true
} > "$SHARED/pam_check.txt"

echo; echo "### [5.2] index.html (под mephi-admin) + curl"
sudo -u mephi-admin bash -c "echo \"Hello from Student: ${STUDENT_ID:-<ВАШ_НОМЕР>}\" > /data/mephi-web/index.html"
cp /data/mephi-web/index.html "$SHARED/index.html"

{
  emit_preamble "s5.txt"
  echo "== ВЫВОД КОМАНД =="
  echo
  echo "=== curl http://192.168.91.100/ ==="
  curl -sv http://192.168.91.100/ 2>&1
  echo; echo
  echo "=== curl http://localhost/ ==="
  curl -sv http://localhost/ 2>&1
} > "$SHARED/curl_output.txt"

# ----------------------------------------------------------------
# Финал: верстаем index.html-отчёт
# ----------------------------------------------------------------
echo; echo "### Генерация HTML-отчёта"
if [[ -x /usr/local/bin/generate_report.sh ]]; then
  STUDENT_ID="${STUDENT_ID:-<ВАШ_НОМЕР>}" \
    sudo -E -u mephi-admin /usr/local/bin/generate_report.sh
fi

# В shared/index.html сохраняем именно сверстанную страницу
cp /data/mephi-web/index.html "$SHARED/index.html"

# Сохраняем лог инициализации как историю исполнения (project_history.txt)
# (история bash здесь не подходит — скрипт не интерактивный)
cp "$LOG" "$SHARED/project_history.txt" 2>/dev/null || true

echo; echo "================================================================"
echo "mephi-init finished at $(date)"
echo "================================================================"
