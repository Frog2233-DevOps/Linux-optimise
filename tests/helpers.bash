#!/usr/bin/env bash
setup() {
  export BOOTSTRAP_LIB_ONLY=1
  # bats вызывает setup сам; повторный вызов из теста не должен подключать скрипт второй раз (readonly)
  if ! declare -F valid_port >/dev/null; then
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../bootstrap.sh"
  fi
}
