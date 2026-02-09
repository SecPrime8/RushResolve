# RushResolve Demo Script
**Walkthrough Guide for Presentations and Training**

---

## Pre-Demo Setup (5 minutes before)

**Prerequisites:**
- Windows 10/11 laptop or workstation
- RushResolve USB drive or network folder access
- Domain-joined computer (for AD/Domain features)
- Access to print server (for printer demo)
- Projector or screen share ready

**Setup Steps:**
1. Copy RushResolve folder to Desktop (if not running from USB)
2. Close any open PowerShell or admin windows
3. Have a test printer path ready: `\\PRINTSERVER\[PRINTER_NAME]`
4. Know your domain controller name
5. Open File Explorer to RushResolve folder (ready to launch)

**What NOT to demo:**
- Don't use production systems if doing destructive tests (disk cleanup, domain rejoin)
- Don't show real user accounts or sensitive AD data
- Don't test on critical servers or infrastructure

---

## Demo Flow (15-20 minutes total)

### Part 1: Launch & Overview (2 minutes)

**Narration:**
> "RushResolve is our new field services toolkit. Instead of opening 5-6 different tools, everything is in one place. Let me show you how it works."

**Actions:**
1. Navigate to RushResolve folder on Desktop
2. Right-click `RushResolve.ps1` → Run with PowerShell
3. **(Point out)** Console window shows module verification
   - "See these hash checks? That's security built-in. If anyone modifies the code, it won't load."
4. Application window opens → Show the tabs across the top

**Talking Points:**
- "8 modules covering our most common workflows"
- "Runs from USB drive - no installation needed"
- "Uses only built-in Windows tools - nothing to download"

---

### Part 2: System Information (2 minutes)

**Narration:**
> "First tab is System Info. When you arrive at a ticket, you need to know what you're working with. This gives you everything instantly."

**Actions:**
1. Click **System Information** tab
2. Scroll through the information displayed:
   - Computer name, domain, manufacturer
   - Serial number (highlight: "This is auto-captured for warranty checks")
   - OS version, RAM, CPU
   - Disk space breakdown
   - Network adapters

**Talking Points:**
- "Notice the serial number - we can use this for HP warranty lookups"
- "Disk space shows C: and D: drives immediately - helps diagnose slowness"
- "All this info without opening msinfo32, Computer Management, or Control Panel"

**Demo Enhancement (Optional):**
- Show the Battery Report section if on a laptop
  - "This tells you if a laptop battery needs replacement"

---

### Part 3: Printer Management (4 minutes)

**Narration:**
> "Printer issues are one of our most common tickets. Let's walk through installing a printer the RushResolve way versus the old way."

