# RushResolve — Product Requirements Document

**Version:** 3.0
**Author:** Luis Arauz / KILA Strategies
**Date:** April 2026
**Status:** Active Development
**Audience:** Development team (internal). Not for hospital approval.

---

## Executive Summary

RushResolve is a portable PowerShell GUI toolkit for IT Field Services technicians at Rush University Medical Center. It consolidates common endpoint tasks — diagnostics, software deployment, printer management, disk cleanup, network troubleshooting — into a single tabbed interface that runs from a USB drive with no installation required.

The tool's core value is not just automation. It is the **discovery and execution layer** for institutional knowledge: scripts, workflows, and best practices that currently exist but that most technicians don't know about or know how to use.

---

## Problem Statement

17 FS technicians support ~10,000 devices across inpatient, outpatient, and administrative sites. Each workstation touch involves:

1. **Tool fragmentation** — Common tasks require switching between Device Manager, Network Connections, Command Prompt, vendor tools, and tribal knowledge scripts
2. **Knowledge silos** — The EUT team maintains scripts and SOPs that most FS techs don't know exist. Institutional knowledge is locked in individuals, not tools.
3. **Inconsistent outcomes** — Without standardized tooling, different techs approach the same problem differently
4. **Manual commands** — Most tasks are still solved by typing commands from memory, which is error-prone and slow
5. **Onboarding gap** — A new FS tech takes months to reach the skill level of a veteran; there is no structured way to transfer that knowledge

---

## Users

| Attribute | Value |
|-----------|-------|
| Team | Rush University Medical Center — IT Field Services |
| Count | 17 technicians |
| Permissions | All techs have identical permissions |
| AD rights | Add/remove devices, unlock accounts, move OUs, apply group memberships — cannot create OUs or memberships |
| Distribution | GitHub pull (`SecPrime8/RushResolve`) |
| Primary use | Running on end-user workstations during ticket resolution |

---

## Environment Constraints

| Constraint | Detail |
|------------|--------|
| GPO restrictions | WinGet blocked; DISM removed from tool (EUT deemed unsafe) |
| Windows Updates | Managed by hospital (WSUS/SCCM) — out of scope |
| VPN | Netskope — out of scope for RushResolve |
| AppLocker | Active; techs frequently encounter blocked installers |
| Network | M365 environment (SharePoint, Teams, OneDrive, Power BI available) |
| Script execution | No execution policy issues — techs can run `.ps1` files |
| PowerShell | 5.1 minimum; .NET 4.7.2+ required |
| Offline operation | Must work fully offline — no cloud dependencies for core features |

---

## Strategic Direction: Two-Tool Architecture

The current single-app model tries to serve two distinct contexts. The correct architecture is two separate tools:

### Tool 1: RushResolve USB (this document)
- **Runs on:** End-user's workstation
- **Purpose:** Diagnose, fix, install, collect data, document
- **Requirement:** No RSAT, no SCCM console, no admin prerequisites on the target machine
- **Deployment:** USB drive or network share

### Tool 2: RushResolve Desktop (future)
- **Runs on:** FS technician's own laptop
- **Purpose:** AD operations, SCCM actions, remote management, team reporting
- **Requirement:** RSAT installed, SCCM console available, domain admin tooling
- **Scope:** Account unlock, OU moves, group membership, device management, future gamification dashboard

### Tool 3: M365 Reporting Layer (future)
- **Purpose:** Telemetry from USB tool sessions uploaded to SharePoint/Power BI
- **Approach:** Uses existing M365 stack — no new ports, no new infrastructure
- **Value:** Management visibility into what techs are doing, adoption tracking, ticket time data

---

## Current State: RushResolve USB v2.6.0

### Module Inventory

| # | Module | Status | Notes |
|---|--------|--------|-------|
| 01 | System Info | Solid, needs polish | Button widths are static — text gets cut off. AD/SCCM buttons should be removed (they belong in the Desktop tool). |
| 02 | Software Installer | Works, rough | HPIA auto-configuration needed if not set up on USB. Batch install working. |
| 03 | Printer Management | Works, rough | **Pending research** — EUT has a server-side printer deployment system (see Open Questions). Current module adds printers directly to the endpoint. |
| 04 | Domain Tools | **Removed** | Cut — requires local admin as a prerequisite that the tool cannot obtain. Domain triage to be integrated as guided steps in a future module. |
| 05 | Network Tools | Solid, needs polish | WLAN report (`netsh wlan show wlanreport`) not yet accessible from UI. |
| 06 | Disk Cleanup | Rough | Needs rework. |
| 07 | Diagnostics | Works | SFC inline output working. DISM tools removed (EUT deemed unsafe). |
| 08 | AD Tools | **Moved to Desktop tool** | Cannot unlock accounts from the affected computer. USB slot to be replaced with AppLocker Troubleshooting. |

