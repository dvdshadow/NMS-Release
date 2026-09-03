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

Works on a **basic headless** Debian/Ubuntu or RHEL/Fedora box (no GUI). The
script installs compilers, CMake, MariaDB, Perl, and Lua via the package
manager. Visual Studio / PowerShell / Strawberry Perl issues from Windows do
not apply here; Linux links against distro `libperl`.

### Requirements

- Debian/Ubuntu or RHEL/Fedora-family (cloud/minimal images are fine)
- `sudo` or root for the first run (packages + MariaDB)
- Several GB free disk (maps alone are ~1 GB; build artifacts more)
- A `git clone --recursive` (GitHub zip downloads omit C++ submodules)

### Run

From the repository root:

```bash
chmod +x install.sh install/linux/install.sh
sudo ./install.sh
```

As root the default runtime folder is `/opt/nms-server` (not `/root/nms-server`).
On a machine with no TTY (cloud-init, piped SSH) the installer switches to
non-interactive defaults automatically.

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
cd /opt/nms-server   # or ~/nms-server if you installed as a normal user
./spire_start
./start
./stop
./build_shared_memory   # if world logs "Could not load item data"
```

There is no desktop browser on a headless host. Tunnel Spire if you need the UI:

```bash
ssh -N -L 3000:127.0.0.1:3000 user@your-server
```

Then open `http://127.0.0.1:3000/admin` on your own machine. Do not expose
Spire to the public internet.

Passwords and paths are written to `install_config.yaml` in the install folder.

---

## Windows

### One-click install

1. Download / clone this repository onto your PC (GitHub → Code → Download ZIP,
   then unzip, **or** `git clone`).
2. Double-click **`install.bat`** at the root of the unzipped folder.
3. Approve the Windows UAC prompt (Administrator).
4. Press Enter to accept defaults, or type your own values when asked.

You do **not** need to open PowerShell yourself — `install.bat` does that
behind the scenes.

### Requirements (install these once beforehand)

- Windows 10/11 x64
- **Visual Studio 2022 or 2026** with the *Desktop development with C++*
  workload (includes CMake) — required to compile this custom server.
  Community is enough. You do not need to open the Visual Studio IDE.
  The installer copies `libsodium.dll`, `libmariadb.dll`, `lua51.dll`,
  `perl524.dll`, and other runtime DLLs into the server `bin\` folder.
  If Spire preflight is green but processes exit `0xc0000135`, those
  DLLs are missing — run `install\windows\copy_runtime_dlls.ps1`.
- Internet access (maps ~1 GB, Spire, and first-time CMake deps)

MariaDB is installed automatically via `winget` when possible. The Windows
build does **not** link against a winget/system Strawberry Perl (5.38/5.40
headers fail to link with MSVC). CMake downloads EQEmu's portable Strawberry
Perl **5.24** into `Release-NMS-Server/perl/` and the start scripts put that
copy on PATH so `zone.exe` can load `perl524.dll`.

### Advanced / scripted installs

PowerShell is still available if you want flags:

```powershell
.\install\windows\install.ps1 -SkipMaps -InstallDir 'C:\nms-server'
.\install\windows\install.ps1 -NonInteractive -DbPassword 'secret' -SpirePassword 'admin' -UseExistingMysql -SkipDeps
```

### After install

In `%USERPROFILE%\nms-server` (or your chosen install folder), double-click:

| Script | Purpose |
| --- | --- |
| `spire_start.bat` | Starts MariaDB if needed, then Spire (web admin) |
| `spire_web_admin.bat` | Opens `http://127.0.0.1:3000/admin` |
| `server_start.bat` | Starts the game server via Spire |
| `server_stop.bat` | Stops the game server |
| `server_restart.bat` | Restarts the game server |
| `build_shared_memory.bat` | Rebuilds `shared\items` (and spells/loot) from MariaDB |

World does **not** load items from SQL at boot. It memory-maps `shared\items`,
which `shared_memory.exe` writes. If world logs `Could not load item data` or
`Could not map a view of the shared memory file`, the mmap file is missing or
truncated (cancelling `shared_memory.exe` does that). Stop world, run
`build_shared_memory.bat` from the runtime folder (not from `bin\`), wait for
it to finish, then start again. Do not double-click `bin\shared_memory.exe` in
Explorer — the working directory must be the runtime root so it finds
`eqemu_config.json`.

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