**Traditional Way (Narrate, don't show):**
1. Open Print Management
2. Wait for it to load
3. Connect to print server
4. Browse printer list (wait for load)
5. Right-click printer → Connect
6. Open Control Panel → Devices and Printers
7. Right-click → Set as Default
8. Right-click → Printer Properties → Print Test Page

**RushResolve Way (Show live):**
1. Click **Printer Management** tab
2. Enter print server name (or select from dropdown if you've pre-configured)
3. Click **"Browse Server"**
   - "See how fast this loads? No waiting."
4. Select a printer from the list
5. Click **"Install"**
   - "Installs for all users automatically. No checkbox confusion."
6. **(Optional)** Click **"Set Default"**
7. **(Optional)** Click **"Test Page"**
   - "One click test page. No navigating menus."

**Talking Points:**
- "This takes ~30 seconds. The old way took 3-4 minutes."
- "Every tech follows the same steps now. No more 'how did you install this?'"
- "Left side shows installed printers - can clear queues or remove from here too"

---

### Part 4: Domain Tools (3 minutes)

**Narration:**
> "Domain connectivity issues are tricky. Different techs had different approaches. Now we have a standardized workflow."

**Scenario:**
> "User says 'I can't log in, it says domain unavailable.' Here's how we troubleshoot."

**Actions:**
1. Click **Domain Tools** tab
2. Click **"Check DC Connectivity"** (top section)
   - Shows list of domain controllers with ping results
   - "Green check = reachable, Red X = unreachable"

**Talking Points:**
- "If all DCs are reachable, problem isn't network"
- "If all are unreachable, check physical network"
- "If some are down, we know which DC is having issues"

**Actions (continued):**
3. Click **"Check Trust Relationship"** (middle section)
   - "This checks if the computer's domain trust is broken"
   - If broken: "We can click 'Repair Trust' to fix without rejoining"

4. **(Don't actually run unless safe)** Show **"Rejoin Domain"** button (bottom section)
   - "Last resort: This automates the domain rejoin process"
   - "Used to require manually removing from AD, rebooting, re-adding. Now it's automated."

---

### Part 5: Diagnostics (4 minutes)

**Narration:**
> "Users report 'my computer is slow' or 'it keeps freezing.' We need to find the root cause. Diagnostics does a full health check."

**Actions:**
1. Click **Diagnostics** tab
2. Click **"Full Diagnostic"** button
3. Watch the progress bar as it runs through checks:
   - Event Logs (crashes, errors)
   - Storage (disk space, SMART warnings)
   - Memory
   - Drivers
   - Thermal (overheating)
   - Stability
   - Resources
   - Battery (if laptop)
   - HP Drivers (if HP machine)

**Narration (while running):**
> "This is checking 7-8 different areas automatically. Event logs, storage health, memory, drivers, thermals. Things that used to take 15 minutes manually."

**Actions (after completion):**
4. Show the findings list
   - Color-coded: Red = Critical, Yellow = Warning, Green = OK
5. Click on a finding to see details
   - "See the recommendation? It tells techs exactly what to do."

**Example Findings (improvise based on actual results):**
- **Critical:** "10 unexpected shutdowns detected" → "Check power supply and thermals"
- **Warning:** "Disk space low on C:" → "Run Disk Cleanup"
- **OK:** "No memory issues detected"

**Talking Points:**
- "This gives us a starting point for troubleshooting"
- "New techs know exactly what to check, no guessing"
- "Findings are color-coded - reds need immediate attention"

---

### Part 6: Network Tools (2 minutes)

**Narration:**
> "Quick demo of network troubleshooting. This consolidates ping, tracert, nslookup, and ipconfig."

**Actions:**
1. Click **Network Tools** tab
2. **Ping Test:**
   - Enter a hostname or IP (e.g., `google.com` or `8.8.8.8`)
   - Click **"Ping"**
   - Results show immediately: reachable or not, response time

3. **DNS Lookup:**
   - Enter a hostname (e.g., `rush.edu`)
   - Click **"DNS Lookup"**
   - Shows IP address resolution

**Talking Points:**
- "No more opening CMD and typing commands"
- "Results are formatted clearly"
- "Traceroute option shows network path (useful for off-site issues)"

---

### Part 7: Active Directory Tools (2 minutes)

**Narration:**
> "AD Tools module is special - it doesn't require RSAT. Uses built-in .NET libraries."

**Actions:**
1. Click **AD Tools** tab
2. Show the two sections: **Users** and **Computers**
3. **Search for a user:**
   - Enter a test username (yours or a known test account)
   - Click **"Search Users"**
   - User info displays: Name, Email, Account Status, Last Logon

4. **(Optional)** Show **"Unlock Account"** or **"Enable Account"** buttons
   - "These are single-click operations. No navigating AD Users & Computers."

**Talking Points:**
- "No RSAT required - works on any Windows 10/11 machine"
- "Common AD tasks techs need: unlock accounts, check computer status"
- "Read-only for most ops, write ops require admin rights"

---

### Part 8: Security & Logging (1 minute)

**Narration:**
> "Everything you do in RushResolve is logged. Full audit trail."

**Actions:**
1. Open File Explorer to `RushResolve\Logs\Sessions\`
2. Show the JSON log file for current session
3. Open in Notepad (or show in File Explorer preview)
   - Point out: timestamp, user, action, result

**Talking Points:**
- "Every action logged: who, what, when"
- "Helps troubleshoot: 'What did the last tech do?'"
- "Security likes this - full accountability"

---

### Part 9: Wrap-Up & Benefits (2 minutes)

**Narration:**
> "So that's RushResolve. Let me summarize what we gain."

**Recap:**
1. **Faster:** One tool instead of many, workflows optimized
2. **Consistent:** Every tech follows the same steps
3. **Easier to Learn:** New techs productive faster, guided workflows
4. **Auditable:** Full logging for compliance and troubleshooting
5. **Secure:** Hash verification, no external dependencies
6. **Portable:** USB drive or network share, no installation

**The Vision:**
> "This is just the beginning. As other IT departments want field techs to do standardized tasks - compliance checks, security baselines, automated deployments - we can build it into RushResolve. It becomes a platform for IT-wide automation."

---

## Q&A Preparation

**Expected Questions:**

**Q: "What if a tech needs a feature that's not there?"**
A: "We're actively developing. That's why we want feedback from the pilot. We can add modules based on actual needs."

**Q: "How do updates work?"**
A: "If deployed from network share, we update one location and all techs get it. If USB drives, we collect and re-flash. Considering SCCM deployment for automatic updates."

**Q: "What about security? Can techs modify the code?"**
A: "Hash verification prevents running modified code. If anyone changes a module, it won't load. We can also implement code signing for extra protection."

**Q: "Does this work without network connectivity?"**
A: "Mostly yes. System info, diagnostics, disk cleanup work offline. Domain and AD tools obviously need network. Printer management needs connection to print servers."

**Q: "What if PowerShell execution policy blocks it?"**
A: "We recommend RemoteSigned policy. Allows local scripts but requires signature for downloads. We can implement code signing if needed."

**Q: "How long did this take to build?"**
A: "About [X weeks] of development. Built it because our techs needed it - no commercial tool did exactly what we wanted."

**Q: "What about training?"**
A: "Interface is intuitive - most techs pick it up in 15-30 minutes. We'll do a 1-hour training session at rollout, then it's available as needed."

**Q: "Can we customize it for our workflows?"**
A: "Absolutely. That's the advantage of owning the code. If End-User Tech wants a specific check, we build it in. If Cybersecurity wants a compliance module, we add it."

**Q: "What's the maintenance burden?"**
A: "Minimal. PowerShell is stable, Windows tools don't change often. Bug fixes and feature adds are on-demand. I own it, but open to departmental ownership."

---

## Demo Tips

### Do's:
- **Practice first:** Run through the demo 2-3 times before presenting
- **Keep it moving:** Don't dwell on one module too long
- **Show real results:** Use actual printer servers, domain controllers, etc.
- **Highlight time savings:** "This used to take 5 minutes, now it's 30 seconds"
- **Address security proactively:** Don't wait for them to ask

### Don'ts:
- **Don't troubleshoot live:** If something breaks, say "I'll follow up" and move on
- **Don't show bugs:** If you know a feature is buggy, skip it
- **Don't over-technical:** Execs don't care about SHA256 algorithms, they care about "secure"
- **Don't promise features:** "We're considering" not "We'll definitely add"
- **Don't bad-mouth existing tools:** "Consolidates workflows" not "Current tools suck"

### Technical Difficulties:
- **App won't start:** Have backup - screen recording video of the demo
- **Network issues:** Demo offline features (System Info, Diagnostics)
- **Permissions denied:** Use a test VM or laptop where you have admin rights

---

## Video Recording Script (If Pre-Recording)

**Opening (5 seconds):**
[Screen: RushResolve folder on Desktop]
Voiceover: "Introducing RushResolve - the field services toolkit that consolidates IT workflows into one application."

**Launch (10 seconds):**
[Screen: Launch RushResolve.ps1, show console window with hash checks]
Voiceover: "Runs from USB drive with built-in security - hash verification ensures code integrity."

**Feature Montage (90 seconds):**
[Quick cuts between tabs, showing key features]
- System Information → "Instant hardware and software overview"
- Printer Management → "Install printers in 3 clicks"
- Domain Tools → "Diagnose connectivity issues automatically"
- Diagnostics → "Full system health check in 30 seconds"
- Network Tools → "Ping, DNS, traceroute - all in one place"
- AD Tools → "Active Directory management without RSAT"

**Benefits (15 seconds):**
[Screen: Side-by-side comparison graphic]
- Before: "5+ tools, 5+ minutes, inconsistent results"
- After: "1 tool, 30 seconds, standardized process"

**Closing (10 seconds):**
[Screen: RushResolve logo or contact info]
Voiceover: "Faster, consistent, auditable. RushResolve - built by techs, for techs."

**Total Runtime:** ~2 minutes

---

## Post-Demo Follow-Up

After demo, provide:
1. **Executive Brief PDF** (email to attendees)
2. **Link to documentation** (if available)
3. **Pilot sign-up sheet** (for volunteer techs)
4. **Cybersecurity review packet** (if security team attended)

**Next Steps Email Template:**

```
Subject: RushResolve Demo Follow-Up - Next Steps

Hi [Name],

Thanks for attending the RushResolve demo today. As discussed, here are the next steps:

1. Cybersecurity Review (1-2 weeks)
   - Code audit and security validation
   - [Contact Name] from Cybersecurity will coordinate

2. Pilot Deployment (2 weeks)
   - 5 volunteer field techs will test in production
   - Gather feedback and metrics

3. Full RUMC Rollout (1 week after successful pilot)
   - Deploy to all 17 field service technicians
   - 1-hour training session

Attached:
- Executive Brief (1-page overview)
- Security Review Documentation (for Cybersecurity team)
- Demo Script (for reference)

Let me know if you have questions or need additional information.

Thanks,
Luis Arauz
Field Services | RUMC IT
```

---

## Appendix: Backup Demo Plan (If Technical Issues)

**If RushResolve won't start:**
1. Have a pre-recorded video ready (2-3 min walkthrough)
2. Show screenshots instead of live demo
3. Walk through the features conceptually with slides

**If network is down:**
1. Demo offline features only:
   - System Information
   - Disk Cleanup (preview mode)
   - Diagnostics (will show some results)
2. Explain network features conceptually
3. Offer follow-up demo when network available

**If projector fails:**
1. Have printed screenshots in handout format
2. Walk through features verbally with Executive Brief as guide
3. Offer individual desktop demos after meeting
