#!/usr/bin/env bash
#
# bootstrap.sh v1.2.0 — первичная настройка свежего Ubuntu-сервера (24.04 / 26.04)
#
# Универсальная база для удобной и безопасной работы (не заточена под VPN).
# v1.2.0 — закрыты блокеры потери доступа, найденные при аудите v1.1.0:
#   * root больше не режется молча (PermitRootLogin prohibit-password, root в AllowUsers)
#   * AllowUsers не сужается до одного пользователя
#   * ufw откатывается вместе с SSH-транзакцией
#   * fail2ban следит и за прежним портом SSH
#   * --block-ping идемпотентен в обе стороны
#   * предупреждение про cloud firewall / security group
#   * curl со --proto-redir '=https', проверка sha256
#   * --check: валидация окружения без изменений системы
#   * self-verification после установки (FAIL/WARN с кодом возврата)
#
# Требования: Ubuntu 24.04/26.04, root, systemd (в контейнере часть шагов пропускается),
#             >= 1.5 ГБ свободного места на /, рабочий DNS/доступ к зеркалам apt.
#
# Запуск от root, одна команда, без флагов — скрипт сам спросит публичный ключ:
#   bash <(curl -fsSL --proto '=https' --proto-redir '=https' \
#          https://raw.githubusercontent.com/USER/REPO/<COMMIT_SHA>/bootstrap.sh)
# Без вопросов: ... | bash -s -- --key "ssh-ed25519 AAAA... me"   или   --github USERNAME
#
# Повторный запуск безопасен. Лог: /var/log/bootstrap.log (0600). Бэкапы: /var/backups/bootstrap/
#
# ВАЖНО про порядок: UFW включается ДО смены порта SSH, поэтому открытыми остаются и новый,
# и текущие порты sshd. Если смена порта не удаётся — SSH откатывается вместе с правилами ufw.
#
set -Eeuo pipefail
umask 022

SCRIPT_VERSION="1.2.0"
LOG="${LOG:-/var/log/bootstrap.log}"
LOCK="${LOCK:-/run/bootstrap.lock}"
BACKUP_DIR="/var/backups/bootstrap/$(date +%Y%m%d-%H%M%S)"

# ───────────────────────── настройки (env или флаги) ─────────────────────────
NEW_USER="${NEW_USER:-super}"
SSH_PORT="${SSH_PORT:-49500}"
SSH_KEYS="${SSH_KEYS:-}"
KEYS_FILE="${KEYS_FILE:-}"
GITHUB_USER="${GITHUB_USER:-}"
OPEN_PORTS="${OPEN_PORTS-}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
TIMEZONE="${TIMEZONE:-}"
NEW_HOSTNAME="${NEW_HOSTNAME:-}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
INSTALL_DOCKER="${INSTALL_DOCKER:-0}"
DOCKER_UFW="${DOCKER_UFW:-0}"       # защитить опубликованные порты docker от обхода ufw
BLOCK_PING="${BLOCK_PING:-0}"
SET_UMASK="${SET_UMASK:-1}"         # umask 0077 для пользователя (v1.2: включено по умолчанию)
AUTOREMOVE="${AUTOREMOVE:-0}"
SKIP_UPGRADE="${SKIP_UPGRADE:-0}"
KEEP_ROOT="${KEEP_ROOT:-1}"         # 1 = root может входить по ключу (prohibit-password)
LOCK_ROOT="${LOCK_ROOT:-0}"         # 1 = passwd -l root (ломает вход по паролю в VNC-консоли)
ALLOW_USERS="${ALLOW_USERS:-}"      # пусто = NEW_USER + все существующие human-аккаунты (+root при KEEP_ROOT)
DO_REBOOT="${DO_REBOOT:-0}"
FORCE="${FORCE:-0}"
CHECK="${CHECK:-0}"
SHA_EXPECT="${SHA_EXPECT:-}"
KEY_ARGS=()

usage() {
  cat <<EOF
bootstrap.sh v$SCRIPT_VERSION — первичная настройка Ubuntu 24.04 / 26.04 (запускать от root)

Ключи (нужен хотя бы один источник; если ничего не дал — берутся из /root/.ssh/authorized_keys):
  -k, --key "ssh-ed25519 AAAA..."   публичный ключ (можно несколько раз)
      --keys-file FILE              файл с ключами
      --github USER                 забрать ключи с https://github.com/USER.keys
      env SSH_KEYS                  ключи через перевод строки

Основное:
  -u, --user NAME        имя пользователя (по умолчанию: super)
  -p, --ssh-port N       порт SSH (по умолчанию: 49500)
      --allow-users "L"  кому разрешён вход по SSH (по умолчанию: новый юзер + все
                         существующие human-аккаунты, плюс root при --keep-root)
      --ports "LIST"     что открыть в ufw кроме SSH, напр. "80/tcp 443/tcp 6000:6010/tcp"
                         (диапазон — только с /tcp или /udp; по умолчанию: ничего)
      --swap SIZE        размер swap: 512M, 2G, 0 = выключить (по умолчанию 2G)
      --timezone TZ      например Europe/Moscow
      --hostname NAME    сменить hostname
      --packages "LIST"  доп. пакеты apt (опции apt не поддерживаются)

Политика root:
      --keep-root        PermitRootLogin prohibit-password (по умолчанию)
      --no-root          PermitRootLogin no, root исключается из AllowUsers
      --lock-root        дополнительно passwd -l root (пароль root, в т.ч. в VNC-консоли, перестанет работать)

Опции:
      --docker           поставить docker.io + docker-compose-v2
      --docker-ufw       + правила DOCKER-USER (docker больше не обходит ufw для опубликованных портов)
      --block-ping       не отвечать на ping (только IPv4 echo-request, PMTUD не ломаем)
      --no-umask         не ставить umask 0077 пользователю
      --autoremove       выполнить apt autoremove --purge
      --no-upgrade       не делать apt full-upgrade
      --reboot           перезагрузиться в конце (через 1 минуту, отмена: shutdown -c)
      --force            не падать на неподдерживаемой версии Ubuntu / системном пользователе
      --check            только валидация окружения и печать плана, систему не менять
      --sha256 HEX       сверить sha256 самого скрипта (при запуске из файла)
  -h, --help
EOF
}

