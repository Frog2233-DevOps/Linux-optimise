#!/usr/bin/env bats
load ../helpers

@test "parse_args переключает режимы" {
  setup
  parse_args check
  [ "$MODE" = check ]
  parse_args verify
  [ "$MODE" = verify ]
}

@test "parse_args собирает ключи и порты" {
  setup
  parse_args --key "ssh-ed25519 AAAA" --ports "80/tcp"
  [ "${#KEY_ARGS[@]}" -eq 1 ]
  [ "$OPEN_PORTS" = "80/tcp" ]
}

@test "parse_args включает docker-ufw только вместе с docker" {
  setup
  parse_args --docker-ufw
  [ "$INSTALL_DOCKER" -eq 1 ]
  [ "$DOCKER_UFW" -eq 1 ]
}

@test "parse_args на мусоре выходит с кодом 2" {
  setup
  run parse_args --nope
  [ "$status" -eq 2 ]
}
