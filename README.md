# Anso Statusline

A personal fork of [lucaslus/omarchy-statusline](https://github.com/lucaslus/omarchy-statusline) (v0.4.0): a native Omarchy Shell (Quickshell/QML + Python) system monitor for the bar. It runs under its own plugin ID, `anso.statusline`, so upstream updates never overwrite it.

## What this fork adds

- **All drives, not just `/`:** the `disk` metric expands to one bar entry per mounted drive (e.g. `SYS 168G · GAMES 663G · USB 0.9G`) showing free space, with a usage meter in the Default layout. Boot partitions are skipped; drives appear and disappear as they're mounted. The detail panel shows used / total / free for each.
- **Network speed** (`net`) with a 60-second sparkline.
- **Public IP** (`ip`) via api.ipify.org, refreshed every 5 minutes and when VPN links change.
- **VPN / ZeroTier status** (`vpn`): detects WireGuard, tun/tap and ZeroTier interfaces.
- Fix: bar metric order from `shell.json` arrives as a QML list, which upstream's `Array.isArray` check rejected; it is now copied correctly.

Everything else (CPU per-core bars, memory, per-GPU utilization and temperatures, disk I/O, theme-following colors, settings page) comes from upstream; see [docs/UPSTREAM_README.md](docs/UPSTREAM_README.md).

## Install

```bash
omarchy plugin add https://github.com/ansonysgithub/anso.statusline.git --enable --yes
```

Or clone it to `~/.config/omarchy/plugins/anso.statusline` and enable it from Omarchy's plugin settings. After editing files, run `omarchy restart shell` (hot reload can leave the widget stale).

## Configuration

Metrics and order live in the widget's entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "anso.statusline",
  "layout": "minimal",
  "metrics": ["cpu", "memory", "gpu", "heat", "disk", "vpn", "net", "diskio", "ip"]
}
```

Available metrics: `cpu`, `memory`, `gpu`, `heat`, `disk`, `diskio`, `net`, `vpn`, `ip`. When the bar runs out of room, metrics at the **end** of the list are hidden first, so put the ones you care about most up front.

## Requirements

- Omarchy with the Quickshell-based Omarchy Shell
- Python 3.11+ (standard library only)
- Optional: `nvidia-smi` for NVIDIA telemetry; `iproute2` (`ip`) for VPN detection

## Development

```bash
python3 collector.py --once          # one JSON sample
python3 -m unittest discover -s tests -v
python3 scripts/test-qml.py          # native QML tests (needs an Omarchy session)
```

## Credits and license

Based on [omarchy-statusline](https://github.com/lucaslus/omarchy-statusline) by lucas. MIT licensed; see [LICENSE](LICENSE). Screenshots in `docs/images` are from upstream.
