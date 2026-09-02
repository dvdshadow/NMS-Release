# NMS installers

One-shot install scripts that turn this repository into a runnable private
server on your machine, including **Spire** (EQEmu's web admin / content editor
and process launcher).

They follow the same overall flow as Akkadius's classic EQEmu installer and the
modern Spire `eqemu-server-installer`, but they use **this** tree instead of
stock PEQ binaries/quests:

| Piece | Source |
| --- | --- |
| Server source / binaries | `Release-NMS-Server/` (compiled locally) |
| Database | `Release-NMS-Server/database/release-peq.zip` |
| Quests | `Release-NMS-Quests/` |
| Plugins | `Release-NMS-Plugins/` |
| Maps | [EQEmu/maps](https://github.com/EQEmu/maps/releases) (~1 GB) |
| Spire | [EQEmu/spire](https://github.com/EQEmu/spire/releases) |

The runtime layout Spire expects (`bin/`, `quests/`, `maps/`, `eqemu_config.json`,
`login.json`, …) is created under a dedicated install directory (default
`~/nms-server` on Linux, `%USERPROFILE%\nms-server` on Windows).

---

## Linux

### Requirements

- Debian/Ubuntu or RHEL/Fedora-family
- `sudo` for the first run (packages + MariaDB)
- Several GB free disk (maps alone are ~1 GB; build artifacts more)

### Run

From the repository root:

```bash
chmod +x install.sh install/linux/install.sh
sudo ./install.sh
```

Or directly:

```bash
sudo ./install/linux/install.sh
```

Useful flags:

```bash
sudo ./install.sh --skip-maps              # skip the ~1 GB maps download
sudo ./install.sh --skip-build             # reuse an existing build/bin
sudo ./install.sh --install-dir /opt/nms
sudo NMS_NONINTERACTIVE=1 NMS_DB_PASSWORD=... NMS_SPIRE_PASSWORD=... \
  ./install.sh --non-interactive --use-existing-mysql
```

See `./install/linux/install.sh --help` for the full list.

### After install

```bash
cd ~/nms-server   # or your --install-dir
./spire_start     # web UI on http://127.0.0.1:3000
./start           # starts world/zone/ucs/loginserver via Spire
./stop
```

Passwords and paths are written to `install_config.yaml` in the install folder.

---

## Windows

### Requirements

- Windows 10/11 x64
- **Visual Studio 2022** with *Desktop development with C++* (includes CMake)
- Administrator PowerShell recommended for the first run (winget can install
  MariaDB + Strawberry Perl)
- Internet access for maps, Spire, and the first CMake dependency fetch

### Run

From the repository root, in an **elevated** PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.bat
```

Or:

```powershell
.\install\windows\install.ps1
```

Useful parameters:

```powershell
.\install\windows\install.ps1 -SkipMaps -InstallDir 'C:\nms-server'
.\install\windows\install.ps1 -NonInteractive -DbPassword 'secret' -SpirePassword 'admin' -UseExistingMysql -SkipDeps
```

### After install

In `%USERPROFILE%\nms-server` (or your `-InstallDir`):

| Script | Purpose |
| --- | --- |
| `spire_start.bat` | Starts Spire (web admin) |
| `spire_web_admin.bat` | Opens `http://127.0.0.1:3000/admin` |
| `server_start.bat` | Starts the game server via Spire |
| `server_stop.bat` | Stops the game server |
| `server_restart.bat` | Restarts the game server |

---

## Client (both platforms)

These installers set up the **server** only. You still need a RoF2-era EverQuest
client (not included):

1. Copy `Release-NMS-Client/ClientFiles/` over your client.
2. Point `eqhost.txt` at your loginserver (`Host=YOUR_IP:5999` for RoF2).
3. With the database imported, run `export_client_files` from the server `bin/`
   folder and copy `spells_us.txt`, `dbstr_us.txt`, `SkillCaps.txt`, and
   `BaseData.txt` into the client (and its `Resources\` folder).

Details: [Release-NMS-Client/README.md](../Release-NMS-Client/README.md).

---

## Notes

- Compiling from this tree is required — stock EQEmu release binaries do not
  include the multiclass / NMS changes.
- Maps are large; pass `--skip-maps` / `-SkipMaps` if you will copy them in
  yourself later. Without maps, pathing and many zone features will not work.
- Spire is treated as a local admin tool. Do not expose it to the public
  internet without additional access controls.
- The old Linux installer under
  `Release-NMS-Server/utils/scripts/linux_installer/` is the legacy Akkadius
  stock script and is **not** used by these NMS installers.
