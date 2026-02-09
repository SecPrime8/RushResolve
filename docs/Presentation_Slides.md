# RushResolve Presentation Deck
**Field Services Efficiency Toolkit**

---

## Slide 1: Title
**RushResolve: Field Services Toolkit**
Standardizing and Accelerating IT Support at RUMC

*Luis Amador | Field Services*

---

## Slide 2: The Problem - Time Waste
**Field Techs Are Tool Juggling**

*Visual: Screenshot of multiple windows open (AD Users & Computers, Print Management, Computer Management, CMD, Event Viewer)*

Current Reality:
- Open Print Management → Browse servers → Find printer → Install
- Open AD Users & Computers → Navigate OU structure → Find computer → Check status
- Open Event Viewer → Filter logs → Export → Send to email
- Open CMD → Run ipconfig → Run ping → Run nslookup

**Result:** 5+ tools for routine tasks, constant context switching

---

## Slide 3: The Problem - Inconsistent Quality
**17 Techs, 17 Different Approaches**

Scenario: "Computer can't join domain"

- **Tech A:** Checks DNS, reboots, retries
- **Tech B:** Resets computer account in AD, clears cache, retries
- **Tech C:** Re-images immediately
- **Tech D:** Calls escalation

**Which one is right?** 🤷

**Result:** Inconsistent outcomes, difficult troubleshooting, repeated work

---

## Slide 4: The Problem - Training Burden
**New Techs Need Months to Get Up to Speed**

Training Requirements:
- Shadow experienced techs for 2-4 weeks
- Learn "tribal knowledge" (undocumented workarounds)
- Memorize tool locations and workflows
- Understand Rush-specific configurations

**Result:** Slow onboarding, productivity lag, increased errors during ramp-up

---

## Slide 5: The Solution - RushResolve Overview
**One Tool, All Workflows**

*Visual: Screenshot of RushResolve main window with tabs*

**What is RushResolve?**
A unified PowerShell toolkit that consolidates field service workflows into one standardized application.

**Key Features:**
- System Info & Diagnostics
- Printer Management
- Domain & AD Tools
- Network Troubleshooting
- Disk Cleanup
- HP Driver Management

---

## Slide 6: Feature Spotlight - Printer Management
**Before vs After**

**Before RushResolve:**
1. Open Print Management
2. Connect to print server
3. Browse printer list (wait for load)
4. Right-click → Install
5. Open Control Panel → Set default
6. Right-click → Print test page

**With RushResolve:**
1. Open RushResolve → Printers tab
2. Select server (instant browse)
3. Click "Install" + "Set Default" + "Test Page"
4. Done.

**Time Saved:** ~3-4 minutes per printer installation

---

## Slide 7: Feature Spotlight - Domain Tools
**Standardized Domain Troubleshooting**

*Visual: Screenshot of Domain Tools tab*

**Common Issue:** "Computer can't reach domain controller"

**RushResolve Workflow:**
1. Click "Check DC Connectivity" → Instant results for all DCs
2. If trust broken → Click "Repair Trust"
3. If that fails → Click "Rejoin Domain" (automated with credential prompt)

**Result:** Consistent resolution path, no guesswork, built-in escalation logic

---

## Slide 8: Feature Spotlight - Diagnostics
**Proactive System Health Checks**

*Visual: Screenshot of Diagnostics findings list*

**Automated Checks:**
- Event log errors (Kernel-Power crashes, disk errors, BSODs)
- Storage health (low disk space, SMART warnings)
- Memory issues
- Driver problems
- Thermal throttling
- Battery health (laptops)
- HP driver updates (HPIA integration)

**Output:** Color-coded findings (Critical/Warning/OK) with recommendations

---

## Slide 9: Security & Compliance
**Built for Healthcare IT**

**Security Features:**
- **Module Integrity:** SHA256 hash verification prevents tampering
- **Audit Logging:** Full session logs (who, what, when)
- **No External Dependencies:** Uses only built-in Windows tools
- **No Patient Data Access:** System administration only, no PHI touched
- **Code Transparency:** Full source code available for Cybersecurity review

**Compliance:**
- HIPAA-safe (no PHI access)
- No installation required (runs from USB)
- No cloud connectivity (fully local)

---

## Slide 10: Technical Architecture
**How It Works**

*Visual: Simple diagram*

```
┌─────────────────────────────────────────┐
│         RushResolve.ps1 (Launcher)      │
└─────────────────────────────────────────┘
                    │
        ┌───────────┴───────────┐
        │   Module Verifier     │
        │   (SHA256 Checks)     │
        └───────────┬───────────┘
                    │
    ┌───────────────┼───────────────┐
    │               │               │
┌───▼───┐     ┌────▼────┐    ┌────▼────┐
│Module │     │Module   │    │Module   │
│  01   │     │   02    │    │   08    │
│System │     │Software │    │   AD    │
│ Info  │     │Install  │    │  Tools  │
└───────┘     └─────────┘    └─────────┘
```