while (($#)); do
  case "$1" in
    -k|--key)        KEY_ARGS+=("${2:?нужен ключ}"); shift 2 ;;
    --keys-file)     KEYS_FILE="${2:?}"; shift 2 ;;
    --github)        GITHUB_USER="${2:?}"; shift 2 ;;
    -u|--user)       NEW_USER="${2:?}"; shift 2 ;;
    -p|--ssh-port)   SSH_PORT="${2:?}"; shift 2 ;;
    --allow-users)   ALLOW_USERS="${2:?}"; shift 2 ;;
    --ports)         OPEN_PORTS="${2-}"; shift 2 ;;
    --swap)          SWAP_SIZE="${2:?}"; shift 2 ;;
    --timezone)      TIMEZONE="${2:?}"; shift 2 ;;
    --hostname)      NEW_HOSTNAME="${2:?}"; shift 2 ;;
    --packages)      EXTRA_PACKAGES="${2-}"; shift 2 ;;
    --keep-root)     KEEP_ROOT=1; shift ;;
    --no-root)       KEEP_ROOT=0; shift ;;
    --lock-root)     LOCK_ROOT=1; shift ;;
    --docker)        INSTALL_DOCKER=1; shift ;;
    --docker-ufw)    INSTALL_DOCKER=1; DOCKER_UFW=1; shift ;;
    --block-ping)    BLOCK_PING=1; shift ;;
    --no-umask)      SET_UMASK=0; shift ;;
    --autoremove)    AUTOREMOVE=1; shift ;;
    --no-upgrade)    SKIP_UPGRADE=1; shift ;;
    --reboot)        DO_REBOOT=1; shift ;;
    --force)         FORCE=1; shift ;;
    --check)         CHECK=1; shift ;;
    --sha256)        SHA_EXPECT="${2:?}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ───────────────────── root, лог, блокировка, временные файлы ─────────────────
[[ $EUID -eq 0 ]] || { echo "Запускай от root (sudo -i, потом bash bootstrap.sh ...)" >&2; exit 1; }

install -d -m 755 "$(dirname "$LOG")"
[[ -e "$LOG" ]] || install -m 600 /dev/null "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1

ts()   { date '+%F %T'; }
log()  { printf '%s [+] %s\n' "$(ts)" "$*"; }
warn() { printf '%s [!] %s\n' "$(ts)" "$*" >&2; }
die()  { printf '%s [x] %s\n' "$(ts)" "$*" >&2; exit 1; }
step() { printf '\n%s ══ %s\n' "$(ts)" "$*"; }

exec 9>"$LOCK"
flock -n 9 || die "Уже запущен другой экземпляр bootstrap.sh (lock: $LOCK)"

WORKDIR="$(mktemp -d)"

