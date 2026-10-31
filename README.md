# script-for-server-optimization

Базовый слой для Ubuntu 24.04 / 26.04: пользователь с ключом и sudo, SSH на нестандартном порту без пароля, UFW, fail2ban, sysctl-hardening, swap, unattended-upgrades, опционально Docker и auditd. Один файл, без зависимостей, идемпотентный, с транзакционным откатом SSH.

## Режимы

| режим | что делает | код |
|---|---|---|
| `apply` | приводит машину к целевому состоянию | 0 / 1 |
| `check` | валидирует окружение и печатает план | 0 / 2 / 4 |
| `verify` | сверяет живую машину с состоянием, JSON через `--json` | 0 / 3 |

`verify` — то, что гоняется перед работой на каждой машине: дрейф конфигурации ловится до того, как начнётся задача.

## Запуск

```
bash <(curl -fsSL --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/Frog2233-DevOps/script-for-server-optimization/<COMMIT_SHA>/bootstrap.sh)
```

Автоматика:

```
bash bootstrap.sh apply --yes --github youruser
bash bootstrap.sh verify --json
```

Полный список флагов: `--help`. Пример конфигурации: `examples/bootstrap.conf`.

## Гарантии

- UFW открывает и старый, и новый порт SSH; старый закрывается только после успешных проверок.
- Сбой на любом шаге правки SSH откатывает конфиг sshd и правила ufw.
- Пароль закрывается только при непустом `authorized_keys`, `sudo -n` проверяется на месте.
- cloud-init фиксируется (`ssh_pwauth: false`), иначе он вернёт пароль после ребута.
- `apply` заканчивается теми же проверками, что и `verify`.

## Разработка

```
make check   # синтаксис + lib-режим
make lint    # shellcheck + shfmt
make test    # bats
make smoke   # apply -> verify -> повторный apply в systemd-контейнере
```

Релиз: `make release V=2.0.1` — тег, workflow собирает sha256 и публикует файл.

## Лицензия

MIT, см. `LICENSE`.