### Active USB Module Roster (v2.6.0 → next)
`01 System Info` | `02 Software Installer` | `03 Printer Management` | `05 Network Tools` | `06 Disk Cleanup` | `07 Diagnostics` | `08 AppLocker Troubleshooting` *(new)*

---

## Module Roadmap — USB Tool

### 01 System Info
**Polish needed:**
- All buttons need dynamic width sizing (AutoSize or calculated) — text is currently cut off
- Remove AD Tools and SCCM launcher buttons (move to Desktop tool)
- Retain: Device Manager, Task Manager, Event Viewer, Services, MSInfo32

### 02 Software Installer
**Polish needed:**
- HPIA: if not configured on USB, auto-detect or prompt with clear setup instructions
- Ensure installer scan handles deep subdirectories (already at `-Depth 5`)

### 03 Printer Management
**Polish needed:**
- Current: adds printers directly to endpoint (immediate effect)
- **Pending decision:** EUT system uses server-side config files (profile-based, applies on next login). May be superior for centralized management. Research needed before module is locked.
- Hold on major changes until EUT approach is evaluated

### 05 Network Tools
**Polish needed:**
- Add WLAN report button (`netsh wlan show wlanreport` → opens HTML report)
- Ensure Wi-Fi signal strength and SSID info is visible in UI

### 06 Disk Cleanup
**Needs rework:**
- Current implementation is rough
- Should cover: temp files, browser caches, Windows Update cache, Recycle Bin, error dumps, old logs, installer leftovers
- Large files scan: files not accessed in 90+ days, sortable by size

### 07 Diagnostics
**Status: Works**
- SFC inline output streaming is solid
- DISM tools removed entirely (EUT team deemed unsafe for field use)
- Quick Tools container height fixed (was clipping button borders)
- No major changes needed

### 08 AppLocker Troubleshooting *(new module — replaces AD Tools)*
**Planned scope:**
- Detect if an installer or app is blocked by AppLocker
- Launch Local Security Policy (`secpol.msc`) from within RushResolve
- Auto-generate AppLocker rules for all packaged apps on the computer
- Auto-generate AppLocker rules for installers in a specified folder
- Use case: field techs need to unblock installers blocked by AppLocker packaged app rules

---

## Out of Scope (USB Tool)

| Item | Reason |
|------|--------|
| Windows Updates | Managed by hospital WSUS/SCCM |
| VPN configuration | Netskope — separate system, separate team |
| User data backup/restore | FS is not responsible for user data |
| Domain rejoin prerequisite chain | LAPS retrieval and BitLocker key recovery require tools/access outside this app |
| Creating OUs or AD group memberships | Outside FS permission scope |
| AD account unlock | Must be done from tech's own machine (Desktop tool), not the locked-out computer |
| WinGet | Blocked by hospital GPO |

---

## Future Vision: Guided Workflow System (v3)

The long-term direction for RushResolve is to evolve from a toolbox into an **intelligent guided workflow system**:

- Decision trees that walk techs through every process step-by-step, not just buttons
- New FS techs reach 1-year veteran skill level within their first week
- Process updates pushed from a central server to all tech installations
- Cryptographic signatures on process updates — verifies who authored the change
- Integration with M365 (SharePoint) for telemetry and reporting without opening new network ports

This is a v3 architectural shift. Current work focuses on making the USB tool lean, polished, and demo-ready.

---

## Open Questions / Pending Research

| # | Question | Owner | Due |
|---|----------|-------|-----|
| 1 | **EUT Printer System** — EUT maintains a spreadsheet (computer hostname + printer columns, one column markable as default). A macro generates config files uploaded to a server. On a user's first login to that computer, a profile script reads the file and installs the mapped printers. Is this approach better than RushResolve's direct-add method? Should Module 03 integrate with it? | Luis | Monday 2026-04-07 |
| 2 | **Driver Management module** — List installed drivers, check for updates, bulk update or provide download links. Should this be Module 02 extension or a new module? | Luis/Claude | TBD |
| 3 | **EUT scripts inventory** — How many scripts exist, where do they live, who maintains them? Getting a full list would define what RushResolve should surface. | Luis | TBD |

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 0.1–2.0 | 2026-01-05 | Optimized Primate / Claude | Original PRD (wrong app name, v2.0 scope only) — archived in `RushResolveApp.bak/` |
| 3.0 | 2026-04-05 | Luis Arauz / KILA Strategies | Full rewrite based on requirements interview. Reflects v2.6.0 reality, two-tool strategy, lean USB focus. |
