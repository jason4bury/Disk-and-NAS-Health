# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with versions numbered
`<major>.<minor>` and a two-digit minor (v1.00, v1.01 ... v1.10) to match the release folder names.

## [Unreleased]

## [1.02] - 2026-11-23
### Added
- **Other drives** tab beside NAS: how full the drives elsewhere are. Network drives mapped on this PC appear by
  themselves (drives that are shares of one disk on the same machine share a card), and shared folders on other
  PCs can be listed in Settings (such as `\\OFFICE-PC\D`; Windows shares, or Linux with Samba), with
  **Add folder...** and **Remove folder...**. Free space only, with the same warning levels; one that can't be
  reached shows as Offline. Copy report includes them.

## [1.01] - 2026-11-17
### Changed
- The main script is now `Disk-and-NAS-Health.ps1`, matching the folder name.
- The repo and folder are now `Disk-and-NAS-Health`, matching the AppName. Old GitHub links redirect.

## [1.00] - 2026-11-17
First release.

### Added
- **This PC tab**: free space on every fixed and removable drive, with a bar that turns amber and red below the warning and problem levels.
- **Physical disks**: model, NVMe/SATA/USB, SSD or HDD, size, drive letters and Windows' health verdict for each disk. Run as administrator to add temperature, wear, power-on hours and uncorrected error counts. A **Run as administrator** button restarts it elevated.
- **A tab for each NAS**, read over SSH with your key: DSM version, uptime, load, memory and temperature; free space on each volume; RAID state from `/proc/mdstat` (healthy, degraded, rebuilding with time left, data scrubbing); and each disk's SMART health from `smartctl` (overall result, temperature, power-on hours, reallocated, pending and uncorrectable sectors, CRC errors, NVMe wear and media errors).
- **Biggest folders**: measure any folder on this PC (a fast read-only scanner, five levels kept so going in and out is instant, with the largest files underneath) or on a NAS (`du` over SSH). Double-click to go in, Up or Backspace to go back, Stop to end a scan early, right-click for Open in Explorer and Copy path.
- **Summary line** under the title (green, amber or red), a coloured dot on every tab and a list of warnings and problems at the top of each tab.
- **Copy report**: a plain-text summary of everything on the clipboard.
- **Settings**: NAS machines (name, SSH login, port) with **Test connection**, copied the first time from Homelab or Docker Container Manager; free-space and temperature levels; automatic re-check every 15 minutes (or never); Auto, Light or Dark theme.
- **Help** (F1) explains every part, including the one-line sudo rule that lets the NAS share SMART over SSH.
- Read only throughout: nothing is written to any disk, here or on the NAS. Settings and the log live in `%APPDATA%\Disk and NAS Health`.
- No exe: `Disk and NAS Health.cmd` makes a shortcut in the release folder and the Start menu, and Build.cmd makes `Builds\Disk and NAS Health.lnk` for the Home Launcher.
