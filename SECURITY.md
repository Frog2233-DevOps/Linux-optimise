# Политика безопасности

Поддерживается только последняя версия из `main` и последний тег.

## Что считается уязвимостью

- откат SSH-транзакции не восстанавливает доступ;
- `apply` закрывает пароль при пустом `authorized_keys`;
- подмена скрипта при запуске через `curl | bash` (защита: `--sha256`);
- повышение привилегий через sudoers-файл, `authorized_keys` или drop-in.

## Правила по умолчанию

- `PasswordAuthentication no` + `AuthenticationMethods publickey`;
- `PermitRootLogin prohibit-password`, root в `AllowUsers` при `--keep-root`;
- пароль root не блокируется без `--lock-root`, чтобы не потерять VNC-консоль;
- логи `0600` и append-only, бэкапы `0700` в `/var/backups/bootstrap/`.

## Репорт

support@omnix.now или приватный Security Advisory в GitHub. Ответ в течение 72 часов.