# sha256 самого скрипта (для процесса подстановки fd не перечитываем — там отдаём n/a)
SCRIPT_SHA="n/a"
case "${BASH_SOURCE[0]:-}" in
  /dev/fd/*|/proc/self/fd/*|pipe:*) : ;;
  *) [[ -r "${BASH_SOURCE[0]:-}" ]] && SCRIPT_SHA="$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')" ;;
esac

# Состояние SSH-транзакции: пока SSH_TXN=1, любой выход со сбоем откатывает SSH-конфиг И правила ufw.
SSHD_DROPIN=/etc/ssh/sshd_config.d/00-bootstrap.conf
SOCK_DROPIN=/etc/systemd/system/ssh.socket.d/zz-bootstrap-port.conf
SSHD_PREV="$WORKDIR/sshd-dropin.prev"; SOCK_PREV="$WORKDIR/sock-dropin.prev"
SSHD_HAD=0; SOCK_HAD=0; SSH_TXN=0; SSH_CUT=0; SOCKET_MODE=0
OLD_SSH_PORTS=(); NEW_UFW_PORTS=()

HAS_SYSTEMD=0; [[ -d /run/systemd/system ]] && HAS_SYSTEMD=1
svc() {
  if ((HAS_SYSTEMD)); then systemctl "$@"
  else warn "systemd не запущен (chroot/контейнер) — пропускаю: systemctl $*"; fi
}

# v1.2: в сокетном режиме не запускаем ssh.service вслепую — иначе два бинда на один порт.
restart_ssh() {
  ((HAS_SYSTEMD)) || { warn "systemd нет — ssh не перезапускаю"; return 0; }
  systemctl daemon-reload || return 1
  if ((SOCKET_MODE)); then
    systemctl restart ssh.socket || return 1
    if systemctl is-active --quiet ssh.service; then systemctl reload-or-restart ssh.service || return 1; fi
  else
    systemctl reload-or-restart ssh || systemctl restart ssh || return 1
  fi
}

rollback_ssh() {
  ((SSH_TXN)) || return 0
  SSH_TXN=0
  warn "Откатываю SSH-конфиг и правила ufw, добавленные транзакцией"
  if ((SSHD_HAD)); then cp -a "$SSHD_PREV" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
  if ((SOCK_HAD)); then cp -a "$SOCK_PREV" "$SOCK_DROPIN"; else rm -f "$SOCK_DROPIN"; fi
  local p
  for p in "${NEW_UFW_PORTS[@]}"; do ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true; done
  ufw reload >/dev/null 2>&1 || true
  if ((SSH_CUT)); then
    restart_ssh || warn "ssh не перезапустился после отката — проверь вручную. В ufw остаются открытыми порты: ${OLD_SSH_PORTS[*]:-22}"
  fi
}

on_exit() {
  local rc=$?
  trap - ERR
  rollback_ssh || true
  rm -rf "$WORKDIR"
  exit "$rc"
}
trap on_exit EXIT
trap 'die "Прервано сигналом"' INT TERM
trap 'die "Упало на строке $LINENO (команда: $BASH_COMMAND). Поправь и запусти заново. Лог: $LOG"' ERR

# ───────────────────────────────── утилиты ───────────────────────────────────
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
          -o DPkg::Lock::Timeout=600 -o Acquire::Retries=3)
apt_run() { apt-get "${APT_OPTS[@]}" "$@" </dev/null; }

# Только для необязательных пакетов: без recommends (nmap/telnet и прочая мишура).
apt_install() {
  local ok=() p
  for p in "$@"; do
    if [[ "$p" == -* ]]; then continue; fi
    if apt-cache show --no-all-versions "$p" &>/dev/null; then ok+=("$p")
    else warn "пакета $p нет в этом релизе — пропускаю"; fi
  done
  if ((${#ok[@]})); then apt_run install --no-install-recommends "${ok[@]}"; fi
  return 0
}

backup_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  install -d -m 700 "$BACKUP_DIR"
  cp -a "$f" "$BACKUP_DIR/$(printf '%s' "${f#/}" | tr / _)"
}

WRITE_CHANGED=0
write_file() {
  local path="$1" mode="$2" tmp
  WRITE_CHANGED=0
  tmp="$(mktemp -p "$WORKDIR")"; cat >"$tmp"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 0; fi
  backup_file "$path"
  install -m "$mode" -o root -g root "$tmp" "$path"; rm -f "$tmp"
  WRITE_CHANGED=1
  log "записал $path"
}

os_field() { ( . /etc/os-release; printf '%s' "${!1:-}" ); }

valid_port_num() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }

port_in_array() {
  local x="$1" e; shift
  for e in "$@"; do [[ "$e" == "$x" ]] && return 0; done
  return 1
}

# v1.2: human-аккаунты, которым имеет смысл разрешить SSH
collect_human_users() {
  awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd | sort -u
}

# Порты, на которых SSH доступен ПРЯМО СЕЙЧАС (конфиг sshd, ssh.socket, текущая сессия).
detect_ssh_ports() {
  local c=""
  mkdir -p /run/sshd
  {
    if command -v sshd >/dev/null 2>&1; then sshd -T 2>/dev/null | awk '$1=="port"{print $2}'; fi
    if ((HAS_SYSTEMD)); then
      systemctl show ssh.socket -p Listen --value 2>/dev/null | grep -oE ':[0-9]+ \(Stream\)' | tr -dc '0-9\n'
    fi
    c="${SSH_CONNECTION:-}"
    if [[ -n "$c" ]]; then echo "${c##* }"; fi
  } | grep -E '^[0-9]+$' | sort -un || true
}

# ───────────────────────────── проверка окружения ────────────────────────────
step "0/12 Проверки"
log "bootstrap.sh v$SCRIPT_VERSION, sha256=$SCRIPT_SHA"
if [[ -n "$SHA_EXPECT" && "$SCRIPT_SHA" != "n/a" && "$SCRIPT_SHA" != "$SHA_EXPECT" ]]; then
  die "sha256 не совпал: ожидался $SHA_EXPECT, получен $SCRIPT_SHA"
elif [[ -n "$SHA_EXPECT" && "$SCRIPT_SHA" == "n/a" ]]; then
  warn "--sha256 задан, но скрипт запущен из процесса подстановки — сверка пропущена"
fi

[[ -r /etc/os-release ]] || die "нет /etc/os-release"
OS_ID="$(os_field ID)"; OS_VER="$(os_field VERSION_ID)"; OS_CODENAME="$(os_field VERSION_CODENAME)"
[[ "$OS_ID" == ubuntu ]] || die "Это не Ubuntu (ID=${OS_ID:-?})"
case "$OS_VER" in
  24.04|26.04) log "Ubuntu $OS_VER (${OS_CODENAME:-?}) — поддерживается" ;;
  *) if ((FORCE)); then warn "Ubuntu ${OS_VER:-?} не тестировалась, продолжаю (--force)"
     else die "Поддерживаются 24.04 и 26.04, у тебя ${OS_VER:-?}. Можно --force на свой риск."; fi ;;
esac

[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Некорректное имя пользователя: $NEW_USER"
[[ "$NEW_USER" != root ]] || die "Пользователь не должен быть root"
valid_port_num "$SSH_PORT" || die "Некорректный SSH-порт: $SSH_PORT"
SSH_PORT=$((10#$SSH_PORT))
[[ "$SWAP_SIZE" =~ ^(0|[1-9][0-9]*[MG])$ ]] || die "SWAP_SIZE должен быть 0, 512M, 2G и т.п."

read -r -a OPEN_ARR <<<"$OPEN_PORTS"
for p in "${OPEN_ARR[@]}"; do
  if [[ "$p" =~ ^([0-9]{1,5})(/(tcp|udp))?$ ]]; then
    valid_port_num "${BASH_REMATCH[1]}" || die "Некорректный порт в --ports: $p"
  elif [[ "$p" =~ ^([0-9]{1,5}):([0-9]{1,5})/(tcp|udp)$ ]]; then
    pa="${BASH_REMATCH[1]}"; pb="${BASH_REMATCH[2]}"
    if ! { valid_port_num "$pa" && valid_port_num "$pb" && ((10#$pa <= 10#$pb)); }; then
      die "Некорректный диапазон в --ports: $p"
    fi
  else
    die "Некорректный порт в --ports: $p (диапазон допустим только с /tcp или /udp)"
  fi
done

if [[ -n "$TIMEZONE" && ! -e "/usr/share/zoneinfo/$TIMEZONE" ]]; then die "Нет такой таймзоны: $TIMEZONE"; fi
if [[ -n "$NEW_HOSTNAME" ]] && ! [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,60}[a-zA-Z0-9])?$ ]]; then
  die "Некорректный hostname: $NEW_HOSTNAME"
fi
if [[ -n "$EXTRA_PACKAGES" && "$EXTRA_PACKAGES" =~ (^|[[:space:]])- ]]; then
  die "EXTRA_PACKAGES/--packages не поддерживает опции apt (начинающиеся с -): '$EXTRA_PACKAGES'"
fi

# Существующий пользователь: не выдаём NOPASSWD-sudo системным и nologin-аккаунтам.
if id "$NEW_USER" &>/dev/null; then
  U_UID="$(id -u "$NEW_USER")"; U_SHELL="$(getent passwd "$NEW_USER" | cut -d: -f7)"
  if ((U_UID < 1000)) && ! ((FORCE)); then die "$NEW_USER — системный аккаунт (UID $U_UID). Выбери другое имя (или --force)."; fi
  case "$U_SHELL" in
    */nologin|*/false) if ! ((FORCE)); then die "У $NEW_USER shell=$U_SHELL — войти нельзя. Выбери другое имя (или --force)."; fi ;;
  esac
fi

# v1.2: AllowUsers не сужаем. Пусто = NEW_USER + существующие human-аккаунты (+root при KEEP_ROOT).
if [[ -z "$ALLOW_USERS" ]]; then
  ALLOW_USERS="$NEW_USER"
  while read -r u; do
    [[ -z "$u" || "$u" == "$NEW_USER" || "$u" == root ]] && continue
    ALLOW_USERS+=" $u"
  done < <(collect_human_users)
else
  ALLOW_USERS="${ALLOW_USERS//,/ }"
fi
((KEEP_ROOT)) && ALLOW_USERS+=" root"
ALLOW_USERS="$(printf '%s' "$ALLOW_USERS" | xargs)"
for u in $ALLOW_USERS; do
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Некорректное имя в --allow-users: $u"
done
log "AllowUsers: $ALLOW_USERS"

if ((KEEP_ROOT)); then ROOT_LOGIN_MODE=prohibit-password; else ROOT_LOGIN_MODE=no; fi

VIRT="$(systemd-detect-virt -c 2>/dev/null || true)"; [[ "$VIRT" == none ]] && VIRT=""
if [[ -n "$VIRT" ]]; then warn "Контейнер ($VIRT): swap и часть sysctl будут пропущены"; fi

