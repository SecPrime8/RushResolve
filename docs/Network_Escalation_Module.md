# Network Escalation Module (Module 09)

**Purpose:** give the Networking team everything they need on the first
handoff, so a ticket does not bounce back asking for the switch port, the
MAC address, or "did you try a known-good cable".

Field Services is required to collect this information. This module means a
tech does not have to remember which commands produce it.

---

## For the technician: the four-click workflow

1. **Fill in the ticket and location boxes.**
   The **Wall jack ID** field is highlighted for a reason - it is how
   Networking finds the switch port. If the faceplate has a label, put it in.

2. **Pick the symptom, tick what you already verified.**
   The checklist is the list of questions Networking would otherwise have to
   ask you. Ticking them honestly is what keeps the ticket moving. If a
   specific server or app is unreachable, put it in **Affected target**.

3. **Click "Collect Escalation Packet".** Takes about 20-30 seconds.
   If "Switch/port info (LLDP)" is ticked you will be prompted once for
   admin credentials - that query needs them.

4. **Click "Copy for Ticket"** and paste into the ticket before assigning
   to Networking.

Use **Copy Short Summary** instead when you just need a few lines for a
Teams message or a phone handoff. Use **Save Report** to drop a `.txt` copy
into the `Logs` folder.

---

## What the packet contains

| Section | Contents |
|---|---|
| 1. Ticket and location | Ticket, site, room, wall jack, asset tag, reporter |
| 2. Symptom | Symptom, how many affected, when it started, port light state |
| 3. Already verified | The Field Services checklist, ticked or unticked |
| 4. Device identity | Hostname, FQDN, make/model, serial, OS build, uptime |
| 5. Adapters | Per adapter: link state, speed, duplex, MAC, IP/mask, gateway, DNS, DHCP server and lease times. The adapter carrying the default route is marked PRIMARY |
| 6. Switch and port | LLDP: switch name, chassis ID, management IP, port ID, port description, VLAN |
| 7. Wireless | SSID, **BSSID (the AP radio MAC)**, channel, band, signal, radio type, auth and cipher |
| 8. Reachability | Pass/fail for loopback, own IP, gateway, each DNS server, domain resolution and the affected target |
| 9. Traceroute | Path to the affected target, 15 hops max |
| 10. Domain | Domain, secure channel health, logon server, AD site |
| 11. Proxy and VPN | WinHTTP proxy, user proxy, PAC URL, VPN adapters present |
| 12. ARP neighbors | Layer 2 neighbors, to confirm the device is on the expected VLAN |
| 13. Appendix | Raw `ipconfig /all` and `route print` |

The packet also raises explicit flags that save the Networking team a
triage step, for example:

- **APIPA address** - link is up but DHCP never answered on this VLAN.
- **Gateway does not answer** - traffic is not leaving the access port, or
  the port is in the wrong VLAN.
- **Gateway answers but the target does not** - points at routing, an ACL
  or a firewall rule rather than the access port.
- **Wireless signal below 40 percent** - a coverage problem, not a
  configuration problem.

---

## Look Up Device by IP

Answers "I have an IP, what is the MAC?" for printers, cameras, medical
devices and anything else on the network.

Enter the IP and click **Look Up** (or press Enter). It returns the MAC
address, a vendor hint, the cache state, reverse DNS, and a short service
port fingerprint - port 9100 open, for instance, means it is almost
certainly a printer. If ICMP is blocked it makes a TCP connection attempt
first to force the ARP exchange, so it still works against devices that
drop ping.

**The important part:** MAC addresses do not cross a router. If the IP you
enter is not on this PC's subnet, the tool says so and tells you what to do
instead (ask Networking for the ARP table on that VLAN gateway, or check
the DHCP lease). Without that warning it is easy to report the router's MAC
as the device's - the single most common mistake in this workflow.

---

## Vendor lookup (optional one-time setup)

The module ships with a small built-in table covering virtual NIC vendors
and a few unambiguous prefixes. It deliberately does not guess: an
incorrect vendor is worse than "Unknown".

Two things it always reports correctly without any setup:

- **Multicast / broadcast addresses**, which are not device NICs.
- **Locally administered (randomized) MACs.** Modern phones, tablets and
  laptops randomize their Wi-Fi MAC per SSID by default. The MAC you
  capture may not match the hardware label and can change over time. If
  MAC-based allowlisting is in play, the user must turn off "Private Wi-Fi
  address" (iOS) or "Random hardware addresses" (Windows) for that SSID.

For full vendor coverage, load the IEEE registry once:

1. Download the **MA-L CSV** from <https://standards-oui.ieee.org/>.
2. Click **Import OUI File** and select it.

It is copied to `Config\oui.csv` and used for every lookup from then on.
The file is data only - it is never fetched automatically, so this works in
environments with no outbound internet access.

---

## Requirements and limits

- **LLDP (section 6) needs two things:** local admin, and the Data Center
  Bridging feature installed. Run **Network Tools -> Setup LLDP** once per
  tech laptop; it requires a reboot the first time. Without it the packet
  still collects everything else and tells Networking to identify the port
  from the MAC address and wall jack instead.
- LLDP data can take 30-60 seconds to arrive after the cable is connected.
  If the first attempt reports no data, wait and re-collect.
- LLDP is skipped when the primary adapter is wireless; section 7 carries
  the BSSID, which is the wireless equivalent.
- Section 12 only sees the local broadcast domain, by design.

---

## Notes for maintainers

- All logic lives in `$script:NE_*` script blocks. Modules are dot-sourced
  **inside** the loader function, so plain `function` definitions would go
  out of scope the moment the module finishes loading.
- The `NE_` prefix avoids collisions with `05_NetworkTools.ps1`, which
  defines similarly named script blocks in the same script scope.
- LLDP collection is duplicated rather than reused from Module 05 on
  purpose: this module must not break if Module 05 fails its hash check or
  is removed.
- Core dependencies (allowed): `Invoke-Elevated`, `Get-ElevatedCredential`,
  `Test-IsElevated`, `Write-SessionLog`, `Start-AppActivity`,
  `Clear-AppStatus`, `Set-AppError`, `$script:LogsPath`,
  `$script:ConfigPath`, `$script:AppVersion`. Every optional one is guarded
  with `Get-Command`.
- Output is ASCII only, matching the rest of the app.
- After editing this module, re-run `Update-SecurityManifests` (or update
  `Security/module-manifest.json`) or it will be blocked in Enforced mode.
