#!/usr/bin/env bash
# =============================================================================
#  bootstrap.sh — воспроизводимая база для Ubuntu 24.04 / 26.04
#  v2.0.0 · MIT · https://github.com/Frog2233-DevOps/Linux-optimise
#
#  Режимы:
#    apply   (по умолчанию) привести машину к целевому состоянию
#    check   провалидировать окружение и напечатать план, ничего не менять
#    verify  сверить живую машину с сохранённым состоянием; != 0 при дрейфе
#
#  Коды возврата: 0 ok · 1 сбой применения · 2 ошибка аргументов ·
#                 3 дрейф/провал verify · 4 провал префлайта
#
#  Запуск (одна команда, скрипт сам спросит ключ):
#    bash <(curl -fsSL --proto '=https' --proto-redir '=https' \
#      https://raw.githubusercontent.com/Frog2233-DevOps/Linux-optimise/<SHA>/bootstrap.sh)
#
#  Без вопросов: ... | bash -s -- --yes --key "ssh-ed25519 AAAA... me"
#  Повторный запуск идемпотентен. Состояние: /var/lib/bootstrap/state.env
#  Лог: /var/log/bootstrap.log (0600, append-only). Бэкапы: /var/backups/bootstrap/
# =============================================================================
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

readonly SCRIPT_VERSION="2.0.0"
readonly STATE_DIR="/var/lib/bootstrap"
readonly STATE_FILE="$STATE_DIR/state.env"
readonly LOG="${LOG:-/var/log/bootstrap.log}"
readonly LOCK="${LOCK:-/run/bootstrap.lock}"
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/00-bootstrap.conf"
readonly SOCK_DROPIN="/etc/systemd/system/ssh.socket.d/zz-bootstrap-port.conf"

MODE="apply"
NEW_USER="${NEW_USER:-super}"
SSH_PORT="${SSH_PORT:-49500}"
SSH_KEYS="${SSH_KEYS:-}"
KEYS_FILE="${KEYS_FILE:-}"
GITHUB_USER="${GITHUB_USER:-}"
OPEN_PORTS="${OPEN_PORTS-}"
SSH_ALLOW_FROM="${SSH_ALLOW_FROM:-}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
TIMEZONE="${TIMEZONE:-}"
NEW_HOSTNAME="${NEW_HOSTNAME:-}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
INSTALL_DOCKER="${INSTALL_DOCKER:-0}"
DOCKER_UFW="${DOCKER_UFW:-0}"
BLOCK_PING="${BLOCK_PING:-0}"
SET_UMASK="${SET_UMASK:-1}"
AUTOREMOVE="${AUTOREMOVE:-0}"
UPGRADE="${UPGRADE:-safe}" # safe | full | none
AGENT_FORWARDING="${AGENT_FORWARDING:-0}"
NET_TUNING="${NET_TUNING:-1}"
HARDENING_SYSCTL="${HARDENING_SYSCTL:-1}"
INSTALL_AUDITD="${INSTALL_AUDITD:-0}"
KEEP_ROOT="${KEEP_ROOT:-1}"
LOCK_ROOT="${LOCK_ROOT:-0}"
ALLOW_USERS="${ALLOW_USERS:-}"
DO_REBOOT="${DO_REBOOT:-0}"
CLOSE_OLD_PORTS="${CLOSE_OLD_PORTS:-0}"
CLOUD_INIT_CFG="${CLOUD_INIT_CFG:-1}"
UNATTENDED_REBOOT="${UNATTENDED_REBOOT:-}"
FORCE="${FORCE:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
JSON="${JSON:-0}"
SHA_EXPECT="${SHA_EXPECT:-}"
CONFIG_FILE="${CONFIG_FILE:-}"

KEY_ARGS=()
OPEN_ARR=()
OLD_SSH_PORTS=()
NEW_UFW_PORTS=()
HAS_SYSTEMD=0
[[ -d /run/systemd/system ]] && HAS_SYSTEMD=1
SOCKET_MODE=0
VIRT=""
BACKUP_DIR=""
SCRIPT_SHA="n/a"
PROG="${0##*/}"
SSH_TXN=0
SSH_CUT=0
SSHD_HAD=0
SOCK_HAD=0
RUNDIR=""
pass_count=0
fail_count=0
json_items=()
WRITE_CHANGED=0

# ──────────────────────────────── вывод ─────────────────────────────────────
ts() { date -u '+%F %T'; }
_esc() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}
_emit() {
  local lvl=$1
  shift
  printf '%s [%s] %s\n' "$(ts)" "$lvl" "$*" >&8
  printf '%s [%s] %s\n' "$(ts)" "$lvl" "$*" >&2
}
log() { _emit '+' "$@"; }
warn() { _emit '!' "$@"; }
ok() { _emit 'OK' "$@"; }
fail() {
  fail_count=$((fail_count + 1))
  _emit 'FAIL' "$@"
  json_items+=("{\"id\":\"$(_esc "$1")\",\"ok\":false}")
}
pass() {
  pass_count=$((pass_count + 1))
  _emit 'OK' "$@"
  json_items+=("{\"id\":\"$(_esc "$1")\",\"ok\":true}")
}
die() {
  _emit 'x' "$@"
  exit "${2:-1}"
}
step() {
  printf '\n%s ══ %s\n' "$(ts)" "$*" >&8
  printf '\n%s ══ %s\n' "$(ts)" "$*" >&2
}

usage() {
  cat <<EOF
bootstrap.sh v$SCRIPT_VERSION — база для Ubuntu 24.04 / 26.04 (только root)

Режимы:
  apply            применить (по умолчанию)
  check            проверить окружение и напечатать план
  verify           сверить машину с состоянием; код 3 при расхождении

Ключи:
  -k, --key "ssh-ed25519 AAAA..."   публичный ключ (можно повторять)
      --keys-file FILE              файл с ключами
      --github USER                 https://github.com/USER.keys
      --config FILE                 файл KEY=VALUE (читается до флагов)

Основное:
  -u, --user NAME        имя пользователя (super)
  -p, --ssh-port N       порт SSH (49500)
      --allow-users "L"  кому разрешён вход (по умолчанию: новый юзер + все human-аккаунты + root при --keep-root)
      --ssh-allow-from C ограничить SSH по источнику (CIDR, можно повторять)
      --ports "LIST"     что ещё открыть в ufw ("80/tcp 443/tcp 6000:6010/udp")
      --swap SIZE        512M, 2G, 0 = выключить (2G)
      --timezone TZ      Europe/Moscow
      --hostname NAME    сменить hostname
      --packages "LIST"  доп. пакеты apt

Политика root:
      --keep-root        PermitRootLogin prohibit-password (по умолчанию)
      --no-root          PermitRootLogin no
      --lock-root        passwd -l root (пароль в VNC-консоли перестанет работать)

Опции:
      --docker           docker.io + compose-v2
      --docker-ufw       правила DOCKER-USER (docker не обходит ufw)
      --block-ping       не отвечать на ICMP echo-request (только IPv4)
      --agent-forwarding разрешить SSH agent forwarding
      --no-net-tuning    не трогать congestion control / буферы
      --no-hardening-sysctl  не применять dmesg_restrict/rp_filter и т.п.
      --auditd           поставить auditd с минимальными правилами
      --no-umask         не ставить umask 0077 пользователю
      --no-cloud-init    не писать cloud-init конфиг (ssh_pwauth)
      --autoremove       apt autoremove --purge
      --upgrade MODE     safe | full | none (safe)
      --close-old-ports  закрыть переходные правила ufw после успешной проверки
      --auto-reboot HH:MM  время автоперезагрузки unattended-upgrades
      --reboot           перезагрузиться через 1 минуту
      --yes              без подтверждения и вопросов
      --json             машиночитаемый отчёт verify в stdout
      --force            игнорировать неподдерживаемый релиз / системного юзера
      --sha256 HEX       сверить sha256 скрипта
  -h, --help
EOF
}

