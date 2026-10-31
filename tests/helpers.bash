#!/usr/bin/env bash
setup() {
  export BOOTSTRAP_LIB_ONLY=1
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../../bootstrap.sh"
}