**Key Points:**
- Modular design (easy to add features)
- PowerShell 5.1 compatible (works on all Windows 10/11)
- Session logging to local JSON files
- No admin rights required for most functions

---

## Slide 11: Portability & Deployment
**USB Drive Ready**

**No Installation Required:**
- Copy folder to USB drive
- Run `RushResolve.ps1`
- All tools work immediately

**Why This Matters:**
- No IT approval process for software installation
- Works on any Windows 10/11 machine
- Can be updated centrally (share drive deployment)
- Techs can carry their toolkit everywhere

**Deployment Options:**
1. USB drives (current)
2. Network share (future)
3. SCCM package (future, if needed)

---

## Slide 12: Benefits Summary
**What We Gain**

| Benefit | Impact |
|---------|--------|
| **Faster Resolution** | Consolidated workflows = fewer clicks, less time per ticket |
| **Consistent Quality** | Standardized processes = predictable outcomes |
| **Easier Training** | New techs follow guided workflows, less tribal knowledge |
| **Audit Trail** | Session logs provide accountability and troubleshooting history |
| **Extensibility** | Platform for future automation from other departments |

---

## Slide 13: The Vision - Cross-Department Collaboration
**More Than a Tool - It's a Platform**

**Future Collaboration Opportunities:**

**Cybersecurity:**
- Automated compliance checks built into field workflows
- BitLocker status verification on every service call
- Security baseline validation

**End-User Technologies:**
- Standardized software deployment procedures
- Configuration drift detection

**Networking/Telecoms:**
- Automated network diagnostics
- VoIP troubleshooting workflows

**Result:** Field techs become execution layer for other departments' automation needs

---

## Slide 14: Roadmap & Next Steps
**Getting to Full Deployment**

**Phase 1: Security Review** (1-2 weeks)
- Cybersecurity code audit
- Security model validation
- Address any concerns

**Phase 2: Pilot Deployment** (2 weeks)
- Deploy to 5 volunteer techs
- Gather feedback and metrics
- Refine workflows

**Phase 3: Full RUMC Rollout** (1 week)
- Deploy to all 17 field service techs
- Training session (1 hour)
- Ongoing support

**Phase 4: Future Enhancements** (Ongoing)
- Collaborate with other IT departments
- Build requested automation features
- Expand to Copley and Rush Oak Park (if successful)

---

## Slide 15: The Ask
**What We Need**

1. **Approval** to deploy RushResolve to all 17 RUMC field service technicians

2. **Cybersecurity Collaboration** to review and validate security model

3. **Future Partnership** with End-User Technologies, Networking, and Telecoms to identify automation opportunities

**Ownership:** Luis Amador (Field Services) - open to departmental ownership transition

---

## Slide 16: Questions & Discussion

**Contact Information:**
Luis Amador | Field Services | RUMC IT

**Resources Available:**
- Full source code for review
- Technical documentation
- Demo/walkthrough available

---

## Appendix: Feature List (Reference Slide)

**Module 01 - System Information**
- Hardware specs, BIOS info, OS details
- Disk space, network adapters, installed software

**Module 02 - Software Installer**
- Pre-packaged software deployments
- Silent install capabilities

**Module 03 - Printer Management**
- Browse print servers
- Install/remove printers
- Test page, clear queues
- Set default printer

**Module 04 - Domain Tools**
- Trust relationship status
- DC connectivity checks
- Domain rejoin automation

**Module 05 - Network Tools**
- Ping, traceroute, DNS lookup
- IP configuration
- Connectivity troubleshooting

**Module 06 - Disk Cleanup**
- Temp files, Windows Update cleanup
- Recycle Bin, log files
- Safe cleanup with preview

**Module 07 - Diagnostics**
- Event log analysis
- Storage health (SMART)
- Memory diagnostics
- Driver issue detection
- Thermal monitoring
- Battery health (laptops)
- HP driver updates (HPIA)

**Module 08 - Active Directory Tools**
- User account management
- Computer account management
- Group membership
- Account unlock/password reset
- No RSAT required (uses ADSI)

---

## Appendix: Security Technical Details (Reference Slide)

**Module Verification Process:**
1. On startup, RushResolve reads `Security/module-manifest.json`
2. Calculates SHA256 hash of each module file
3. Compares to stored hash
4. Blocks execution if hash mismatch
5. Logs verification results

**Session Logging:**
- All actions logged to `Logs/Sessions/YYYY-MM-DD_HHMMSS.json`
- Includes: timestamp, user, computer, module, action, result
- Read-only access for audit purposes

**Privilege Model:**
- Most functions run with user privileges
- Admin-required functions prompt for elevation (UAC)
- No persistent elevation

**Code Signing (Future):**
- Can be signed with organization code signing certificate
- Would prevent any modifications without re-signing
