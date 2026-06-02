#!/usr/bin/env bash
# Генератор index.html-отчёта по проекту МИФИ.
# Запускается внутри контейнера от имени mephi-admin (см. README).
# Содержимое разделов rationale читается из /opt/mephi-content/*.html,
# чтобы текст можно было править отдельно от верстки.
set -uo pipefail

SHARED="${SHARED_DIR:-/shared}"
CONTENT="${CONTENT_DIR:-/opt/mephi-content}"
OUT="${OUT_FILE:-/data/mephi-web/index.html}"
STUDENT_ID="${STUDENT_ID:-<ВАШ_НОМЕР>}"

esc() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$1"
}

read_artifact() {
    if [[ -f "$1" ]]; then
        esc "$1"
    else
        echo "(файл $1 отсутствует)"
    fi
}

# Рендерит .txt-блок из content/ в HTML.
# Формат source:
#   ## Термин            ← начало блока (станет <dt>)
#   текст определения    ← <dd>; может занимать несколько строк
#   `code` → <code>code</code>
emit_rationale() {
    local file="$CONTENT/$1"
    [[ -f "$file" ]] || return 0
    printf '<div class="rationale"><dl>\n'
    awk '
        function flush_dd() {
            if (dd != "") {
                # обрезаем хвостовые пустые строки
                sub(/[[:space:]\n]+$/, "", dd)
                printf("<dd>%s</dd>\n", dd)
                dd = ""
            }
        }
        /^## / {
            flush_dd()
            term = $0; sub(/^## /, "", term)
            # экранируем HTML в термине
            gsub(/&/, "\\&amp;", term); gsub(/</, "\\&lt;", term); gsub(/>/, "\\&gt;", term)
            printf("<dt>%s</dt>", term)
            in_def = 1
            next
        }
        in_def {
            line = $0
            # HTML-escape
            gsub(/&/, "\\&amp;", line); gsub(/</, "\\&lt;", line); gsub(/>/, "\\&gt;", line)
            # Backticks → <code>
            while (match(line, /`[^`]*`/)) {
                inner = substr(line, RSTART + 1, RLENGTH - 2)
                line = substr(line, 1, RSTART - 1) "<code>" inner "</code>" substr(line, RSTART + RLENGTH)
            }
            dd = dd (dd == "" ? "" : " ") line
        }
        END { flush_dd() }
    ' "$file"
    printf '</dl></div>\n'
}

GEN_DATE=$(date '+%Y-%m-%d %H:%M:%S %Z')
HOSTNAME_FQDN=$(hostname -f 2>/dev/null || hostname)
KERNEL=$(uname -r)
DISTRO=$(. /etc/os-release && echo "$PRETTY_NAME")

cat > "$OUT" <<HTML_HEAD
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<title>МИФИ — итоговый проект 2026</title>
<style>
  :root {
    --bg: #f7f8fa;
    --card: #ffffff;
    --ink: #1a1d23;
    --muted: #6b7280;
    --accent: #2563eb;
    --accent-soft: #eff6ff;
    --line: #e5e7eb;
    --code-bg: #0f172a;
    --code-ink: #e2e8f0;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; background: var(--bg); color: var(--ink);
               font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
               line-height: 1.6; }
  .wrap { max-width: 980px; margin: 0 auto; padding: 32px 24px 64px; }

  header.hero { padding: 28px 32px; background: linear-gradient(135deg, #2563eb, #1e3a8a);
                color: white; border-radius: 16px; margin-bottom: 28px;
                box-shadow: 0 4px 24px rgba(37, 99, 235, 0.18); }
  header.hero h1 { margin: 0 0 6px; font-size: 28px; font-weight: 700; letter-spacing: -0.02em; }
  header.hero .student { font-size: 20px; font-weight: 500; opacity: 0.95; }
  header.hero .meta { margin-top: 18px; font-size: 13px; opacity: 0.85;
                      display: flex; flex-wrap: wrap; gap: 18px; }
  header.hero .meta span b { font-weight: 600; }

  nav.toc { background: var(--card); border: 1px solid var(--line); border-radius: 12px;
            padding: 18px 22px; margin-bottom: 28px; }
  nav.toc h2 { font-size: 14px; text-transform: uppercase; letter-spacing: 0.08em;
               color: var(--muted); margin: 0 0 10px; }
  nav.toc ol { margin: 0; padding-left: 20px; }
  nav.toc li { margin: 4px 0; }
  nav.toc a { color: var(--accent); text-decoration: none; }
  nav.toc a:hover { text-decoration: underline; }

  section.card { background: var(--card); border: 1px solid var(--line); border-radius: 12px;
                 padding: 22px 26px; margin-bottom: 20px; }
  section.card h2 { margin: 0 0 4px; font-size: 20px; }
  section.card .lead { color: var(--muted); margin: 0 0 14px; font-size: 14px; }

  .rationale { background: var(--accent-soft); border-left: 3px solid var(--accent);
               padding: 12px 16px; border-radius: 6px; margin: 14px 0 18px;
               font-size: 14px; }
  .rationale dl { margin: 0; display: grid; grid-template-columns: 130px 1fr; gap: 6px 14px; }
  .rationale dt { font-weight: 600; color: var(--accent); }
  .rationale dd { margin: 0; }

  h3.sub { margin: 18px 0 8px; font-size: 14px; color: var(--ink);
           text-transform: uppercase; letter-spacing: 0.05em; }
  pre { background: var(--code-bg); color: var(--code-ink); padding: 14px 16px;
        border-radius: 8px; overflow-x: auto; font-size: 12.5px;
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
        line-height: 1.5; margin: 0 0 10px; }

  footer { text-align: center; color: var(--muted); font-size: 12px; margin-top: 32px; }
</style>
</head>
<body>
<div class="wrap">

<header class="hero">
  <h1>МИФИ — итоговый проект 2026</h1>
  <div class="student">Hello from Student: ${STUDENT_ID}</div>
  <div class="meta">
    <span><b>Hostname:</b> ${HOSTNAME_FQDN}</span>
    <span><b>OS:</b> ${DISTRO}</span>
    <span><b>Kernel:</b> ${KERNEL}</span>
    <span><b>Сгенерировано:</b> ${GEN_DATE}</span>
  </div>
</header>

<section class="card">
  <h2>Об архитектуре проекта</h2>
  <p>Задание реализовано в формате Infrastructure-as-Code: один файл
  <code>docker-compose.yml</code>, два вспомогательных скрипта
  (<code>init.sh</code>, <code>generate_report.sh</code>) и одно описание
  systemd-юнита. После <code>git clone</code> и <code>docker compose up -d</code>
  стенд разворачивается с нуля за ~20 секунд на любом устройстве,
  где есть Docker — Linux, macOS, Windows (WSL2). Никаких ручных шагов.</p>
  $(emit_rationale "intro.txt")
</section>

<nav class="toc">
  <h2>Содержание</h2>
  <ol>
    <li><a href="#s1">Управление сетью</a></li>
    <li><a href="#s2">Управление программным обеспечением</a></li>
    <li><a href="#s3">Файловые системы и сервисы</a></li>
    <li><a href="#s4">Управление доступом (DAC, MAC, capabilities)</a></li>
    <li><a href="#s5">Аутентификация и итоговая проверка</a></li>
  </ol>
</nav>

<section class="card" id="s1">
  <h2>1. Управление сетью</h2>
  <p class="lead">Статический IP, шлюз, DNS через nmcli; hostname через hostnamectl; проверка связности.</p>
  $(emit_rationale "s1.txt")
  <h3 class="sub">Артефакт: network_check.txt</h3>
  <pre>$(read_artifact "$SHARED/network_check.txt")</pre>
</section>

<section class="card" id="s2">
  <h2>2. Программное обеспечение</h2>
  <p class="lead">Установка nginx, tcpdump, libcap2-bin через пакетный менеджер; скачивание и установка локального бинарного пакета.</p>
  $(emit_rationale "s2.txt")
  <h3 class="sub">Установленные версии</h3>
  <pre>$(nginx -v 2>&1 | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
$(tcpdump --version 2>&1 | head -2 | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
$(dpkg -l tcpdump 2>/dev/null | tail -1 | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')</pre>
  <h3 class="sub">Артефакт: tcpdump.deb</h3>
  <pre>$(ls -lh "$SHARED/tcpdump.deb" 2>&1 | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')</pre>
</section>

<section class="card" id="s3">
  <h2>3. Файловые системы и сервисы</h2>
  <p class="lead">Раздел ext4 с меткой MEPHI_DATA, автомонтирование по LABEL через fstab; nginx как systemd-юнит.</p>
  $(emit_rationale "s3.txt")
  <h3 class="sub">Артефакт: fstab.txt</h3>
  <pre>$(read_artifact "$SHARED/fstab.txt")</pre>
  <h3 class="sub">Артефакт: nginx_recent_logs.txt</h3>
  <pre>$(read_artifact "$SHARED/nginx_recent_logs.txt")</pre>
</section>

<section class="card" id="s4">
  <h2>4. Управление доступом</h2>
  <p class="lead">DAC: пользователь mephi-admin, группа mephi-devs, владелец каталога, SGID 2775. MAC: SELinux. Capabilities: cap_net_raw + cap_net_admin на tcpdump.</p>

  <h3 class="sub">4.1 DAC</h3>
  $(emit_rationale "s4-dac.txt")
  <h3 class="sub">users_groups.txt</h3>
  <pre>$(read_artifact "$SHARED/users_groups.txt")</pre>
  <h3 class="sub">permissions.txt</h3>
  <pre>$(read_artifact "$SHARED/permissions.txt")</pre>

  <h3 class="sub">4.2 MAC (SELinux)</h3>
  $(emit_rationale "s4-mac.txt")
  <h3 class="sub">selinux_status.txt</h3>
  <pre>$(read_artifact "$SHARED/selinux_status.txt")</pre>
  <h3 class="sub">file_contexts.txt</h3>
  <pre>$(read_artifact "$SHARED/file_contexts.txt")</pre>

  <h3 class="sub">4.2 Capabilities на tcpdump</h3>
  $(emit_rationale "s4-cap.txt")
  <h3 class="sub">tcpdump_capabilities.txt</h3>
  <pre>$(read_artifact "$SHARED/tcpdump_capabilities.txt")</pre>
</section>

<section class="card" id="s5">
  <h2>5. Аутентификация и итоговая проверка</h2>
  <p class="lead">PAM-модуль pam_listfile.so запрещает вход root по SSH и локальной консоли; nginx отдаёт страницу из /data/mephi-web под mephi-admin.</p>
  $(emit_rationale "s5.txt")
  <h3 class="sub">5.1 pam_check.txt</h3>
  <pre>$(read_artifact "$SHARED/pam_check.txt")</pre>
  <h3 class="sub">5.2 index.html (создан под mephi-admin)</h3>
  <pre>Hello from Student: ${STUDENT_ID}</pre>
  <h3 class="sub">5.2 curl_output.txt</h3>
  <pre>$(read_artifact "$SHARED/curl_output.txt")</pre>
</section>

<footer>
  Сгенерировано generate_report.sh — ${GEN_DATE}
</footer>

</div>
</body>
</html>
HTML_HEAD

echo "Готово: $OUT"
ls -l "$OUT"