FREE_ROOT_MB="$(df -Pk / | awk 'NR==2{print int($4/1024)}')"
((FREE_ROOT_MB >= 1536)) || die "Мало места на / (${FREE_ROOT_MB}M, нужно >= 1536M)"
getent hosts archive.ubuntu.com >/dev/null 2>&1 || warn "archive.ubuntu.com не резолвится — apt может упасть (проверь DNS)"

if ! command -v ss >/dev/null 2>&1; then
  if ((CHECK)); then log "iproute2 не установлен (нужен для ss) — будет поставлен"
  else log "ставлю iproute2 (нужен ss)"; apt_run update; apt_run install iproute2; fi
fi
if ((HAS_SYSTEMD)) && systemctl is-enabled ssh.socket &>/dev/null; then SOCKET_MODE=1; fi
mapfile -t OLD_SSH_PORTS < <(detect_ssh_ports)

# v1.2: если действующие порты определить не удалось — не гадаем молча
if ((${#OLD_SSH_PORTS[@]} == 0)); then
  if [[ -n "${SSH_CONNECTION:-}" ]]; then OLD_SSH_PORTS=("${SSH_CONNECTION##* }")
  elif ((FORCE)); then warn "порты SSH не определены, предполагаю 22 (--force)"; OLD_SSH_PORTS=(22)
  else die "Не удалось определить действующие порты SSH и нет SSH_CONNECTION. Запусти по SSH или добавь --force."; fi
fi
if ! port_in_array "$SSH_PORT" "${OLD_SSH_PORTS[@]}" && command -v ss >/dev/null 2>&1 \
   && ss -H -ltn "sport = :$SSH_PORT" 2>/dev/null | grep -q .; then
  die "Порт $SSH_PORT уже занят другим сервисом — выбери другой (--ssh-port)"
fi
log "текущие порты SSH: ${OLD_SSH_PORTS[*]}; новый: $SSH_PORT"

if ((CHECK)); then
  printf '\n%s ════════════════ ПЛАН (--check) ════════════════\n' "$(ts)"
  echo "Пользователь:      $NEW_USER (sudo NOPASSWD), umask=$([[ $SET_UMASK == 1 ]] && echo 0077 || echo не трогаем)"
  echo "SSH-порт:          $SSH_PORT (прежние останутся открыты: ${OLD_SSH_PORTS[*]})"
  echo "AllowUsers:        $ALLOW_USERS"
  echo "PermitRootLogin:   $ROOT_LOGIN_MODE | passwd -l root: $([[ $LOCK_ROOT == 1 ]] && echo да || echo нет)"
  echo "Открыть в ufw:     ${OPEN_ARR[*]:-только SSH}"
  echo "swap:              ${SWAP_SIZE}${VIRT:+ (контейнер — пропуск)}"
  echo "hostname/timezone: ${NEW_HOSTNAME:-не трогаю} / ${TIMEZONE:-не трогаю}"
  echo "docker:            $([[ $INSTALL_DOCKER == 1 ]] && echo да || echo нет)$([[ $DOCKER_UFW == 1 ]] && echo ' + DOCKER-USER')"
  echo "block-ping:        $([[ $BLOCK_PING == 1 ]] && echo да || echo н��т)"
  echo "пакеты:            база + ${EXTRA_PACKAGES:-—}"
  echo; log "--check: систему не менял"
  exit 0
fi

# ───────────────────────────────── SSH-ключи ─────────────────────────────────
step "1/12 Собираю SSH-ключи"
KEYS_TMP="$(mktemp -p "$WORKDIR")"

if ! command -v ssh-keygen >/dev/null 2>&1; then
  log "ставлю openssh-client для проверки ключей"; apt_run update; apt_run install openssh-client
fi

prompt_for_key() {
  { : </dev/tty; } 2>/dev/null || return 1
  local line one tries=0
  {
    printf '\n┌─ Вставь свой ПУБЛИЧНЫЙ SSH-ключ (одна строка из .pub: ssh-ed25519 AAAA... ) и нажми Enter.\n'
    printf '└─ Пустой ввод — взять ключи из /root/.ssh/authorized_keys (если они есть).\n'
  } >/dev/tty
  while ((tries < 3)); do
    printf '> ' >/dev/tty
    IFS= read -r line </dev/tty || return 1
    line="${line//$'\r'/}"
    [[ -z "${line//[[:space:]]/}" ]] && return 1
    if [[ "$line" == *"PRIVATE KEY"* ]]; then
      warn "Это ПРИВАТНЫЙ ключ! Нужен публичный (файл .pub)."
      tries=$((tries+1)); continue
    fi
    one="$(mktemp -p "$WORKDIR")"; printf '%s\n' "$line" >"$one"
    if ssh-keygen -l -f "$one" >/dev/null 2>&1; then
      rm -f "$one"; printf '%s\n' "$line" >>"$KEYS_TMP"; return 0
    fi
    rm -f "$one"; warn "Не похоже на публичный ключ, попробуй ещё раз"
    tries=$((tries+1))
  done
  return 1
}

# v1.2: добавлен тип сертификата
KEYTYPE_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-ed25519-cert-v01@openssh\.com|ssh-rsa-cert-v01@openssh\.com|ecdsa-sha2-nistp(256|384|521)-cert-v01@openssh\.com)$'

if [[ -n "$SSH_KEYS" ]]; then printf '%s\n' "$SSH_KEYS" >>"$KEYS_TMP"; fi
for k in "${KEY_ARGS[@]}"; do printf '%s\n' "$k" >>"$KEYS_TMP"; done
if [[ -n "$KEYS_FILE" ]]; then
  [[ -r "$KEYS_FILE" ]] || die "Не могу прочитать $KEYS_FILE"
  cat "$KEYS_FILE" >>"$KEYS_TMP"; echo >>"$KEYS_TMP"
fi
if [[ -n "$GITHUB_USER" ]]; then
  [[ "$GITHUB_USER" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]] || die "Некорректное имя GitHub-пользователя"
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 --max-time 20 \
    "https://github.com/${GITHUB_USER}.keys" >>"$KEYS_TMP" \
    || die "Не смог скачать ключи github.com/$GITHUB_USER"
  echo >>"$KEYS_TMP"
fi
grep -Eq '^\s*[^#[:space:]]' "$KEYS_TMP" || prompt_for_key || true

if ! grep -Eq '^\s*[^#[:space:]]' "$KEYS_TMP" && [[ -s /root/.ssh/authorized_keys ]]; then
  warn "Ключи не переданы — беру из /root/.ssh/authorized_keys (опции command=/from= срезаю). Сверь отпечатки ниже!"
  awk -v re="$KEYTYPE_RE" '
    /^[[:space:]]*(#|$)/ {next}
    { for (i=1;i<=NF;i++) if ($i ~ re) { s=$i; for (j=i+1;j<=NF;j++) s=s" "$j; print s; next } }
  ' /root/.ssh/authorized_keys >>"$KEYS_TMP"
fi

if grep -q 'PRIVATE KEY' "$KEYS_TMP"; then die "В ключах лежит ПРИВАТНЫЙ ключ. Нужен публичный (.pub)!"; fi
CLEAN_KEYS="$(mktemp -p "$WORKDIR")"
grep -Ev '^\s*(#|$)' "$KEYS_TMP" | sed 's/\r$//' | awk '!seen[$0]++' >"$CLEAN_KEYS" || true

N_KEYS=0
while IFS= read -r line; do
  one="$(mktemp -p "$WORKDIR")"; printf '%s\n' "$line" >"$one"
  ssh-keygen -l -f "$one" >/dev/null 2>&1 || { rm -f "$one"; die "Невалидный публичный ключ: ${line:0:60}..."; }
  rm -f "$one"; N_KEYS=$((N_KEYS+1))
done <"$CLEAN_KEYS"
((N_KEYS > 0)) || die "Нет ни одного ключа. Без них вход по паролю закрывать нельзя. Дай --key / --github / --keys-file."
log "Валидных ключей: $N_KEYS. Отпечатки (проверь, что это ТВОИ ключи):"
{ ssh-keygen -l -f "$CLEAN_KEYS" 2>/dev/null || true; } | while IFS= read -r fp; do log "  $fp"; done

# ──────────────────────────── обновление и пакеты ────────────────────────────
step "2/12 Обновление системы"
apt_run update
if ((SKIP_UPGRADE)); then log "full-upgrade пропущен (--no-upgrade)"; else apt_run full-upgrade; fi
if ((AUTOREMOVE)); then apt_run autoremove --purge; else log "autoremove пропущен (включается --autoremove)"; fi

step "3/12 Базовые пакеты"
apt_run install sudo iproute2 openssh-server ufw fail2ban python3-systemd unattended-upgrades ca-certificates curl
# shellcheck disable=SC2086
apt_install wget gnupg git jq unzip zip nano vim tmux htop net-tools dnsutils lsof $EXTRA_PACKAGES

write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

if [[ -f /etc/default/motd-news ]]; then backup_file /etc/default/motd-news; sed -i 's/^ENABLED=1/ENABLED=0/' /etc/default/motd-news; fi
if command -v pro >/dev/null 2>&1; then pro config set apt_news=false >/dev/null 2>&1 || true; fi

# ─────────────────────────── hostname / timezone ─────────────────────────────
step "4/12 Hostname и время"
if [[ -n "$NEW_HOSTNAME" ]]; then
  backup_file /etc/hostname
  if ((HAS_SYSTEMD)); then hostnamectl set-hostname "$NEW_HOSTNAME" || warn "hostnamectl не сработал"; else hostname "$NEW_HOSTNAME"; fi
  printf '%s\n' "$NEW_HOSTNAME" >/etc/hostname
  log "hostname = $NEW_HOSTNAME"
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    write_file /etc/cloud/cloud.cfg.d/99-bootstrap-hostname.cfg 0644 <<'EOF'
preserve_hostname: true
EOF
  fi
fi
HN="$(hostname)"
if ! grep -Eq "(^|[[:space:]])${HN//./\\.}([[:space:]]|$)" /etc/hosts; then
  backup_file /etc/hosts
  echo "127.0.1.1 $HN" >>/etc/hosts; log "добавил $HN в /etc/hosts"
fi
if [[ -n "$TIMEZONE" ]]; then
  if ((HAS_SYSTEMD)); then timedatectl set-timezone "$TIMEZONE" || warn "timedatectl set-timezone не сработал"; else ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime; fi
  log "таймзона = $TIMEZONE"
fi
if ((HAS_SYSTEMD)); then
  timedatectl set-ntp true 2>/dev/null || warn "не удалось включить NTP — проверь время: timedatectl"
fi

# ───────────────────────── пользователь, ключи, sudo ─────────────────────────
step "5/12 Пользователь $NEW_USER"
if id "$NEW_USER" &>/dev/null; then
  log "пользователь $NEW_USER уже есть"; usermod -aG sudo "$NEW_USER"
else
  useradd -m -s /bin/bash -G sudo "$NEW_USER"; log "создан $NEW_USER"
fi
U_HOME="$(getent passwd "$NEW_USER" | cut -d: -f6)"
U_GRP="$(id -gn "$NEW_USER")"
[[ "$U_HOME" == /* && -d "$U_HOME" ]] || die "Домашний каталог $NEW_USER некорректен или не существует: '$U_HOME'"
chmod go-w "$U_HOME"
install -d -m 700 -o "$NEW_USER" -g "$U_GRP" "$U_HOME/.ssh"

AK="$U_HOME/.ssh/authorized_keys"
MERGED="$(mktemp -p "$WORKDIR")"
{ if [[ -f "$AK" ]]; then cat "$AK"; fi; cat "$CLEAN_KEYS"; } | awk '!seen[$0]++' >"$MERGED"
install -m 600 -o "$NEW_USER" -g "$U_GRP" "$MERGED" "$AK"
rm -f "$MERGED" "$KEYS_TMP" "$CLEAN_KEYS"
log "authorized_keys: $(grep -c . "$AK") ключ(ей)"

# v1.2: проверяем, что владелец/права/родители не отобьют StrictModes
chown "$NEW_USER:$U_GRP" "$U_HOME" "$U_HOME/.ssh" "$AK"
chmod 700 "$U_HOME/.ssh"; chmod 600 "$AK"

SUDOERS_FILE="/etc/sudoers.d/90-bootstrap-$NEW_USER"
SUDOERS_TMP="$(mktemp -p "$WORKDIR")"
printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$NEW_USER" >"$SUDOERS_TMP"
visudo -cf "$SUDOERS_TMP" >/dev/null || die "sudoers-правило не прошло visudo -c"
install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"; rm -f "$SUDOERS_TMP"
if ! grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; then
  warn "в /etc/sudoers нет includedir — добавляю"; backup_file /etc/sudoers
  printf '@includedir /etc/sudoers.d\n' >>/etc/sudoers
fi
# v1.2: если валидация всего дерева падает — ругаемся адресно, но правило НЕ удаляем молча при рабочем файле
if ! visudo -c >/dev/null; then
  warn "visudo -c ругается на итоговую конфигурацию (возможно, чужой файл в /etc/sudoers.d):"
  visudo -c || true
  visudo -cf "$SUDOERS_FILE" >/dev/null || { rm -f "$SUDOERS_FILE"; die "наше правило невалидно — удалил"; }
fi
log "sudo NOPASSWD для $NEW_USER настроен"

# v1.2: root не режем молча. --lock-root отключает пароль root (в т.ч. VNC-консоль).
if ((LOCK_ROOT)); then
  passwd -l root >/dev/null 2>&1 || warn "passwd -l root не удался"
  log "пароль root заблокирован (вход только по ключу; VNC-консоль по паролю работать не будет)"
else
  log "пароль root оставлен (--lock-root, чтобы заблокировать)"
fi

if ((SET_UMASK)) && ! grep -q '^umask 0077' "$U_HOME/.bashrc" 2>/dev/null; then
  echo 'umask 0077' >>"$U_HOME/.bashrc"; chown "$NEW_USER:$U_GRP" "$U_HOME/.bashrc"; log "umask 0077 добавлен"
fi

# ───────────────────────────────── firewall ──────────────────────────────────
step "6/12 UFW"
mapfile -t OLD_SSH_PORTS < <(detect_ssh_ports)
((${#OLD_SSH_PORTS[@]})) || OLD_SSH_PORTS=("${SSH_CONNECTION##* }")

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
NEW_UFW_PORTS+=("$SSH_PORT")
for p in "${OLD_SSH_PORTS[@]}"; do
  if [[ "$p" != "$SSH_PORT" ]]; then
    ufw allow "${p}/tcp" comment 'SSH-transition' >/dev/null
    log "ufw allow ${p}/tcp (прежний порт SSH; закрыть после проверки)"
  fi
done
for p in "${OPEN_ARR[@]}"; do ufw allow "$p" comment 'bootstrap' >/dev/null; log "ufw allow $p"; done

# v1.2: ping-правило идемпотентно в обе стороны
if [[ -f /etc/ufw/before.rules ]]; then
  PING_WANT=ACCEPT; ((BLOCK_PING)) && PING_WANT=DROP
  if ! grep -qE '^# bootstrap.*ping' /etc/ufw/before.rules; then
    backup_file /etc/ufw/before.rules
    sed -i -E "s|^(-A ufw-before-input -p icmp --icmp-type echo-request) -j (ACCEPT|DROP)|\1 -j $PING_WANT|" /etc/ufw/before.rules
    sed -i "1i # bootstrap: block-ping=$BLOCK_PING" /etc/ufw/before.rules
  fi
  sed -i -E "0,/^# bootstrap.*ping/{s/^# bootstrap.*ping/# bootstrap: block-ping=$BLOCK_PING/}" /etc/ufw/before.rules
  sed -i -E "s|^(-A ufw-before-input -p icmp --icmp-type echo-request) -j (ACCEPT|DROP)|\1 -j $PING_WANT|" /etc/ufw/before.rules
  log "ping (IPv4 echo-request) = $([[ $PING_WANT == DROP ]] && echo закрыт || echo открыт); остальной ICMP не трогаю"
fi

if ufw --force enable >/dev/null 2>&1; then log "ufw включён"
else warn "ufw не включился (нет netfilter в ядре/контейнере?) — проверь вручную!"; fi
ufw reload >/dev/null 2>&1 || true

# ───────────────────────────────── fail2ban ──────────────────────────────────
step "7/12 fail2ban"
IGNORE="127.0.0.1/8 ::1"
CLIENT_IP="${SSH_CONNECTION:-${SSH_CLIENT:-}}"; CLIENT_IP="${CLIENT_IP%% *}"
if [[ "${CLIENT_IP:-}" =~ ^[0-9a-fA-F:.]+$ ]]; then IGNORE="$IGNORE $CLIENT_IP"; fi

# v1.2: следим и за прежними портами, пока они открыты
F2B_PORTS="$SSH_PORT"
for p in "${OLD_SSH_PORTS[@]}"; do [[ "$p" == "$SSH_PORT" ]] || F2B_PORTS+=",$p"; done

# v1.2: не перебиваем пользовательский jail.local — отдельный файл с более высоким приоритетом
write_file /etc/fail2ban/jail.d/20-bootstrap.local 0644 <<EOF
# Managed by bootstrap.sh. Файл 20-* намеренно выше jail.local, чтобы переходный
# период по старому порту SSH тоже был под защитой.
[DEFAULT]
ignoreip = $IGNORE
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w

[sshd]
enabled = true
backend = systemd
port = $F2B_PORTS
maxretry = 5
findtime = 10m
bantime = 1h
EOF
fail2ban-client -t >/dev/null 2>&1 || { fail2ban-client -t || true; die "конфиг fail2ban невалиден"; }
svc enable fail2ban >/dev/null 2>&1 || true
svc restart fail2ban || true
if ((HAS_SYSTEMD)); then
  sleep 3
  if systemctl is-active --quiet fail2ban && fail2ban-client ping >/dev/null 2>&1; then log "fail2ban работает (порты: $F2B_PORTS)"
  else warn "fail2ban НЕ запустился — journalctl -u fail2ban -n 30. (Ubuntu 24.04: базовый fail2ban 1.0.2-3 требует pocket noble-updates, иначе 'No module named asynchat')"; fi
fi

# ─────────────────────── sysctl: BBR и сетевая оптимизация ───────────────────
step "8/12 sysctl (BBR + сеть)"
BBR_LINES=""
if [[ -z "$VIRT" ]]; then
  modprobe tcp_bbr 2>/dev/null || true
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    BBR_LINES=$'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr'
    echo tcp_bbr | write_file /etc/modules-load.d/bbr.conf 0644
  else
    warn "BBR недоступен в этом ядре — оставляю дефолтный congestion control"
  fi
fi
RESERVED_LINE=""
if ((SSH_PORT >= 32768 && SSH_PORT <= 60999)); then
  CUR_RES="$(sysctl -n net.ipv4.ip_local_reserved_ports 2>/dev/null || true)"; NEW_RES="$SSH_PORT"
  if [[ -n "$CUR_RES" ]]; then
    case ",$CUR_RES," in *",$SSH_PORT,"*) NEW_RES="$CUR_RES" ;; *) NEW_RES="$CUR_RES,$SSH_PORT" ;; esac
  fi
  RESERVED_LINE="net.ipv4.ip_local_reserved_ports = $NEW_RES"
fi
write_file /etc/sysctl.d/99-bootstrap.conf 0644 <<EOF
# Managed by bootstrap.sh. Консервативный набор.
$BBR_LINES
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.somaxconn = 4096
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
vm.swappiness = 10
kernel.panic = 10
$RESERVED_LINE
EOF
sysctl -q -p /etc/sysctl.d/99-bootstrap.conf || warn "часть sysctl не применилась (контейнер/старое ядро) — не критично"

# ───────────────────────── лимиты, журналы, ротация ──────────────────────────
step "9/12 Лимиты, journald, logrotate"
write_file /etc/security/limits.d/99-bootstrap.conf 0644 <<'EOF'
*    soft nofile 65536
*    hard nofile 1048576
root soft nofile 65536
root hard nofile 1048576
EOF
write_file /etc/systemd/system.conf.d/99-bootstrap.conf 0644 <<'EOF'
[Manager]
DefaultLimitNOFILE=1024:1048576
EOF
if ((WRITE_CHANGED)); then svc daemon-reexec 2>/dev/null || true; fi

write_file /etc/systemd/journald.conf.d/99-bootstrap.conf 0644 <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
EOF
if ((WRITE_CHANGED)); then svc restart systemd-journald || true; fi

write_file /etc/logrotate.d/bootstrap 0644 <<'EOF'
/var/log/bootstrap.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
    create 0600 root root
}
EOF

# ────────────────────────────────── swap ─────────────────────────────────────
step "10/12 Swap"
if [[ "$SWAP_SIZE" == 0 ]]; then log "swap отключён флагом"
elif [[ -n "$VIRT" ]]; then log "контейнер — swap пропускаю"
elif [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then log "swap уже есть — не трогаю"
elif [[ -e /swapfile ]]; then warn "/swapfile существует, но не подключён — не трогаю"
else
  MB="${SWAP_SIZE%[MG]}"
  if [[ "$SWAP_SIZE" == *G ]]; then MB=$((MB*1024)); fi
  FREE_MB="$(df -Pk / | awk 'NR==2{print int($4/1024)}')"
  if ((FREE_MB < MB + 2048)); then warn "мало места на диске (${FREE_MB}M) — swap пропускаю"
  else
    SWAP_TMP=/swapfile.bootstrap
    rm -f "$SWAP_TMP"
    if ( umask 077; fallocate -l "${MB}M" "$SWAP_TMP" 2>/dev/null || dd if=/dev/zero of="$SWAP_TMP" bs=1M count="$MB" status=none ) \
       && chmod 600 "$SWAP_TMP" && mkswap "$SWAP_TMP" >/dev/null && mv "$SWAP_TMP" /swapfile; then
      if swapon /swapfile 2>/dev/null; then
        if ! grep -q '^/swapfile ' /etc/fstab; then backup_file /etc/fstab; echo '/swapfile none swap sw 0 0' >>/etc/fstab; fi
        log "swap ${SWAP_SIZE} создан"
      else warn "swapon не удался (ФС не поддерживает?) — удаляю файл"; rm -f /swapfile; fi
    else
      rm -f "$SWAP_TMP"; warn "не удалось создать swap-файл (место/ФС) — пропускаю"
    fi
  fi
fi

# ─────────────────────────────── docker (опция) ──────────────────────────────
step "11/12 Docker"
if ((INSTALL_DOCKER)); then
  DOCKER_WAS_ACTIVE=0; DOCKER_CFG_CHANGED=0
  if ((HAS_SYSTEMD)) && systemctl is-active --quiet docker 2>/dev/null; then DOCKER_WAS_ACTIVE=1; fi
  if [[ ! -f /etc/docker/daemon.json ]]; then
    write_file /etc/docker/daemon.json 0644 <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
    DOCKER_CFG_CHANGED=$WRITE_CHANGED
  fi
  apt_run install docker.io
  apt_install docker-compose-v2
  usermod -aG docker "$NEW_USER" || warn "не удалось добавить $NEW_USER в группу docker"
  svc enable --now docker || warn "docker не стартовал"
  if ((DOCKER_CFG_CHANGED && DOCKER_WAS_ACTIVE)); then warn "docker уже работал — перезапускаю, чтобы применить daemon.json"; svc restart docker || true; fi

  # v1.2: docker публикует порты в обход ufw (цепочка DOCKER-USER обрабатывается раньше ufw-user-forward)
  if ((DOCKER_UFW)) && [[ -f /etc/ufw/after.rules ]] && ! grep -q 'BEGIN UFW AND DOCKER' /etc/ufw/after.rules; then
    backup_file /etc/ufw/after.rules
    BLOCK="$(mktemp -p "$WORKDIR")"
    cat >"$BLOCK" <<'EOF'
# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16
-A DOCKER-USER -p udp -m udp --sport 53 --dport 1024:65535 -j RETURN
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -j DROP
COMMIT
# END UFW AND DOCKER
EOF
    awk -v blk="$(cat "$BLOCK")" '/^COMMIT[[:space:]]*$/ && !done {print blk; done=1} {print}' \
      /etc/ufw/after.rules >"$BLOCK.new" && install -m 640 -o root -g root "$BLOCK.new" /etc/ufw/after.rules
    rm -f "$BLOCK" "$BLOCK.new"
    ufw reload >/dev/null 2>&1 || true
    log "docker-порты больше не обходят ufw: разрешай их через 'ufw route allow ...'"
  elif ((DOCKER_UFW)); then
    log "правило DOCKER-USER уже есть — не трогаю"
  else
    warn "Docker обходит ufw для опубликованных портов (-p 8080:80 открыт всем!). Биндись на 127.0.0.1, правь DOCKER-USER или запусти с --docker-ufw"
  fi
else log "пропущено (включается флагом --docker)"; fi

# ───────────────────────── SSH hardening — в самом конце ─────────────────────
step "12/12 Харденинг SSH"
mkdir -p /run/sshd /etc/ssh/sshd_config.d
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
  warn "в sshd_config нет Include sshd_config.d — добавляю в начало"
  backup_file /etc/ssh/sshd_config
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi

if [[ -f "$SSHD_DROPIN" ]]; then cp -a "$SSHD_DROPIN" "$SSHD_PREV"; SSHD_HAD=1; fi
if [[ -f "$SOCK_DROPIN" ]]; then cp -a "$SOCK_DROPIN" "$SOCK_PREV"; SOCK_HAD=1; fi
SSH_TXN=1

PORT_LINE=""; if ((SSH_PORT != 22)); then PORT_LINE="Port $SSH_PORT"; fi
cat >"$SSHD_DROPIN" <<EOF
# Managed by bootstrap.sh v$SCRIPT_VERSION
$PORT_LINE
PermitRootLogin $ROOT_LOGIN_MODE
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers $ALLOW_USERS
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 10:30:60
ClientAliveInterval 300
ClientAliveCountMax 3
LogLevel VERBOSE
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding local
GatewayPorts no
PermitTunnel no
EOF
chmod 644 "$SSHD_DROPIN"

sshd -t || die "sshd -t не прошёл, конфиг откатывается"
EFF="$(sshd -T 2>/dev/null)"
for want in "passwordauthentication no" "kbdinteractiveauthentication no" "permitrootlogin $ROOT_LOGIN_MODE" \
            "pubkeyauthentication yes" "authenticationmethods publickey" "port $SSH_PORT"; do
  grep -qxF "$want" <<<"$EFF" || die "Эффективный конфиг sshd не содержит '$want' (перебито другим файлом?) — откат"
done
# v1.2: сверяем AllowUsers как множество, а не как одну строку с NEW_USER
EXPECT_ALLOW="allowusers $ALLOW_USERS"
grep -qxF "$EXPECT_ALLOW" <<<"$EFF" || die "AllowUsers в эффективном конфиге не равен ожидаемому ('$EXPECT_ALLOW') — откат"
N_ALLOW="$(grep -c '^allowusers ' <<<"$EFF" || true)"
((N_ALLOW == 1)) || die "В эффективном конфиге sshd $N_ALLOW строк AllowUsers (другой drop-in расширяет список) — откат"
[[ -s "$AK" ]] || die "authorized_keys пуст — не закрываю вход по паролю"
log "sshd -t ок, эффективный конфиг проверен (AllowUsers: $ALLOW_USERS, PermitRootLogin: $ROOT_LOGIN_MODE)"

SSH_CUT=1
if ((HAS_SYSTEMD && SOCKET_MODE)); then
  if ((SSH_PORT != 22)); then
    mkdir -p "$(dirname "$SOCK_DROPIN")"
    printf '[Socket]\nListenStream=\nListenStream=%s\n' "$SSH_PORT" >"$SOCK_DROPIN"
  else
    rm -f "$SOCK_DROPIN"
  fi
fi
restart_ssh || die "не удалось перезапустить ssh — конфиг откатывается"

if ((HAS_SYSTEMD)); then
  LISTEN_OK=0
  for _ in $(seq 1 15); do
    if ss -H -ltn "sport = :$SSH_PORT" 2>/dev/null | grep -q .; then LISTEN_OK=1; break; fi
    sleep 1
  done
  ((LISTEN_OK)) || die "sshd не слушает порт $SSH_PORT за 15 секунд — откат, проверь вручную"
  log "sshd слушает порт $SSH_PORT"
fi
SSH_TXN=0

# ──────────────────────── self-verification (v1.2) ───────────────────────────
step "Проверки после установки"
VERIFY_FAIL=0
vok()  { log  "OK   $*"; }
vbad() { warn "FAIL $*"; VERIFY_FAIL=1; }

ss -H -ltn "sport = :$SSH_PORT" 2>/dev/null | grep -q . \
  && vok "sshd слушает порт $SSH_PORT" || vbad "sshd не слушает порт $SSH_PORT"
sshd -T 2>/dev/null | grep -qxF "allowusers $ALLOW_USERS" \
  && vok "AllowUsers = $ALLOW_USERS" || vbad "AllowUsers не совпадает"
sshd -T 2>/dev/null | grep -qxF "passwordauthentication no" \
  && vok "вход по паролю выключен" || vbad "вход по паролю включён"
sshd -T 2>/dev/null | grep -qxF "permitrootlogin $ROOT_LOGIN_MODE" \
  && vok "PermitRootLogin = $ROOT_LOGIN_MODE" || vbad "PermitRootLogin не совпадает"
[[ -s "$AK" ]] && vok "authorized_keys не пуст ($(grep -c . "$AK") ключ(ей))" || vbad "authorized_keys пуст"
[[ "$(stat -c '%U %a' "$AK")" == "$NEW_USER 600" ]] \
  && vok "права authorized_keys корректны" || vbad "права authorized_keys: $(stat -c '%U %a' "$AK")"
runuser -u "$NEW_USER" -- sudo -n true 2>/dev/null \
  && vok "sudo NOPASSWD для $NEW_USER работает" || vbad "sudo -n для $NEW_USER не работает"
ufw status 2>/dev/null | head -1 | grep -q 'Status: active' \
  && vok "ufw активен" || vbad "ufw не активен"
if ((HAS_SYSTEMD)); then
  systemctl is-active --quiet fail2ban && vok "fail2ban активен" || vbad "fail2ban не активен"
fi
ufw status 2>/dev/null | grep -qE "^${SSH_PORT}/tcp" \
  && vok "ufw пропускает новый порт $SSH_PORT" || vbad "в ufw нет правила для $SSH_PORT"
if [[ "$SWAP_SIZE" != 0 && -z "$VIRT" ]]; then
  [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]] && vok "swap активен" || vbad "swap не активен"
fi

# ───────────────────────────────────── итог ──────────────────────────────────
printf '\n%s ════════════════ ГОТОВО ════════════════\n' "$(ts)"
IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
echo "SSH:       ssh -p $SSH_PORT $NEW_USER@${IP:-<ip>}"
echo "sshd:      $(sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|allowusers) ' | tr '\n' ';' || true)"
echo "BBR:       $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo ?)"
echo "swap:      $(swapon --show --noheadings 2>/dev/null | awk '{print $1" "$3}' | tr '\n' ' ' || true)"
echo "ufw:       $(ufw status 2>/dev/null | head -1 || true)"
if ((HAS_SYSTEMD)) && command -v fail2ban-client >/dev/null; then
  echo "fail2ban:  $(systemctl is-active fail2ban 2>/dev/null || true) ($(fail2ban-client status 2>/dev/null | grep -i 'jail list' | sed 's/.*://;s/\s//g' || true))"
fi
((KEEP_ROOT)) && echo "root:      вход по ключу разрешён, пароль $([[ $LOCK_ROOT == 1 ]] && echo 'заблокирован (VNC по паролю не войдёт)' || echo 'оставлен')"

warn "НЕ закрывай эту сессию, пока в НОВОМ окне не проверишь: ssh -p $SSH_PORT $NEW_USER@${IP:-<ip>} && sudo -n true"
warn "Проверь, что порт $SSH_PORT открыт в security group / cloud firewall провайдера — ufw этого не видит."
for p in "${OLD_SSH_PORTS[@]}"; do
  if [[ "$p" != "$SSH_PORT" ]]; then
    warn "Только после успешной внешней проверки закрой прежний порт: sudo ufw delete allow ${p}/tcp"
  fi
done
if [[ -f /var/run/reboot-required ]]; then warn "Нужна перезагрузка (новое ядро/библиотеки): sudo reboot"; fi
if ((VERIFY_FAIL)); then warn "Часть self-verification провалена — смотри FAIL выше и лог $LOG"; fi
if ((DO_REBOOT)); then
  warn "Перезагрузка через 1 минуту (--reboot). Отмена: shutdown -c"
  shutdown -r +1 "bootstrap.sh: плановая перезагрузка" || warn "shutdown не удался — перезагрузи вручную"
fi
cy=$((VERIFY_FAIL != 0))
exit $cy
