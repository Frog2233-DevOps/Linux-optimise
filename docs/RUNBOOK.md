# Runbook

## Первый запуск на машине

```
bash <(curl -fsSL --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/Frog2233-DevOps/Linux-optimise/<SHA>/bootstrap.sh)
```

Не закрывать текущую сессию. В новом окне:

```
ssh -p 49500 super@<ip> && sudo -n true
```

Только после успеха: `ufw delete allow 22/tcp` (или `--close-old-ports` при следующем прогоне).

## Периодическая проверка дрейфа

```
curl -fsSL .../bootstrap.sh -o /usr/local/sbin/bootstrap.sh && chmod 700 /usr/local/sbin/bootstrap.sh
/usr/local/sbin/bootstrap.sh verify --json
```

Код 3 — машина разошлась с базовой линией, разбирать по списку FAIL.

## Откат

- SSH не поднялся: скрипт откатил конфиг сам. Вручную — `/var/backups/bootstrap/<ts>/`.
- Потерян вход: с консоли провайдера `rm /etc/ssh/sshd_config.d/00-bootstrap.conf && systemctl restart ssh`.
- Удалить всё применение: `rm -f /etc/ssh/sshd_config.d/00-bootstrap.conf /etc/sysctl.d/99-bootstrap.conf && systemctl restart ssh`.

## Типовые сбои

| Симптом | Причина | Действие |
|---|---|---|
| `suite noble-updates` в логе fail2ban | устаревший индекс apt | `apt update`, `systemctl restart fail2ban` |
| `ufw не включился` | нет netfilter в контейнере | проверить `iptables -L`, запускать на KVM/LXC с модулями |
| `не определил текущий порт SSH` | запуск из консоли провайдера | добавить `--force` |
