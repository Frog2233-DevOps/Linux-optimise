# Контроли

`verify` проверяет ровно этот список. Каждый пункт — отдельный `chk` в `run_checks`.

| id | что проверяется |
|---|---|
| sshd_listening | sshd слушает целевой порт |
| sshd_effective_config | port, PasswordAuthentication no, PermitRootLogin, AllowUsers из `sshd -T` |
| authorized_keys / _perm | ключ есть, владелец и режимы 600/700 |
| sudo_nopasswd | `sudo -n` у пользователя работает |
| ufw_active / _default_deny / _ssh_rule / _extra_ports | профиль firewall соответствует плану |
| fail2ban_active / _ports | jail sshd активен и покрывает порты |
| swap / ping_policy / hostname / timezone | целевые значения применены |
| unattended_upgrades / cloud_init_pwauth | обновления включены, cloud-init не вернёт пароль |
| apparmor / umask / hardening_sysctl | базовый hardening на месте |
