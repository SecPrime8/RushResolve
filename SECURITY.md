# RushResolve Security Documentation

## Risk Acceptance Decisions

### PIN Complexity (Accepted Risk)

**Finding:** 6-digit numeric PIN has only 1 million possible combinations, theoretically brute-forceable.

**Decision:** Accepted as low risk given operational context.

**Rationale:**
- **Time-limited value** - Admin password rotates every ~24 hours. Even if PIN is brute-forced offline, the decrypted credential is likely expired.
- **Physical possession required** - Encrypted credential file stays on technician's thumb drive. Attacker must first obtain physical access.
- **Operational necessity** - Field technicians need quick access during service calls. Complex passwords would impede workflow.
- **Defense in depth** - 10,000 PBKDF2 iterations + AES-256 encryption + daily rotation + physical security provides acceptable protection for the use case.

**Date:** 2026-01-28

---

## Bundled Dependencies

### QRCoder.dll v1.4.3

- **Source:** NuGet (https://www.nuget.org/packages/QRCoder/1.4.3)
- **Target Framework:** .NET Framework 4.0
- **SHA256:** `561ACFE4B1A14C837B189FB9FC5C6D3E82440184BBDE61912DE723D62D6368B3`
- **Location:** `Lib/QRCoder.dll`
- **Verification:** Hash checked at runtime before loading

---

## Security Architecture

### Credential Protection
- AES-256 encryption with PBKDF2 key derivation (10K iterations)
- PIN-protected with 3-attempt lockout in UI
- 15-minute session timeout requires re-authentication
- Clipboard auto-clear after 30 seconds

### Module Loading
- Allowlist-based module validation
- Hash verification of module files
- Security modes: Enforced (block untrusted) / Warn / Disabled

### Network Security
- Printer path allowlist restricts to approved print servers
- Software installation restricted to approved network shares

---

## Known Issues & Remediation Plan

See audit findings and remediation plan in project documentation.
