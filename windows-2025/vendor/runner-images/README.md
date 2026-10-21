# Vendored from actions/runner-images

Upstream: https://github.com/actions/runner-images at commit
`e7c7cb8f4227797c6404a4e98c2ad463c2f70f91`, MIT licence (`LICENSE` in this
folder, copied unchanged).

The `.ps1` files are byte-identical copies of upstream files. Do not edit
them here: to take a newer version, copy the files again from a new upstream
commit and update the commit above.

| File | Upstream path | What it does in our image |
|---|---|---|
| `Configure-WindowsDefender.ps1` | `images/windows/scripts/build/` | Turns off Defender scanning and excludes `C:\` and `D:\` (the work directory is `D:\_work`). |
| `Configure-System.ps1` | `images/windows/scripts/build/` | Turns off telemetry, Windows Update, SysMain and other background services and scheduled tasks, including the .NET NGen idle tasks. |
| `PathHelpers.ps1` | `images/windows/scripts/helpers/` | Registry hive helpers used by `Configure-System.ps1`. |

`../../runner-images.ps1` runs the two build scripts in that order near the
end of the first logon. It also defines the few upstream helper functions
these scripts need (the architecture and OS version checks), so the rest of
upstream's helper module is not copied.

`runner-images.ps1` then runs .NET Framework NGen with the same three
commands as upstream's `Install-NativeImages.ps1`, so native images are not
compiled after each boot. That script is not copied: it stops when
`ngen update` exits non-zero, and on our image `ngen update` exits -1 after
compiling everything it can, because a few CLR 2.0 assemblies need .NET 3.5,
which the image does not install. Our step logs the exit code instead.

`Configure-System.ps1` also makes two permission changes that are not about
services: it grants the `Users` group full control of `%SystemRoot%\Temp` and
turns on permission inheritance for `C:\`. They are kept so the file stays
identical to upstream.

`Configure-System.ps1` disables every scheduled task in the root folder `\`,
so Toshi's own tasks are registered under `\toshi\`.
