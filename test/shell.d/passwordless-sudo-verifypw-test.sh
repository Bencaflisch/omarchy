#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$SHELL_TEST_DIR/fixtures/passwordless-sudo-test.sh"

# Under sudo's default verifypw=all, `sudo -v` asks for a password unless every
# entry the user has is passwordless. The installer's own admin grant is
# password-requiring, so a user who asked for passwordless sudo could not
# validate their credentials without a password. The published grant therefore
# carries the sudoers default that makes validation read the grant instead of
# every other entry in the policy.

(
  source "$library"
  enable_locked 1000 15
  head -1 "$(rule_file 1000)" | grep -qx 'Defaults verifypw = any'
  tail -1 "$(rule_file 1000)" | grep -qx 'audituser ALL=(ALL) NOTAFTER=[0-9]\{14\}Z NOPASSWD: ALL'
)
pass "the published grant carries the sudoers default above its rule"

(
  source "$library"
  enable_locked 1000 permanent
  head -1 "$(rule_file 1000 permanent)" | grep -qx 'Defaults verifypw = any'
  tail -1 "$(rule_file 1000 permanent)" | grep -qx 'audituser ALL=(ALL) NOPASSWD: ALL'
)
pass "a permanent grant carries the sudoers default above its rule"

# A grant published before the default existed is still this command's grant,
# so it keeps working until it is rewritten.
(
  source "$library"
  reset_grant
  printf 'audituser ALL=(ALL) NOPASSWD: ALL\n' >"$(rule_file 1000 permanent)"
  read_grant 1000
  [[ $GRANT_NAME == "audituser" ]]
)
pass "a grant published before the default existed is still read as the user's grant"

# The upgrade rewrites such a grant in place, keeping the rule and its
# deadline exactly as they were.
(
  source "$library"
  reset_grant
  printf 'audituser ALL=(ALL) NOTAFTER=20261231235959Z NOPASSWD: ALL\n' >"$(rule_file 1000)"
  upgrade_grant_format_locked
  head -1 "$(rule_file 1000)" | grep -qx 'Defaults verifypw = any'
  tail -1 "$(rule_file 1000)" | grep -qx 'audituser ALL=(ALL) NOTAFTER=20261231235959Z NOPASSWD: ALL'
  [[ $(wc -l <"$(rule_file 1000)") == 2 ]]
)
pass "the upgrade rewrites a grant published before the default existed"

(
  source "$library"
  reset_grant
  printf 'audituser ALL=(ALL) NOPASSWD: ALL\n' >"$(rule_file 1000 permanent)"
  upgrade_grant_format_locked
  upgrade_grant_format_locked
  [[ $(wc -l <"$(rule_file 1000 permanent)") == 2 ]]
  tail -1 "$(rule_file 1000 permanent)" | grep -qx 'audituser ALL=(ALL) NOPASSWD: ALL'
)
pass "the upgrade leaves a grant that already carries the default alone"

# Policy this command did not generate stays untouched: it belongs to the
# administrator, and rewriting it would publish a rule nobody asked for.
(
  source "$library"
  printf 'admin ALL=(ALL) NOPASSWD: /usr/bin/true\n' >"$test_tmp/etc/sudoers.d/99-omarchy-nopasswd-custom"
  upgrade_grant_format_locked
  [[ $(cat "$test_tmp/etc/sudoers.d/99-omarchy-nopasswd-custom") == 'admin ALL=(ALL) NOPASSWD: /usr/bin/true' ]]
)
pass "the upgrade leaves administrator policy under the generated prefix alone"
