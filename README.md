# MKVToolNix for Windows on ARM64: cross-build script

`build-mkvtoolnix-woa.sh` builds native **Windows ARM64** (`aarch64-w64-mingw32`) versions of [MKVToolNix](https://mkvtoolnix.download/) from Linux. It's meant to run in WSL on a Windows-on-Arm machine, and should also work on any Debian or Ubuntu system, x86_64 or aarch64.

MKVToolNix provides official Windows builds for x86 and x64 only. Those builds are cross-compiled with GCC/MinGW, and GCC's Windows ARM64 support is still immature. This script uses [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) (Clang/LLVM), which handles that target well.

> **About this script:** It and this README were written by Claude (Anthropic's AI assistant) at my request. I've reviewed them and am running the build, but the script hasn't yet been verified end to end. Read it before you run it, and expect to fix a step or two. Issues and fixes are welcome.

---

## What it does

The script runs these steps in order. Each one records a marker when it finishes, so a re-run skips completed steps.

| # | Step | What happens |
|---|------|--------------|
| 1 | `host-packages` | Installs the build tools with `apt-get` (requires `sudo`) |
| 2 | `llvm-mingw` | Downloads the latest llvm-mingw release for your machine's architecture (`uname -m`) |
| 3 | `zlib`, `ogg`, `vorbis`, `flac`, `cmark`, `gmp` | Cross-compiles these libraries for Windows ARM64 as static libraries. GMP uses its portable C code because its ARM64 assembly doesn't support Windows |
| 4 | `libiconv`, `gettext` | Cross-compiles translation support (skipped when `WITH_NLS=0`) |
| 5 | `boost-headers`, `boost-filesystem` | Installs the Boost headers, then builds Boost.Filesystem for Windows ARM64 with Boost's `b2`. No other compiled Boost library is needed; Boost.System has been header-only since 1.69 |
| 6 | `qt-host` | Builds Qt `qtbase` **for Linux**, which supplies `moc`, `rcc`, `uic` and `qmake` for the cross build |
| 7 | `qt-target` | Cross-builds a **static** Qt `qtbase` for Windows ARM64 (`win32-clang-g++` mkspec) |
| 8 | `qtsvg` | Cross-builds Qt SVG |
| 8a | `qtshadertools-host`, `qtshadertools` | Builds Qt Shader Tools for Linux (the `qsb` shader compiler) and for Windows ARM64. Qt Multimedia needs both |
| 8b | `qtmultimedia` | Cross-builds Qt Multimedia, which MKVToolNix requires, using the native Windows Media Foundation backend (no FFmpeg). Spatial audio is disabled, and a missing `#include <istream>` is added to the bundled Resonance Audio code so it compiles with current libc++ |
| 8c | `rcc-no-zstd` | Wraps the Linux Qt's `rcc` so it always passes `--no-zstd`. The Linux Qt may have zstd support, but the Windows ARM64 Qt doesn't, so zstd-compressed resources would leave the GUI without icons |
| 9 | `mkvtoolnix` | Downloads the MKVToolNix release tarball, runs `configure` and `rake`. It comments out the `msix-assets` target in the Rakefile first: those Microsoft Store tile images aren't needed for a portable build, and their generator needs zsh. It also changes the hard-coded `processorArchitecture="x86"` in MKVToolNix's Windows manifests to `"*"`; otherwise the GUI fails on ARM64 with `0xc000007b`. This step always runs; `rake` is incremental |
| 10 | package | Copies the `.exe` files, translations, and the GUI's icon resource file and sounds into `dist/`, then checks each `.exe`: its manifest mustn't name x86/x64, and it must import only Windows system DLLs. It then runs `mkvmerge.exe --version` through WSL interop as a quick test |

The two Qt builds take most of the time. Allow one to two hours on a typical ARM laptop.

## Requirements

- **WSL 2** with Ubuntu or Debian (or a native Linux machine). On Windows-on-Arm, WSL runs aarch64 Linux and the native aarch64 llvm-mingw is used.
- **`sudo`** for the package install step.
- **Internet access** for the downloads listed below.
- **Roughly 15–20 GB of free disk space** for sources, two Qt builds and the libraries. This is an estimate.
- **Keep the working directory on the Linux filesystem** (the default is under `~`). Building under `/mnt/c` goes through WSL's 9P file bridge and is very slow.

## Usage

```bash
chmod +x build-mkvtoolnix-woa.sh
./build-mkvtoolnix-woa.sh
```

If a step fails, fix the cause and run the script again. It continues from the step that failed. To redo one step, delete its marker:

```bash
rm ~/mkvtoolnix-woa/stamps/qt-target
```

To start completely fresh, run `rm -rf ~/mkvtoolnix-woa`.

## Inputs (environment variables)

Everything can be overridden from the environment, for example:

```bash
MKVTOOLNIX_VERSION=103.0 QT_VERSION=6.10.1 JOBS=8 ./build-mkvtoolnix-woa.sh
```

| Variable | Default | Purpose |
|----------|---------|---------|
| `MKVTOOLNIX_VERSION` | `103.0` | MKVToolNix release to build |
| `QT_VERSION` | `6.10.1` | Qt version, used for both the host and target builds |
| `BOOST_VERSION` | `1.89.0` | Boost version (headers, plus a compiled Boost.Filesystem) |
| `ZLIB_VERSION` | `1.3.1` | zlib |
| `OGG_VERSION` | `1.3.5` | libogg |
| `VORBIS_VERSION` | `1.3.7` | libvorbis |
| `FLAC_VERSION` | `1.4.3` | libFLAC |
| `CMARK_VERSION` | `0.31.1` | cmark (used by the GUI) |
| `GMP_VERSION` | `6.3.0` | GMP (required by MKVToolNix via Boost.Multiprecision) |
| `ICONV_VERSION` | `1.17` | libiconv |
| `GETTEXT_VERSION` | `0.22.5` | gettext runtime (libintl) |
| `WITH_NLS` | `1` | `0` skips libiconv and gettext and passes `--disable-nls` (no translations) |
| `WORK` | `$HOME/mkvtoolnix-woa` | Directory for everything the script creates |
| `JOBS` | `$(nproc)` | Number of parallel build jobs |

### What it downloads

| From | What |
|------|------|
| `api.github.com` / `github.com` | Latest llvm-mingw release, zlib, cmark |
| `downloads.xiph.org` | libogg, libvorbis, FLAC |
| `ftp.gnu.org` | GMP, libiconv, gettext |
| `archives.boost.io` | Boost |
| `download.qt.io` | Qt `qtbase`, `qtsvg`, `qtshadertools` and `qtmultimedia` source |
| `mkvtoolnix.download` | MKVToolNix source tarball |

Downloads are cached in `$WORK/src/downloads/` and reused on later runs.

## What it changes on your system

- **Packages installed system-wide with `apt-get`:** `build-essential cmake ninja-build pkg-config curl xz-utils bzip2 python3 perl ruby rake xsltproc docbook-xsl inkscape imagemagick gettext file`. On distributions without `apt-get`, this step is skipped and you need to install the equivalents yourself.
- **Everything else stays inside `$WORK`.** The script doesn't write to `/usr`, `/opt`, your shell profile or the Windows filesystem. It modifies `PATH` only for its own process.

Layout of `$WORK`:

```
$WORK/
├── llvm-mingw/                    # cross toolchain
├── qt-host/                       # Qt built for Linux (build tools for the cross build)
├── prefix/                        # all Windows ARM64 libraries (static Qt, zlib, ogg, GMP, …)
├── src/                           # extracted sources; MKVToolNix is built in place here
│   └── downloads/                 # cached tarballs
├── build/                         # out-of-tree build directories
├── shim/                          # small wrapper scripts (see below)
├── stamps/                        # step-completion markers
├── toolchain-aarch64-w64-mingw32.cmake
└── dist/                          # final output
```

`shim/` contains:
- `aarch64-w64-mingw32-pkg-config`, which only searches `prefix/` and always asks for static link flags.
- `qmake6` and `aarch64-w64-mingw32-qmake6`, which forward to the cross-built Qt's target `qmake`.
- `magick`, created only if ImageMagick 7 is missing. It forwards to ImageMagick 6's `convert`, because MKVToolNix calls `magick` and Ubuntu ships ImageMagick 6.

## Outputs

`$WORK/dist/`:

```
mkvmerge.exe
mkvinfo.exe
mkvextract.exe
mkvpropedit.exe
mkvtoolnix-gui.exe
data/qt_resources.rcc                       # the GUI's icons, loaded at runtime
data/sounds/                                # "job finished" sounds
locale/<lang>/LC_MESSAGES/mkvtoolnix.mo     # when WITH_NLS=1
```

- All executables are **statically linked**: Qt, libc++ and the libraries above are built in, so no DLLs need shipping.
- `file dist/*.exe` should report `PE32+ executable … Aarch64`.
- To copy the output to Windows:
  ```bash
  cp -r ~/mkvtoolnix-woa/dist /mnt/c/Users/<you>/mkvtoolnix-arm64
  ```

### Not included

- An installer or MSIX package. You get a portable folder only.
- Qt's own translations (`qttranslations`), so Qt dialogs such as file pickers appear in English.
- Documentation and man pages in `dist/`.

## Troubleshooting

These are the most likely failure points, in order:

1. **`configure` can't find Qt 6** (`qmake6 couldn't be run for a dummy project`). MKVToolNix detects Qt by running `qmake6` on a test project. Check that `$WORK/prefix/bin/qmake` exists and works, then read `src/mkvtoolnix-<version>/config.log` near that check.
2. **`mkvtoolnix-gui.exe` fails to link, or starts and complains about a missing platform plugin.** With static Qt, the `qwindows` platform plugin has to be linked in. The command-line tools don't need it.
3. **Boost.Filesystem fails to build, or `configure` can't link against it.** It's built with `b2` using its `gcc` toolset pointed at llvm-mingw's `aarch64-w64-mingw32-g++` wrapper. Check `$WORK/build/boost-stage/lib/` for `libboost_filesystem.a`. If you switch to a Boost release older than 1.89, `configure` may also want the `boost_system` stub library; add `--with-system` to the `b2` command.
4. **An `.exe` fails to start with `0xc000007b`.** Windows loaded something built for the wrong processor. The packaging checks cover the two causes seen so far: an x86 manifest dependency, and a DLL left over from the build. If a check fails, `grep -rn processorArchitecture` in the MKVToolNix source shows where the manifest comes from. Otherwise, look for x64 DLLs in the folder you ran the program from, because Windows searches that folder first.
5. **The GUI starts but most icons are missing.** It loads them from `data\qt_resources.rcc` beside `mkvtoolnix-gui.exe`. Check that the file is there, and that you copied the whole `dist` folder rather than just the `.exe` files. The other known cause is zstd: if the Linux Qt has zstd and the Windows ARM64 Qt doesn't, resources compressed with it can't be read. The `rcc-no-zstd` step prevents this. To check both builds, run `grep -rh 'define QT_FEATURE_zstd' qt-host/include prefix/include`.
6. **A download fails with `curl: (35)` or similar.** This is usually a temporary server problem. Run the script again; finished downloads are cached.

When reporting a problem, include the last few dozen lines of output and, for `configure` failures, the relevant part of `config.log`.

## Licensing

- MKVToolNix is GPL-licensed, Qt is used here under the LGPL/GPL, and the other libraries have their own licences. If you **distribute** the resulting binaries, you take on those licences' obligations, including making the corresponding source available. Static linking matters for the LGPL parts. Check this yourself before publishing builds.
- This repository contains only the build script and does not include or redistribute any of those projects.
- Script licence: _TODO: choose one, for example MIT._

## Credits

- [MKVToolNix](https://mkvtoolnix.download/) by Moritz Bunkus and contributors.
- [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) by Martin Storsjö.
- Script and README written by Claude (Anthropic) for [@sam-truscott](https://github.com/sam-truscott).
