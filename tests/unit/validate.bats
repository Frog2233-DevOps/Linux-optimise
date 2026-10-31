#!/usr/bin/env bats
load ../helpers

@test "valid_port принимает границы" {
  setup
  run valid_port 1;   [ "$status" -eq 0 ]
  run valid_port 65535; [ "$status" -eq 0 ]
  run valid_port 0;   [ "$status" -ne 0 ]
  run valid_port 65536; [ "$status" -ne 0 ]
  run valid_port abc; [ "$status" -ne 0 ]
}

@test "validate_ports разбирает допустимые списки" {
  setup
  OPEN_PORTS="80/tcp 443/tcp 6000:6010/udp 22"
  run validate_ports; [ "$status" -eq 0 ]
}

@test "validate_ports отвергает диапазон без протокола" {
  setup
  OPEN_PORTS="6000:6010"
  run validate_ports; [ "$status" -eq 2 ]
}

@test "validate_ports отвергает обратный диапазон" {
  setup
  OPEN_PORTS="6010:6000/tcp"
  run validate_ports; [ "$status" -eq 2 ]
}

@test "validate_all отвергает имя root и плохой порт" {
  setup
  NEW_USER=root
  run validate_all; [ "$status" -eq 2 ]
  NEW_USER=super; SSH_PORT=70000
  run validate_all; [ "$status" -eq 2 ]
}

@test "validate_all отвергает плохую таймзону и hostname" {
  setup
  TIMEZONE="Mars/Olympus"
  run validate_all; [ "$status" -eq 2 ]
  TIMEZONE=""; NEW_HOSTNAME="-bad"
  run validate_all; [ "$status" -eq 2 ]
}