# ─────────────────────────── утилиты и файлы ────────────────────────────────
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "нет обязательной команды: $1 (код 4)" 4; }
os_field() { (
  . /etc/os-release
  printf '%s' "${!1:-}"
); }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
in_array() {
  local x=$1 e
  shift
  for e in "$@"; do [[ "$e" == "$x" ]] && return 0; done
  return 1
}

svc() {
  if ((HAS_SYSTEMD)); then
    systemctl "$@"
  else warn "systemd не запущен — пропуск: systemctl $*"; fi
}

backup_file() {
  local f=$1
  [[ -e "$f" ]] || return 0
  install -d -m 700 "$BACKUP_DIR"
  cp -a "$f" "$BACKUP_DIR/$(printf '%s' "${f#/}" | tr / _)"
}

write_file() {
  local path=$1 mode=$2 tmp
  WRITE_CHANGED=0
  tmp="$(mktemp -p "$RUNDIR")"
  cat >"$tmp"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    return 0
  fi
  backup_file "$path"
  install -m "$mode" -o root -g root "$tmp" "$path"
  rm -f "$tmp"
  WRITE_CHANGED=1
  log "записал $path"
}

apt_run() { apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
  -o DPkg::Lock::Timeout=600 -o Acquire::Retries=3 "$@" </dev/null; }

apt_install() {
  local okp=() p
  for p in "$@"; do
    [[ -z "$p" || "$p" == -* ]] && continue
    if apt-cache show --no-all-versions "$p" >/dev/null 2>&1; then okp+=("$p"); else warn "пакета $p нет — пропуск"; fi
  done
  ((${#okp[@]})) && apt_run install --no-install-recommends "${okp[@]}"
  return 0
}

collect_human_users() {
  awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd | sort -u
}

detect_ssh_ports() {
  local c=${SSH_CONNECTION:-}
  mkdir -p /run/sshd
  {
    command -v sshd >/dev/null 2>&1 && sshd -T 2>/dev/null | awk '$1=="port"{print $2}'
    if ((HAS_SYSTEMD)); then
      systemctl show ssh.socket -p Listen --value 2>/dev/null | grep -oE ':[0-9]+ \(Stream\)' | tr -dc '0-9\n'
    fi
    [[ -n "$c" ]] && printf '%s\n' "${c##* }"
  } | grep -E '^[0-9]+$' | sort -un || true
}

restart_ssh() {
  ((HAS_SYSTEMD)) || {
    warn "systemd нет — ssh не перезапускаю"
    return 0
  }
  systemctl daemon-reload || return 1
  if ((SOCKET_MODE)); then
    systemctl restart ssh.socket || return 1
    if systemctl is-active --quiet ssh.service; then
      systemctl reload-or-restart ssh.service || return 1
    fi
  else
    systemctl reload-or-restart ssh || systemctl restart ssh || return 1
  fi
  return 0
}

# sshd -T печатает AllowUsers по одному пользователю на строку
sshd_allowusers() {
  sshd -T 2>/dev/null | awk '$1=="allowusers"{print $2}' | sort | paste -sd' ' -
}
expected_allowusers() {
  tr ' ' '\n' <<<"$ALLOW_USERS" | sort | paste -sd' ' -
}

rollback_ssh() {
  ((SSH_TXN)) || return 0
  SSH_TXN=0
  warn "откат SSH-конфига и правил ufw из транзакции"
  if ((SSHD_HAD)); then cp -a "$RUNDIR/sshd.prev" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
  if ((SOCK_HAD)); then cp -a "$RUNDIR/sock.prev" "$SOCK_DROPIN"; else rm -f "$SOCK_DROPIN"; fi
  local p
  for p in "${NEW_UFW_PORTS[@]}"; do ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true; done
  ufw reload >/dev/null 2>&1 || true
  ((SSH_CUT)) && { restart_ssh || warn "ssh не поднялся после отката; открыты порты: ${OLD_SSH_PORTS[*]:-22}"; }
}

on_exit() {
  local rc=$?
  trap - ERR
  rollback_ssh || true
  [[ -n "$RUNDIR" && -d "$RUNDIR" ]] && rm -rf "$RUNDIR"
  exit "$rc"
}

# ─────────────────────────────── парсинг ────────────────────────────────────
split_flag() { printf '%s' "${1%%=*}"; }

pre_scan_config() {
  local a
  for a in "$@"; do
    case "$a" in
      --config=*) CONFIG_FILE="${a#*=}" ;;
    esac
  done
  local prev=""
  for a in "$@"; do
    [[ "$prev" == "--config" ]] && CONFIG_FILE="$a"
    prev="$a"
  done
  if [[ -n "$CONFIG_FILE" ]]; then
    [[ -r "$CONFIG_FILE" ]] || die "нет файла конфигурации: $CONFIG_FILE (код 2)" 2
    # shellcheck disable=SC1090
    (
      set -a
      . "$CONFIG_FILE"
      set +a
    )
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    log "конфиг: $CONFIG_FILE"
  fi
}

parse_args() {
  while (($#)); do
    case "$1" in
      apply | check | verify)
        MODE="$1"
        shift
        ;;
      --apply)
        MODE=apply
        shift
        ;;
      -k | --key)
        KEY_ARGS+=("${2:?}")
        shift 2
        ;;
      --keys-file)
        KEYS_FILE="$2"
        shift 2
        ;;
      --github)
        GITHUB_USER="$2"
        shift 2
        ;;
      -u | --user)
        NEW_USER="$2"
        shift 2
        ;;
      -p | --ssh-port)
        SSH_PORT="$2"
        shift 2
        ;;
      --allow-users)
        ALLOW_USERS="$2"
        shift 2
        ;;
      --ssh-allow-from)
        SSH_ALLOW_FROM+=" $2"
        shift 2
        ;;
      --ports)
        OPEN_PORTS="$2"
        shift 2
        ;;
      --swap)
        SWAP_SIZE="$2"
        shift 2
        ;;
      --timezone)
        TIMEZONE="$2"
        shift 2
        ;;
      --hostname)
        NEW_HOSTNAME="$2"
        shift 2
        ;;
      --packages)
        EXTRA_PACKAGES="$2"
        shift 2
        ;;
      --upgrade)
        UPGRADE="$2"
        shift 2
        ;;
      --auto-reboot)
        UNATTENDED_REBOOT="$2"
        shift 2
        ;;
      --keep-root)
        KEEP_ROOT=1
        shift
        ;;
      --no-root)
        KEEP_ROOT=0
        shift
        ;;
      --lock-root)
        LOCK_ROOT=1
        shift
        ;;
      --docker)
        INSTALL_DOCKER=1
        shift
        ;;
      --docker-ufw)
        INSTALL_DOCKER=1
        DOCKER_UFW=1
        shift
        ;;
      --block-ping)
        BLOCK_PING=1
        shift
        ;;
      --agent-forwarding)
        AGENT_FORWARDING=1
        shift
        ;;
      --no-net-tuning)
        NET_TUNING=0
        shift
        ;;
      --no-hardening-sysctl)
        HARDENING_SYSCTL=0
        shift
        ;;
      --auditd)
        INSTALL_AUDITD=1
        shift
        ;;
      --no-umask)
        SET_UMASK=0
        shift
        ;;
      --no-cloud-init)
        CLOUD_INIT_CFG=0
        shift
        ;;
      --autoremove)
        AUTOREMOVE=1
        shift
        ;;
      --close-old-ports)
        CLOSE_OLD_PORTS=1
        shift
        ;;
      --reboot)
        DO_REBOOT=1
        shift
        ;;
      --yes | -y)
        ASSUME_YES=1
        shift
        ;;
      --json)
        JSON=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --sha256)
        SHA_EXPECT="$2"
        shift 2
        ;;
      --config) shift 2 ;;
      --config=*) shift ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        printf 'Неизвестный аргумент: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

