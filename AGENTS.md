# EdgeOS Automation Agent Instructions

This document defines **clear, enforceable rules** for writing scripts that configure **Ubiquiti EdgeOS (Vyatta-based)** systems. These rules exist to prevent configuration corruption, partial commits, and unsafe automation.

---

## 1. Scope

These instructions apply to:
- Bash scripts
- Provisioning scripts
- CI/CD automation
- SSH-based remote configuration
- Configuration bootstrap and recovery tooling

They apply to **all EdgeOS versions**, including EdgeOS 1.x, 2.x, and 3.x.

---

## 2. Non-Negotiable Rules

### ❌ NEVER edit EdgeOS configuration files directly

Do **not** edit:
- `/config/config.boot`
- `/config/config.boot.tmp`
- Any file under `/opt/vyatta/config/`

Direct edits bypass EdgeOS’ transaction system and will eventually cause:
- Corrupted configs
- Silent failures
- Broken upgrades

If a script edits these files directly, it is **wrong**.

---

### ✅ ALWAYS use the Vyatta configuration system

All configuration **must** be applied using:

```text
configure
set ...
commit
save
exit
```

This guarantees:
- Transaction safety
- Rollback capability
- Internal state consistency

---

## 3. Script Structure (Required)

### Required shebang and environment

All local EdgeOS scripts **must** start with:

```bash
#!/bin/vbash
source /opt/vyatta/etc/functions/script-template
```

This ensures:
- Correct environment variables
- Access to EdgeOS helper functions
- Compatibility across firmware versions

---

### Required execution context

- Scripts **must run as root**
- Scripts **must not assume interactivity**
- Scripts **must fail loudly** if a commit fails

---

## 4. Minimal Valid Script Template

```bash
#!/bin/vbash
source /opt/vyatta/etc/functions/script-template

configure

set system host-name edge01
set system time-zone UTC
set service ssh port 22

if ! commit; then
  echo "ERROR: Commit failed" >&2
  exit 1
fi

save
exit
```

Anything less than this structure is incomplete.

---

## 5. Avoid Premature Script Exits

In non-interactive scripts, `exit` inside a `configure` session will terminate
the script. If you need to continue after applying configuration, wrap the
configure block in a subshell:

```bash
(
  configure
  set system host-name edge01
  if ! commit; then
    echo "ERROR: Commit failed" >&2
    exit 1
  fi
  save
  exit
)

# Continue with non-configuration steps here.
```

If you do not need to continue after configuration, a standalone configure
block is fine.

---

## 6. Idempotency Requirements

EdgeOS `set` commands are **idempotent by default**.

Scripts **must** rely on this property and:
- Avoid manual state tracking
- Avoid conditional logic unless strictly necessary

Correct:
```bash
set system name-server 1.1.1.1
```

Unnecessary and discouraged:
```bash
if ! show configuration | grep 1.1.1.1; then
  set system name-server 1.1.1.1
fi
```

---

## 7. Bulk Configuration Handling

### Preferred: `load merge`

For large configurations:

```bash
configure
load merge /config/snippets/firewall.conf
commit
save
```

Use cases:
- Golden configs
- Baseline enforcement
- Disaster recovery

---

### Full replace (dangerous, use sparingly)

```bash
load /config/config.boot
```

Only allowed when:
- Rebuilding a device
- Performing full recovery

---

## 8. Remote Automation (SSH)

Remote configuration **must** preserve transaction boundaries.

Correct:
```bash
ssh admin@router <<'EOF'
configure
set system ntp server 1.pool.ntp.org
commit
save
exit
EOF
```

Incorrect:
```bash
ssh admin@router "set system ntp server 1.pool.ntp.org"
```

---

## 9. Commit Safety

### Use commit confirmation when modifying networking

```bash
commit-confirm 5
```

If connectivity is lost, EdgeOS will automatically roll back.

Always follow with:
```bash
confirm
save
```

---

## 10. Error Handling Rules

Scripts **must**:
- Check `commit` return codes
- Exit non-zero on failure
- Never continue after a failed commit

Pattern:
```bash
if ! commit; then
  echo "Commit failed" >&2
  exit 1
fi
```

---

## 11. Logging and Debugging

Recommended:
- Echo major stages
- Log commit failures
- Avoid excessive `set -x` unless debugging

Do not suppress errors.

---

## 11. What Not to Automate

Avoid scripting:
- Firmware upgrades
- Bootloader changes
- Hardware-specific calibration

These require manual validation.

---

## 12. Supported Tooling

The following tools are acceptable:
- SSH + here-docs
- Ansible (`raw` or `expect`)
- Provisioning scripts run on first boot

Not recommended:
- Expect-only workflows without validation
- Screen-scraping CLI output

---

## 13. Philosophy

EdgeOS configuration is **transactional, declarative, and stateful**.

Automation should:
- Declare desired state
- Let EdgeOS manage transitions
- Fail fast and visibly

If a script cannot be safely re-run multiple times, it is not finished.

---

**If you are unsure, default to safety over cleverness.**

