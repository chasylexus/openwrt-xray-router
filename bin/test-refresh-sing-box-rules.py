#!/usr/bin/env python3
"""Check refresh selection and managed-stop safety with local command fixtures."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile


source = Path(__file__).with_name("refresh-sing-box-rules.sh").read_text()
with tempfile.TemporaryDirectory(prefix="rule-refresh-test-") as directory:
    root = Path(directory)
    commands = root / "commands"
    commands.mkdir()
    config = root / "config"
    config.mkdir()
    (config / "config.json").write_text(json.dumps({"route": {"rule_set": [
        {"type": "remote", "tag": "manual-a", "url": "https://example.com/a.json",
         "update_interval": "2h"},
        {"type": "remote", "tag": "primevideo", "url": "https://example.com/p.srs",
         "update_interval": "2h"},
        {"type": "local", "tag": "local-only", "path": "local.json"},
    ]}}, indent=2))
    calls = root / "calls"
    for name, body in {
        "id": "printf '0\\n'",
        "ss": "printf 'LISTEN 127.0.0.1:11080\\n'",
        "sing-box": 'printf "check\\n" >> "$FIXTURE_CALLS"',
        "sing-box-init": 'printf "service-mutation\\n" >> "$FIXTURE_CALLS"; exit 99',
        "dnsmasq-init": 'printf "dns-mutation\\n" >> "$FIXTURE_CALLS"; exit 99',
    }.items():
        path = commands / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)
    for old, new in {
        'SB_ROOT="/etc/sing-box-router"': config,
        'SB_DATA="/var/lib/sing-box-router"': root / "data",
        'SB_BIN="/usr/local/bin/sing-box"': commands / "sing-box",
        'SB_INIT="/etc/init.d/sing-box-router"': commands / "sing-box-init",
        'DNS_INIT="/etc/init.d/dnsmasq"': commands / "dnsmasq-init",
        'BACKUP_ROOT="/root/router-stack-backups"': root / "backups",
        'LOCK_DIR="/tmp/sing-box-rule-refresh.lock"': root / "lock",
    }.items():
        assert source.count(old) == 1
        source = source.replace(old, old.split("=", 1)[0] + "=" + shlex.quote(str(new)))
    # Exercise all real preflight code, then stop at the maintenance boundary.
    boundary = "MAINTENANCE_ACTIVE=1\n"
    assert source.count(boundary) == 1
    source = source.replace(boundary,
        'printf "SELECTED=%s\\n" "$EXPECTED_RULES"\ncat "$RULE_TAGS"\nexit 0\n' + boundary)
    script = root / "refresh.sh"
    script.write_text(source)
    env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
               FIXTURE_CALLS=str(calls), REFRESH_TIMEOUT="600", RULE_REFRESH_TIMEOUT="30")
    cases = [
        ([], ["manual-a", "primevideo"]),
        (["manual-a"], ["manual-a"]),
        (["primevideo", "manual-a", "primevideo"], ["manual-a", "primevideo"]),
        (["missing"], None),
        (["manual-a", "missing"], None),
        (["local-only"], None),
        ([""], None),
        (["../manual-a"], None),
        (["manual a"], None),
        (["manual-a\nprimevideo"], None),
        (["*"], None),
    ]
    for args, expected in cases:
        calls.write_text("")
        result = subprocess.run(["sh", str(script), *args], env=env,
                                capture_output=True, text=True)
        if expected is None:
            assert result.returncode != 0, args
            assert "rule-set tag" in result.stderr, (args, result.stderr)
            assert "SELECTED=" not in result.stdout, args
            assert calls.read_text() == "", args
        else:
            assert result.returncode == 0, (args, result.stderr)
            assert result.stdout.splitlines()[-len(expected)-1:] == [
                "SELECTED=" + str(len(expected)), *expected], args
            assert calls.read_text() == "check\n", args
    print(f"PASS: {len(cases)} tag-selection/pre-stop cases")

    functions = source.split('[ "$(id -u)" = "0" ]', 1)[0]
    init = commands / "sing-box-init"
    init.write_text('#!/bin/sh\nprintf "stop\\n" >> "$FIXTURE_CALLS"\nexit "$STOP_EXIT"\n')
    mocks = '''
ubus() { printf 'lookup\\n' >> "$FIXTURE_CALLS"; printf '{}\\n'; return "$UBUS_EXIT"; }
jsonfilter() {
    cat >/dev/null
    [ "$2" = '@' ] || printf '%s\\n' "$FIXTURE_PID"
}
stop_ticks=0
sleep() { stop_ticks=$((stop_ticks + 1)); }
kill() {
    [ "$1" = '-0' ] && [ "$2" = '424242' ] || exit 90
    [ "$stop_ticks" -lt "$EXIT_AFTER" ]
}
'''
    stop_cases = [
        ("delayed exit", "424242", 2, 0, 0, True),
        ("no managed process", "", 0, 0, 0, True),
        ("timeout", "424242", 1000, 0, 0, False),
        ("multiple processes", "424242\n424243", 0, 0, 0, False),
        ("failed stop, dead PID", "424242", 0, 1, 0, True),
        ("failed stop, live PID", "424242", 1000, 1, 0, False),
        ("unavailable procd", "424242", 0, 0, 1, False),
    ]
    for name, pid, exit_after, stop_exit, ubus_exit, succeeds in stop_cases:
        calls.write_text("")
        fixture_env = dict(env, FIXTURE_PID=pid, EXIT_AFTER=str(exit_after),
                           STOP_EXIT=str(stop_exit), UBUS_EXIT=str(ubus_exit))
        check = '''
if stop_managed_stack; then
    printf 'cache-snapshot\\n' >> "$FIXTURE_CALLS"
else
    exit 1
fi
'''
        if name == "timeout":
            # Rollback must still wait for the old PID after procd forgets it.
            check = '''
if stop_managed_stack; then exit 91; fi
FIXTURE_PID=''
if stop_managed_stack; then exit 92; fi
exit 1
'''
        result = subprocess.run(["sh", "-c", functions + mocks + check],
                                env=fixture_env, capture_output=True, text=True)
        observed = calls.read_text().splitlines()
        assert (result.returncode == 0) == succeeds, (name, result.stderr)
        assert ("cache-snapshot" in observed) == succeeds, (name, observed)
        if name == "timeout":
            assert result.returncode == 1 and observed == ["lookup", "stop", "stop"], observed
        if name in ("multiple processes", "unavailable procd"):
            assert "stop" not in observed, (name, observed)
    print(f"PASS: {len(stop_cases)} managed-stop cases")