# ──────────────────────────── валидация ─────────────────────────────────────
validate_ports() {
  local p a b
  for p in $OPEN_PORTS; do
    if [[ "$p" =~ ^([0-9]{1,5})(/(tcp|udp))?$ ]]; then
      valid_port "${BASH_REMATCH[1]}" || die "--ports: плохой порт $p (код 2)" 2
    elif [[ "$p" =~ ^([0-9]{1,5}):([0-9]{1,5})/(tcp|udp)$ ]]; then
      a=${BASH_REMATCH[1]}
      b=${BASH_REMATCH[2]}
      valid_port "$a" && valid_port "$b" && ((10#$a <= 10#$b)) || die "--ports: плохой диапазон $p (код 2)" 2
    else
      die "--ports: '$p' не порт (диапазон только с /tcp|/udp) (код 2)" 2
    fi
  done
}

validate_all() {
  [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "плохое имя пользователя: $NEW_USER (код 2)" 2
  [[ "$NEW_USER" != root ]] || die "имя пользователя не может быть root (код 2)" 2
  valid_port "$SSH_PORT" || die "плохой SSH-порт: $SSH_PORT (код 2)" 2
  SSH_PORT=$((10#$SSH_PORT))
  [[ "$SWAP_SIZE" =~ ^(0|[1-9][0-9]*[MG])$ ]] || die "SWAP_SIZE: 0, 512M, 2G (код 2)" 2
  [[ "$UPGRADE" =~ ^(safe|full|none)$ ]] || die "--upgrade: safe|full|none (код 2)" 2
  validate_ports
  [[ -z "$TIMEZONE" || -e "/usr/share/zoneinfo/$TIMEZONE" ]] || die "нет таймзоны $TIMEZONE (код 2)" 2
  if [[ -n "$NEW_HOSTNAME" ]] && ! [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,60}[a-zA-Z0-9])?$ ]]; then
    die "плохой hostname: $NEW_HOSTNAME (код 2)" 2
  fi
  [[ -z "$UNATTENDED_REBOOT" || "$UNATTENDED_REBOOT" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || die "--auto-reboot HH:MM (код 2)" 2
  [[ ! "$EXTRA_PACKAGES" =~ (^|[[:space:]])- ]] || die "--packages не поддерживает опции apt (код 2)" 2
  local c
  for c in $SSH_ALLOW_FROM; do
    [[ "$c" =~ ^[0-9a-fA-F:./]+$ ]] || die "плохой CIDR в --ssh-allow-from: $c (код 2)" 2
  done
  read -r -a OPEN_ARR <<<"$OPEN_PORTS"
}

# ───────────────────────────── префлайт ─────────────────────────────────────
preflight() {
  step "Префлайт"
  log "bootstrap.sh v$SCRIPT_VERSION, sha256=$SCRIPT_SHA"
  if [[ -n "$SHA_EXPECT" && "$SCRIPT_SHA" != "n/a" ]]; then
    [[ "$SCRIPT_SHA" == "$SHA_EXPECT" ]] || die "sha256 не совпал (код 4)" 4
  fi
  [[ $EUID -eq 0 ]] || die "нужен root (sudo -i) (код 4)" 4
  [[ -r /etc/os-release ]] || die "нет /etc/os-release (код 4)" 4
  local id ver
  id="$(os_field ID)"
  ver="$(os_field VERSION_ID)"
  [[ "$id" == ubuntu ]] || die "это не Ubuntu (ID=${id:-?}) (код 4)" 4
  case "$ver" in
    24.04 | 26.04) log "Ubuntu $ver — поддерживается" ;;
    *) if ((FORCE)); then warn "Ubuntu ${ver:-?} не тестировалась (--force)"; else die "нужна 24.04/26.04, у тебя ${ver:-?} (код 4)" 4; fi ;;
  esac
  require_cmd apt-get
  require_cmd sshd
  require_cmd ssh-keygen
  require_cmd ufw
  local ro
  ro="$(findmnt -no OPTIONS / 2>/dev/null || true)"
  [[ "$ro" == *ro,* || "$ro" == ro ]] && die "/ смонтирован read-only (код 4)" 4
  local free_mb
  free_mb="$(df -Pk / | awk 'NR==2{print int($4/1024)}')"
  ((free_mb >= 1536)) || die "мало места на /: ${free_mb}M < 1536M (код 4)" 4
  getent hosts archive.ubuntu.com >/dev/null 2>&1 || warn "archive.ubuntu.com не резолвится — проверь DNS"
  if id "$NEW_USER" >/dev/null 2>&1; then
    local uid shell
    uid="$(id -u "$NEW_USER")"
    shell="$(getent passwd "$NEW_USER" | cut -d: -f7)"
    ((uid >= 1000)) || { ((FORCE)) || die "$NEW_USER — системный (UID $uid) (код 4)" 4; }
    case "$shell" in */nologin | */false) ((FORCE)) || die "у $NEW_USER shell=$shell (код 4)" 4 ;; esac
  fi
  VIRT="$(systemd-detect-virt -c 2>/dev/null || true)"
  [[ "$VIRT" == none ]] && VIRT=""
  [[ -n "$VIRT" ]] && warn "контейнер ($VIRT): swap и часть sysctl будут пропущены"
  ((HAS_SYSTEMD)) && systemctl is-enabled ssh.socket >/dev/null 2>&1 && SOCKET_MODE=1
  if [[ -z "$(sshd -T 2>/dev/null | awk '$1=="hostkey"{print $2}' | head -1)" ]]; then
    warn "нет host-ключей sshd — генерирую"
    ssh-keygen -A >/dev/null 2>&1 || true
  fi
  mapfile -t OLD_SSH_PORTS < <(detect_ssh_ports)
  if ((${#OLD_SSH_PORTS[@]} == 0)); then
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
      OLD_SSH_PORTS=("${SSH_CONNECTION##* }")
    elif ((FORCE)); then
      warn "порты SSH не определены, предполагаю 22 (--force)"
      OLD_SSH_PORTS=(22)
    else die "не определил текущий порт SSH; запусти по SSH или добавь --force (код 4)" 4; fi
  fi
  if ! in_array "$SSH_PORT" "${OLD_SSH_PORTS[@]}" && command -v ss >/dev/null 2>&1 &&
    ss -H -ltn "sport = :$SSH_PORT" 2>/dev/null | grep -q .; then
    die "порт $SSH_PORT занят другим сервисом (код 4)" 4
  fi
  log "текущие порты SSH: ${OLD_SSH_PORTS[*]}; целевой: $SSH_PORT"
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
  local u
  for u in $ALLOW_USERS; do
    [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "плохое имя в --allow-users: $u (код 2)" 2
  done
  ROOT_LOGIN_MODE=no
  ((KEEP_ROOT)) && ROOT_LOGIN_MODE=prohibit-password
  log "AllowUsers: $ALLOW_USERS · PermitRootLogin: $ROOT_LOGIN_MODE"
}

print_plan() {
  printf '\n%s ══════ ПЛАН (check) ══════\n' "$(ts)"
  echo "пользователь:   $NEW_USER (sudo NOPASSWD, umask $([[ $SET_UMASK == 1 ]] && echo 0077 || echo 'не трогаем'))"
  echo "SSH-порт:       $SSH_PORT (прежние останутся открыты: ${OLD_SSH_PORTS[*]})"
  echo "AllowUsers:     $ALLOW_USERS"
  echo "root:           PermitRootLogin=$ROOT_LOGIN_MODE, lock=$LOCK_ROOT"
  echo "ufw:            ${OPEN_ARR[*]:-только SSH}${SSH_ALLOW_FROM:+ (SSH с:$SSH_ALLOW_FROM)}"
  echo "swap/timezone:  ${SWAP_SIZE}${VIRT:+ (контейнер)} / ${TIMEZONE:-не трогаю}"
  echo "hostname:       ${NEW_HOSTNAME:-не трогаю}"
  echo "upgrade:        $UPGRADE"
  echo "docker/auditd:  $INSTALL_DOCKER / $INSTALL_AUDITD"
  echo "ping:           $([[ $BLOCK_PING == 1 ]] && echo блокирую || echo разрешаю)"
  echo "пакеты:         база + ${EXTRA_PACKAGES:-—}"
  log "check: система не изменена"
}

# ─────────────────────────────── ключи ──────────────────────────────────────
KEYTYPE_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-ed25519-cert-v01@openssh\.com|ssh-rsa-cert-v01@openssh\.com|ecdsa-sha2-nistp(256|384|521)-cert-v01@openssh\.com)$'

prompt_for_key() {
  { : </dev/tty; } 2>/dev/null || return 1
  local line one tries=0
  printf '\n┌─ Вставь ПУБЛИЧНЫЙ ключ (строка из .pub) и нажми Enter.\n└─ Пустой ввод — взять из /root/.ssh/authorized_keys.\n' >/dev/tty
  while ((tries < 3)); do
    printf '> ' >/dev/tty
    IFS= read -r line </dev/tty || return 1
    line="${line//$'\r'/}"
    [[ -z "${line//[[:space:]]/}" ]] && return 1
    if [[ "$line" == *"PRIVATE KEY"* ]]; then
      warn "это приватный ключ, нужен .pub"
      tries=$((tries + 1))
      continue
    fi
    one="$(mktemp -p "$RUNDIR")"
    printf '%s\n' "$line" >"$one"
    if ssh-keygen -l -f "$one" >/dev/null 2>&1; then
      rm -f "$one"
      printf '%s\n' "$line" >>"$KEYS_TMP"
      return 0
    fi
    rm -f "$one"
    warn "не похоже на публичный ключ"
    tries=$((tries + 1))
  done
  return 1
}

collect_keys() {
  step "SSH-ключи"
  KEYS_TMP="$(mktemp -p "$RUNDIR")"
  [[ -n "$SSH_KEYS" ]] && printf '%s\n' "$SSH_KEYS" >>"$KEYS_TMP"
  local k
  for k in "${KEY_ARGS[@]:-}"; do [[ -n "$k" ]] && printf '%s\n' "$k" >>"$KEYS_TMP"; done
  if [[ -n "$KEYS_FILE" ]]; then
    [[ -r "$KEYS_FILE" ]] || die "не читается $KEYS_FILE (код 1)"
    cat "$KEYS_FILE" >>"$KEYS_TMP"
    echo >>"$KEYS_TMP"
  fi
  if [[ -n "$GITHUB_USER" ]]; then
    [[ "$GITHUB_USER" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]] || die "плохое имя GitHub (код 2)" 2
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 --max-time 20 \
      "https://github.com/${GITHUB_USER}.keys" >>"$KEYS_TMP" || die "не скачал ключи github.com/$GITHUB_USER" 1
    echo >>"$KEYS_TMP"
  fi
  grep -Eq '^\s*[^#[:space:]]' "$KEYS_TMP" || prompt_for_key || true
  if ! grep -Eq '^\s*[^#[:space:]]' "$KEYS_TMP" && [[ -s /root/.ssh/authorized_keys ]]; then
    warn "ключи не переданы — беру из /root/.ssh/authorized_keys, опции command=/from= срезаю"
    awk -v re="$KEYTYPE_RE" '
      /^[[:space:]]*(#|$)/ {next}
      { for (i=1;i<=NF;i++) if ($i ~ re) { s=$i; for (j=i+1;j<=NF;j++) s=s" "$j; print s; next } }
    ' /root/.ssh/authorized_keys >>"$KEYS_TMP"
  fi
  grep -q 'PRIVATE KEY' "$KEYS_TMP" && die "в ключах приватный ключ — нужен .pub (код 1)"
  CLEAN_KEYS="$(mktemp -p "$RUNDIR")"
  grep -Ev '^\s*(#|$)' "$KEYS_TMP" | sed 's/\r$//' | awk '!seen[$0]++' >"$CLEAN_KEYS" || true
  local line one n=0
  while IFS= read -r line; do
    one="$(mktemp -p "$RUNDIR")"
    printf '%s\n' "$line" >"$one"
    ssh-keygen -l -f "$one" >/dev/null 2>&1 || die "невалидный ключ: ${line:0:60}... (код 1)"
    rm -f "$one"
    n=$((n + 1))
  done <"$CLEAN_KEYS"
  ((n > 0)) || die "нет ни одного ключа — без него нельзя закрывать пароль (код 1)"
  if ((! ASSUME_YES)) && [[ -t 0 || -e /dev/tty ]]; then
    log "валидных ключей: $n, отпечатки:"
    ssh-keygen -l -f "$CLEAN_KEYS" 2>/dev/null | while IFS= read -r l; do log "  $l"; done
    local a
    {
      printf 'Продолжить? [y/N] ' >/dev/tty
      IFS= read -r a </dev/tty || a=n
    } 2>/dev/null || a=y
    [[ "$a" =~ ^[YyДд] ]] || die "отменено пользователем" 1
  fi
}

# ───────────────────────── пакеты / время / юзер ────────────────────────────
do_upgrade() {
  step "Обновление системы"
  apt_run update
  case "$UPGRADE" in
    full) apt_run full-upgrade ;;
    safe) apt_run upgrade --with-new-pkgs ;;
    none) log "обновление пакетов пропущено (--upgrade none)" ;;
  esac
  ((AUTOREMOVE)) && apt_run autoremove --purge
  return 0
}

do_packages() {
  step "Базовые пакеты"
  apt_run install sudo iproute2 openssh-server ufw fail2ban python3-systemd unattended-upgrades ca-certificates curl
  local extra=()
  read -r -a extra <<<"$EXTRA_PACKAGES"
  apt_install wget gnupg git jq unzip zip nano vim tmux htop net-tools dnsutils lsof "${extra[@]:-}"
  write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  if [[ -n "$UNATTENDED_REBOOT" ]]; then
    write_file /etc/apt/apt.conf.d/51-bootstrap-unattended 0644 <<EOF
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "$UNATTENDED_REBOOT";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
  fi
  [[ -f /etc/default/motd-news ]] && {
    backup_file /etc/default/motd-news
    sed -i 's/^ENABLED=1/ENABLED=0/' /etc/default/motd-news
  }
  command -v pro >/dev/null 2>&1 && pro config set apt_news=false >/dev/null 2>&1 || true
  if ((INSTALL_AUDITD)); then
    apt_run install auditd audispd-plugins
    write_file /etc/audit/rules.d/90-bootstrap.rules 0640 <<'EOF'
-w /etc/passwd -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd
EOF
    svc enable auditd >/dev/null 2>&1 || true
    augenrules --load >/dev/null 2>&1 || warn "auditd: правила не загрузились"
  fi
  return 0
}

do_host_time() {
  step "Hostname и время"
  if [[ -n "$NEW_HOSTNAME" ]]; then
    backup_file /etc/hostname
    ((HAS_SYSTEMD)) && hostnamectl set-hostname "$NEW_HOSTNAME" || hostname "$NEW_HOSTNAME"
    printf '%s\n' "$NEW_HOSTNAME" >/etc/hostname
    log "hostname = $NEW_HOSTNAME"
  fi
  if ((CLOUD_INIT_CFG)) && [[ -d /etc/cloud/cloud.cfg.d ]]; then
    # cloud-init на каждом ребуте перезаписывает sshd_config.d и парольную аутентификацию
    write_file /etc/cloud/cloud.cfg.d/99-bootstrap.cfg 0644 <<'EOF'
ssh_pwauth: false
disable_root: false
EOF
    log "cloud-init: ssh_pwauth=false, disable_root=false"
  fi
  local hn
  hn="$(hostname)"
  if ! grep -Eq "(^|[[:space:]])${hn//./\\.}([[:space:]]|$)" /etc/hosts; then
    backup_file /etc/hosts
    echo "127.0.1.1 $hn" >>/etc/hosts
    log "добавил $hn в /etc/hosts"
  fi
  if [[ -n "$TIMEZONE" ]]; then
    ((HAS_SYSTEMD)) && timedatectl set-timezone "$TIMEZONE" || ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    log "таймзона = $TIMEZONE"
  fi
  ((HAS_SYSTEMD)) && { timedatectl set-ntp true 2>/dev/null || warn "NTP не включился — проверь timedatectl"; }
  return 0
}

do_user() {
  step "Пользователь $NEW_USER"
  if id "$NEW_USER" >/dev/null 2>&1; then
    log "пользователь уже есть"
    usermod -aG sudo "$NEW_USER"
  else
    useradd -m -s /bin/bash -G sudo "$NEW_USER"
    log "создан"
  fi
  local home grp
  home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  grp="$(id -gn "$NEW_USER")"
  [[ "$home" == /* && -d "$home" ]] || die "плохой home у $NEW_USER" 1
  chmod go-w "$home"
  install -d -m 700 -o "$NEW_USER" -g "$grp" "$home/.ssh"
  local ak="$home/.ssh/authorized_keys" merged
  merged="$(mktemp -p "$RUNDIR")"
  {
    [[ -f "$ak" ]] && cat "$ak"
    cat "$CLEAN_KEYS"
  } | awk '!seen[$0]++' >"$merged"
  install -m 600 -o "$NEW_USER" -g "$grp" "$merged" "$ak"
  rm -f "$merged"
  chown "$NEW_USER:$grp" "$home" "$home/.ssh" "$ak"
  chmod 700 "$home/.ssh"
  chmod 600 "$ak"
  log "authorized_keys: $(grep -c . "$ak") ключ(ей), права 600"
  local sf="/etc/sudoers.d/90-bootstrap-$NEW_USER" tmp
  tmp="$(mktemp -p "$RUNDIR")"
  printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$NEW_USER" >"$tmp"
  visudo -cf "$tmp" >/dev/null || die "sudoers не прошёл visudo" 1
  install -m 0440 -o root -g root "$tmp" "$sf"
  rm -f "$tmp"
  grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers || {
    backup_file /etc/sudoers
    printf '@includedir /etc/sudoers.d\n' >>/etc/sudoers
  }
  visudo -c >/dev/null || {
    warn "visudo -c ругается на дерево sudoers:"
    visudo -c || true
  }
  runuser -u "$NEW_USER" -- sudo -n true 2>/dev/null || die "sudo NOPASSWD для $NEW_USER не работает" 1
  log "sudo NOPASSWD проверен"
  if ((LOCK_ROOT)); then
    passwd -l root >/dev/null 2>&1 || warn "passwd -l root не удался"
    log "пароль root заблокирован"
  fi
  if ((SET_UMASK)) && ! grep -q '^umask 0077' "$home/.bashrc" 2>/dev/null; then
    echo 'umask 0077' >>"$home/.bashrc"
    chown "$NEW_USER:$grp" "$home/.bashrc"
  fi
  return 0
}

# ─────────────────────────────── firewall ───────────────────────────────────
do_firewall() {
  step "UFW"
  mapfile -t OLD_SSH_PORTS < <(detect_ssh_ports)
  ((${#OLD_SSH_PORTS[@]})) || OLD_SSH_PORTS=("${SSH_CONNECTION##* }")
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw default deny routed >/dev/null
  local from
  if [[ -n "$SSH_ALLOW_FROM" ]]; then
    for from in $SSH_ALLOW_FROM; do
      ufw allow from "$from" to any port "$SSH_PORT" proto tcp comment 'SSH' >/dev/null
      NEW_UFW_PORTS+=("$SSH_PORT")
      log "ufw allow ${SSH_PORT}/tcp from $from"
    done
  else
    ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
    NEW_UFW_PORTS+=("$SSH_PORT")
  fi
  local p
  for p in "${OLD_SSH_PORTS[@]}"; do
    [[ "$p" == "$SSH_PORT" ]] && continue
    ufw allow "${p}/tcp" comment 'SSH-transition' >/dev/null
    log "ufw allow ${p}/tcp (переходный)"
  done
  for p in "${OPEN_ARR[@]:-}"; do [[ -n "$p" ]] && {
    ufw allow "$p" comment 'bootstrap' >/dev/null
    log "ufw allow $p"
  }; done
  if [[ -f /etc/ufw/before.rules ]]; then
    local want=ACCEPT
    ((BLOCK_PING)) && want=DROP
    backup_file /etc/ufw/before.rules
    grep -qE '^# bootstrap.*ping' /etc/ufw/before.rules || sed -i "1i # bootstrap: block-ping=$BLOCK_PING" /etc/ufw/before.rules
    sed -i -E "0,/^# bootstrap.*ping/{s/^# bootstrap.*ping/# bootstrap: block-ping=$BLOCK_PING/}" /etc/ufw/before.rules
    sed -i -E "s#^(-A ufw-before-input -p icmp --icmp-type echo-request) -j (ACCEPT|DROP)#\1 -j $want#" /etc/ufw/before.rules
    log "ping (IPv4 echo-request) = $want"
  fi
  ufw --force enable >/dev/null 2>&1 || warn "ufw не включился"
  ufw reload >/dev/null 2>&1 || true
  return 0
}

do_fail2ban() {
  step "fail2ban"
  local ignore="127.0.0.1/8 ::1" ip="${SSH_CONNECTION:-}"
  ip="${ip%% *}"
  [[ "${ip:-}" =~ ^[0-9a-fA-F:.]+$ ]] && ignore+=" $ip"
  local ports="$SSH_PORT" p
  for p in "${OLD_SSH_PORTS[@]:-}"; do [[ -n "$p" && "$p" != "$SSH_PORT" ]] && ports+=",$p"; done
  write_file /etc/fail2ban/jail.d/20-bootstrap.local 0644 <<EOF
# Managed by bootstrap.sh
[DEFAULT]
ignoreip = $ignore
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w

[sshd]
enabled = true
backend = systemd
port = $ports
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  fail2ban-client -t >/dev/null 2>&1 || {
    fail2ban-client -t || true
    die "конфиг fail2ban невалиден" 1
  }
  svc enable fail2ban >/dev/null 2>&1 || true
  svc restart fail2ban || true
  if ((HAS_SYSTEMD)); then
    sleep 3
    if systemctl is-active --quiet fail2ban && fail2ban-client ping >/dev/null 2>&1; then
      log "fail2ban работает (порты: $ports)"
    else
      warn "fail2ban не поднялся — journalctl -u fail2ban -n 30 (24.04 требует noble-updates)"
    fi
  fi
  return 0
}

# ───────────────────────────── sysctl / лимиты ──────────────────────────────
do_sysctl() {
  step "sysctl, лимиты, журналы"
  local bbr="" res=""
  if ((NET_TUNING)) && [[ -z "$VIRT" ]]; then
    modprobe tcp_bbr 2>/dev/null || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
      bbr=$'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr'
      echo tcp_bbr | write_file /etc/modules-load.d/bbr.conf 0644
    else
      warn "BBR недоступен — оставляю дефолт"
    fi
  fi
  if ((SSH_PORT >= 32768 && SSH_PORT <= 60999)); then
    local cur
    cur="$(sysctl -n net.ipv4.ip_local_reserved_ports 2>/dev/null || true)"
    res="$SSH_PORT"
    [[ -n "$cur" ]] && case ",$cur," in *",$SSH_PORT,"*) res="$cur" ;; *) res="$cur,$SSH_PORT" ;; esac
    res="net.ipv4.ip_local_reserved_ports = $res"
  fi
  local hard=""
  if ((HARDENING_SYSCTL)); then
    hard=$(
      cat <<'EOF'
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_ra = 1
EOF
    )
  fi
  write_file /etc/sysctl.d/99-bootstrap.conf 0644 <<EOF
# Managed by bootstrap.sh
$bbr
$hard
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.somaxconn = 4096
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
vm.swappiness = 10
kernel.panic = 10
$res
EOF
  sysctl -q -p /etc/sysctl.d/99-bootstrap.conf || warn "часть sysctl не применилась (контейнер/ядро)"
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
  ((WRITE_CHANGED)) && svc daemon-reexec 2>/dev/null || true
  write_file /etc/systemd/journald.conf.d/99-bootstrap.conf 0644 <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
EOF
  ((WRITE_CHANGED)) && svc restart systemd-journald 2>/dev/null || true
  write_file /etc/logrotate.d/bootstrap 0644 <<'EOF'
/var/log/bootstrap.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
    create 0600 root root
    prerotate  chattr -a /var/log/bootstrap.log 2>/dev/null || true
    postrotate chattr +a /var/log/bootstrap.log 2>/dev/null || true
}
EOF
  return 0
}

# ──────────────────────────────── swap ──────────────────────────────────────
do_swap() {
  step "Swap"
  if [[ "$SWAP_SIZE" == 0 ]]; then
    log "выключен флагом"
    return 0
  fi
  [[ -n "$VIRT" ]] && {
    log "контейнер — пропуск"
    return 0
  }
  [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]] && {
    log "swap уже есть"
    return 0
  }
  [[ -e /swapfile ]] && {
    warn "/swapfile есть, но не подключён — не трогаю"
    return 0
  }
  local mb=${SWAP_SIZE%[MG]}
  [[ "$SWAP_SIZE" == *G ]] && mb=$((mb * 1024))
  local free_mb
  free_mb="$(df -Pk / | awk 'NR==2{print int($4/1024)}')"
  ((free_mb < mb + 2048)) && {
    warn "мало места (${free_mb}M) — swap пропущен"
    return 0
  }
  local tmp=/swapfile.bootstrap fstype
  fstype="$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)"
  rm -f "$tmp"
  if [[ "$fstype" == btrfs ]]; then
    : >"$tmp" && chattr +C "$tmp" 2>/dev/null || true
    fallocate -l "${mb}M" "$tmp" 2>/dev/null || dd if=/dev/zero of="$tmp" bs=1M count="$mb" status=none
  else
    (
      umask 077
      fallocate -l "${mb}M" "$tmp" 2>/dev/null || dd if=/dev/zero of="$tmp" bs=1M count="$mb" status=none
    )
  fi
  if chmod 600 "$tmp" && mkswap "$tmp" >/dev/null && mv "$tmp" /swapfile && swapon /swapfile 2>/dev/null; then
    grep -q '^/swapfile ' /etc/fstab || {
      backup_file /etc/fstab
      echo '/swapfile none swap sw 0 0' >>/etc/fstab
    }
    log "swap ${SWAP_SIZE} активен"
  else
    rm -f "$tmp"
    warn "swap не создан (ФС $fstype)"
  fi
  return 0
}

# ─────────────────────────────── docker ─────────────────────────────────────
do_docker() {
  step "Docker"
  if ((! INSTALL_DOCKER)); then
    log "пропуск (--docker)"
    return 0
  fi
  local was=0
  ((HAS_SYSTEMD)) && systemctl is-active --quiet docker 2>/dev/null && was=1
  local changed=0
  if [[ ! -f /etc/docker/daemon.json ]]; then
    write_file /etc/docker/daemon.json 0644 <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
    changed=$WRITE_CHANGED
  fi
  apt_run install docker.io
  apt_install docker-compose-v2
  usermod -aG docker "$NEW_USER" || warn "не добавил $NEW_USER в docker"
  svc enable --now docker || warn "docker не стартовал"
  ((changed && was)) && {
    warn "docker уже работал — перезапускаю"
    svc restart docker || true
  }
  if ((DOCKER_UFW)) && [[ -f /etc/ufw/after.rules ]] && ! grep -q 'BEGIN UFW AND DOCKER' /etc/ufw/after.rules; then
    backup_file /etc/ufw/after.rules
    local blk="$RUNDIR/docker-ufw"
    cat >"$blk" <<'EOF'
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
    awk -v blk="$(cat "$blk")" '/^COMMIT[[:space:]]*$/ && !done {print blk; done=1} {print}' \
      /etc/ufw/after.rules >"$blk.new" && install -m 640 -o root -g root "$blk.new" /etc/ufw/after.rules
    ufw reload >/dev/null 2>&1 || true
    log "DOCKER-USER установлен: разрешай порты через 'ufw route allow ...'"
  elif ((DOCKER_UFW)); then
    log "правило DOCKER-USER уже есть"
  else
    warn "docker обходит ufw для -p (включай --docker-ufw)"
  fi
  return 0
}

# ─────────────────────────── hardening SSH ──────────────────────────────────
tcp_open() { timeout 2 bash -c ": </dev/tcp/127.0.0.1/$1" 2>/dev/null; }

do_ssh() {
  step "Hardening SSH"
  mkdir -p /run/sshd /etc/ssh/sshd_config.d
  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
    backup_file /etc/ssh/sshd_config
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  fi
  local home ak
  home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  ak="$home/.ssh/authorized_keys"
  [[ -s "$ak" ]] || die "authorized_keys пуст — пароль не закрываю" 1
  [[ -f "$SSHD_DROPIN" ]] && {
    cp -a "$SSHD_DROPIN" "$RUNDIR/sshd.prev"
    SSHD_HAD=1
  }
  [[ -f "$SOCK_DROPIN" ]] && {
    cp -a "$SOCK_DROPIN" "$RUNDIR/sock.prev"
    SOCK_HAD=1
  }
  SSH_TXN=1
  local fwd=no af=no
  [[ "$AGENT_FORWARDING" == 1 ]] && af=yes
  local port_line=""
  ((SSH_PORT != 22)) && port_line="Port $SSH_PORT"
  cat >"$SSHD_DROPIN" <<EOF
# Managed by bootstrap.sh v$SCRIPT_VERSION
$port_line
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
AllowAgentForwarding $af
AllowTcpForwarding $fwd
GatewayPorts no
PermitTunnel no
EOF
  chmod 644 "$SSHD_DROPIN"
  sshd -t || die "sshd -t не прошёл" 1
  local eff
  eff="$(sshd -T 2>/dev/null | sed 's/^permitrootlogin without-password$/permitrootlogin prohibit-password/')"
  local want
  for want in "passwordauthentication no" "kbdinteractiveauthentication no" "permitrootlogin $ROOT_LOGIN_MODE" \
    "pubkeyauthentication yes" "authenticationmethods publickey" "port $SSH_PORT"; do
    grep -qxF "$want" <<<"$eff" || die "эффективный конфиг не содержит '$want' (перебит другим drop-in?)" 1
  done
  [[ "$(sshd_allowusers)" == "$(expected_allowusers)" ]] || die "AllowUsers не совпадает с ожидаемым: $(sshd_allowusers)" 1
  if ((HAS_SYSTEMD && SOCKET_MODE)); then
    if ((SSH_PORT != 22)); then
      mkdir -p "$(dirname "$SOCK_DROPIN")"
      {
        printf '[Socket]\nListenStream=\nListenStream=0.0.0.0:%s\n' "$SSH_PORT"
        if [[ -e /proc/net/if_inet6 ]]; then
          printf 'ListenStream=[::]:%s\nBindIPv6Only=ipv6-only\n' "$SSH_PORT"
        fi
      } >"$SOCK_DROPIN"
    else rm -f "$SOCK_DROPIN"; fi
  else
    warn "sshd слушает напрямую (без systemd-сокета)"
  fi
  SSH_CUT=1
  restart_ssh || die "ssh не перезапустился — откат" 1
  if ((HAS_SYSTEMD)); then
    local l=0
    for _ in $(seq 1 15); do
      tcp_open "$SSH_PORT" && {
        l=1
        break
      }
      sleep 1
    done
    ((l)) || die "sshd не слушает $SSH_PORT за 15с — откат" 1
    log "sshd слушает $SSH_PORT"
  fi
  SSH_TXN=0
  return 0
}

post_login_test() {
  local key="" rc
  for key in /root/.ssh/id_ed25519 /root/.ssh/id_rsa "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
    [[ -r "$key" ]] && break || key=""
  done
  local args=(-p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o NumberOfPasswordPrompts=0)
  [[ -n "$key" ]] && args+=(-i "$key")
  if ssh "${args[@]}" "$NEW_USER@127.0.0.1" true 2>/dev/null; then
    pass "вход по ключу на 127.0.0.1:$SSH_PORT"
  else
    warn "локальный вход по ключу не удался (нет приватного ключа на сервере?) — проверь вручную"
  fi
}

# ─────────────────────────────── проверки ───────────────────────────────────
chk() {
  local id=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$id"; else fail "$id"; fi
}

c_sshd_listen() { tcp_open "$SSH_PORT"; }
c_sshd_conf() {
  local e
  e="$(sshd -T 2>/dev/null | sed 's/^permitrootlogin without-password$/permitrootlogin prohibit-password/')"
  grep -qxF "port $SSH_PORT" <<<"$e" &&
    grep -qxF "passwordauthentication no" <<<"$e" &&
    grep -qxF "permitrootlogin $ROOT_LOGIN_MODE" <<<"$e" &&
    [[ "$(sshd_allowusers)" == "$(expected_allowusers)" ]]
}
c_ak() {
  local ak
  ak="$(getent passwd "$NEW_USER" | cut -d: -f6)/.ssh/authorized_keys"
  [[ -s "$ak" ]]
}
c_ak_perm() {
  local h
  h="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  [[ "$(stat -c '%U:%a' "$h/.ssh/authorized_keys" 2>/dev/null)" == "$NEW_USER:600" &&
  "$(stat -c '%a' "$h/.ssh" 2>/dev/null)" == 700 ]]
}
c_sudo() { runuser -u "$NEW_USER" -- sudo -n true 2>/dev/null; }
c_ufw() { ufw status 2>/dev/null | head -1 | grep -q 'Status: active'; }
c_ufw_ssh() { ufw status 2>/dev/null | grep -qE "^${SSH_PORT}(/tcp)?[[:space:]]"; }
c_ufw_deny() { ufw status verbose 2>/dev/null | grep -q 'Default: deny (incoming)'; }
c_f2b() { ((! HAS_SYSTEMD)) || systemctl is-active --quiet fail2ban; }
c_f2b_ports() { fail2ban-client status sshd >/dev/null 2>&1 && grep -Eq "^port = ([0-9]+,)*${SSH_PORT}(,|$)" /etc/fail2ban/jail.d/20-bootstrap.local; }
c_swap() { [[ "$SWAP_SIZE" == 0 || -n "$VIRT" ]] || [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; }
c_ping() {
  local want=DROP
  ((BLOCK_PING)) || want=ACCEPT
  grep -qE "^-A ufw-before-input -p icmp --icmp-type echo-request -j $want" /etc/ufw/before.rules 2>/dev/null
}
c_hostname() { [[ -z "$NEW_HOSTNAME" ]] || [[ "$(hostname)" == "$NEW_HOSTNAME" ]]; }
c_timezone() { [[ -z "$TIMEZONE" ]] || [[ "$(readlink -f /etc/localtime 2>/dev/null)" == "/usr/share/zoneinfo/$TIMEZONE" ]]; }
c_unattended() { [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; }
c_cloudinit() { ((! CLOUD_INIT_CFG)) || [[ ! -d /etc/cloud/cloud.cfg.d ]] || grep -q '^ssh_pwauth: false' /etc/cloud/cloud.cfg.d/99-bootstrap.cfg 2>/dev/null; }
c_apparmor() { [[ ! -d /sys/kernel/security/apparmor ]] || [[ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" == Y ]]; }
c_umask() { ((! SET_UMASK)) || grep -q '^umask 0077' "$(getent passwd "$NEW_USER" | cut -d: -f6)/.bashrc" 2>/dev/null; }
c_sysctl() {
  local pair
  for pair in kernel.dmesg_restrict=1 net.ipv4.tcp_syncookies=1; do
    [[ "$(sysctl -n "${pair%%=*}" 2>/dev/null)" == "${pair##*=}" ]] || return 1
  done
}
c_ports_open() {
  local p
  for p in "${OPEN_ARR[@]:-}"; do
    [[ -z "$p" ]] && continue
    ufw status 2>/dev/null | grep -qF "${p%%/*}" || return 1
  done
}

run_checks() {
  step "Проверки соответствия"
  chk sshd_listening c_sshd_listen
  chk sshd_effective_config c_sshd_conf
  chk authorized_keys c_ak
  chk authorized_keys_perm c_ak_perm
  chk sudo_nopasswd c_sudo
  chk ufw_active c_ufw
  chk ufw_default_deny c_ufw_deny
  chk ufw_ssh_rule c_ufw_ssh
  chk ufw_extra_ports c_ports_open
  chk fail2ban_active c_f2b
  chk fail2ban_ports c_f2b_ports
  chk swap c_swap
  chk ping_policy c_ping
  chk hostname c_hostname
  chk timezone c_timezone
  chk unattended_upgrades c_unattended
  chk cloud_init_pwauth c_cloudinit
  chk apparmor c_apparmor
  chk umask c_umask
  chk hardening_sysctl c_sysctl
  ((fail_count == 0)) || warn "провалено проверок: $fail_count"
}

finish_json() {
  ((JSON)) || return 0
  local okv=true f it
  ((fail_count == 0)) || okv=false
  printf '{"version":"%s","user":"%s","port":%s,"ok":%s,"passed":%d,"failed":%d,"checks":[' \
    "$SCRIPT_VERSION" "$NEW_USER" "$SSH_PORT" "$okv" "$pass_count" "$fail_count"
  local sep=""
  for it in "${json_items[@]:-}"; do
    [[ -z "$it" ]] && continue
    printf '%s%s' "$sep" "$it"
    sep=","
  done
  printf ']}\n'
}

# ─────────────────────────────── состояние ──────────────────────────────────
save_state() {
  install -d -m 700 "$STATE_DIR"
  write_file "$STATE_FILE" 600 <<EOF
# Managed by bootstrap.sh — используется режимом verify
STATE_VERSION=1
APPLIED_AT='$(date -u +%FT%TZ)'
SCRIPT_VERSION='$SCRIPT_VERSION'
NEW_USER='$NEW_USER'
SSH_PORT='$SSH_PORT'
ALLOW_USERS='$ALLOW_USERS'
ROOT_LOGIN_MODE='$ROOT_LOGIN_MODE'
OPEN_PORTS='$OPEN_PORTS'
SSH_ALLOW_FROM='$SSH_ALLOW_FROM'
BLOCK_PING='$BLOCK_PING'
SWAP_SIZE='$SWAP_SIZE'
TIMEZONE='$TIMEZONE'
NEW_HOSTNAME='$NEW_HOSTNAME'
SET_UMASK='$SET_UMASK'
CLOUD_INIT_CFG='$CLOUD_INIT_CFG'
EOF
}

load_state() {
  [[ -r "$STATE_FILE" ]] || die "нет состояния $STATE_FILE — сначала apply (код 3)" 3
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  ROOT_LOGIN_MODE="${ROOT_LOGIN_MODE:-no}"
  read -r -a OPEN_ARR <<<"${OPEN_PORTS:-}"
}

# ──────────────────────────────── итог ──────────────────────────────────────
summary() {
  printf '\n%s ══════ ГОТОВО ══════\n' "$(ts)"
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo "SSH:      ssh -p $SSH_PORT $NEW_USER@${ip:-<ip>}"
  echo "sshd:     $(sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|allowusers) ' | tr '\n' ';')"
  echo "ufw:      $(ufw status 2>/dev/null | head -1)"
  echo "fail2ban: $(systemctl is-active fail2ban 2>/dev/null || echo n/a)"
  warn "не закрывай текущую сессию, пока в новом окне не проверишь: ssh -p $SSH_PORT $NEW_USER@${ip:-<ip>} && sudo -n true"
  warn "проверь, что $SSH_PORT открыт в security group / cloud firewall провайдера"
  local p
  for p in "${OLD_SSH_PORTS[@]}"; do
    [[ "$p" == "$SSH_PORT" ]] && continue
    warn "переходный порт $p открыт; закрыть: ufw delete allow ${p}/tcp (или перезапусти скрипт с --close-old-ports)"
  if [[ -f /var/run/reboot-required ]]; then
    warn "требуется перезагрузка (новое ядро)"
  fi
}

close_old_ports() {
  ((CLOSE_OLD_PORTS)) || return 0
  ((fail_count == 0)) || {
    warn "есть провалы проверок — переходные порты не закрываю"
    return 0
  }
  local p
  for p in "${OLD_SSH_PORTS[@]:-}"; do
    [[ -n "$p" && "$p" != "$SSH_PORT" ]] && {
      ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
      log "закрыл переходный порт $p"
    }
  done
  ufw reload >/dev/null 2>&1 || true
}

# ───────────────────────────────── main ─────────────────────────────────────
apply_all() {
  ((ASSUME_YES)) || { : </dev/tty; } 2>/dev/null || { [[ -n "${SSH_CONNECTION:-}" ]] || warn "нет tty и --yes"; }
  collect_keys
  do_upgrade
  do_packages
  do_host_time
  do_user
  do_firewall
  do_fail2ban
  do_sysctl
  do_swap
  do_docker
  do_ssh
  save_state
  post_login_test
  run_checks
  close_old_ports
  summary
  if ((DO_REBOOT)); then
    warn "перезагрузка через 1 минуту, отмена: shutdown -c"
    shutdown -r +1 "bootstrap.sh" || warn "shutdown не удался"
  fi
  finish_json
  ((fail_count == 0)) || {
    warn "провалено проверок: $fail_count — см. FAIL выше и $LOG"
    return 1
  }
  return 0
}

main() {
  exec 8>&2
  RUNDIR="$(mktemp -d /run/bootstrap.XXXXXX)"
  trap on_exit EXIT
  trap 'die "прервано сигналом" 1' INT TERM
  trap 'die "сбой на строке $LINENO: $BASH_COMMAND (лог: $LOG)" 1' ERR
  install -d -m 755 "$(dirname "$LOG")"
  [[ -e "$LOG" ]] || install -m 600 /dev/null "$LOG"
  chmod 600 "$LOG" 2>/dev/null || true
  chattr +a "$LOG" 2>/dev/null || true
  exec 8>>"$LOG"
  BACKUP_DIR="/var/backups/bootstrap/$(date +%Y%m%d-%H%M%S)"
  case "${BASH_SOURCE[0]:-}" in
    /dev/fd/* | /proc/self/fd/* | pipe:*) : ;;
    *) [[ -r "${BASH_SOURCE[0]:-}" ]] && SCRIPT_SHA="$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')" ;;
  esac
  pre_scan_config "$@"
  parse_args "$@"
  # значения, сохранённые предыдущим apply, — база для повторного запуска
  # shellcheck disable=SC1090
  if [[ -r "$STATE_FILE" ]]; then (
    set -a
    . "$STATE_FILE"
    set +a
  ); fi
  parse_args "$@"
  if [[ "$MODE" == verify ]]; then
    load_state
    validate_all
    run_checks
    finish_json
    ((fail_count == 0)) || {
      warn "дрейф: $fail_count проверок провалено"
      exit 3
    }
    log "машина соответствует состоянию от ${APPLIED_AT:-?}"
    exit 0
  fi
  validate_all
  preflight
  if [[ "$MODE" == check ]]; then
    print_plan
    exit 0
  fi
  exec 9>"$LOCK"
  flock -n 9 || die "уже работает другой экземпляр (lock $LOCK)" 1
  apply_all
}

if [[ -z "${BOOTSTRAP_LIB_ONLY:-}" ]]; then main "$@"; fi
