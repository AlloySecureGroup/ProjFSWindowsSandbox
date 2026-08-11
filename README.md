# ProjFS in Windows Sandbox — experimental package

This package prepares a Windows Sandbox session that manually installs and loads the host-matched Windows Projected File System components, then runs a minimal provider that projects `C:\ProjFSRoot\hello.txt`.

## One Shoe
```
One-shot: extract the PhantomFS-Sandboxzip, right-click Install-And-Launch.ps1, choose Run with PowerShell, and approve the admin prompt. The sandbox launches and PhantomFS starts automatically.
```


## Run

1. Extract this ZIP on the Windows host.
2. Right-click `Install-And-Launch.ps1` and choose **Run with PowerShell**, or run:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-And-Launch.ps1
   ```

3. Approve the administrator prompt.
4. If the script enables ProjFS and requests a restart, restart Windows and rerun it.
5. Windows Sandbox launches automatically. The bootstrap copies the driver and DLL, imports the host's `PrjFlt` service registration, loads the minifilter, starts the provider, hydrates `hello.txt`, and opens the virtualization root in Explorer.

## Paths

- Host staging, mapped read-only: `C:\Sandbox\Read`
- Host/sandbox logs, mapped writable: `C:\Sandbox\Write`
- Sandbox virtualization root: `C:\ProjFSRoot`
- Projected file: `C:\ProjFSRoot\hello.txt`

## Expected output

`hello.txt` contains:

```text
Hello from a basic ProjFS provider running inside Windows Sandbox.
```

Useful logs are written to `C:\Sandbox\Write`, including `sandbox-bootstrap.log`, `provider.log`, and `fltmc-filters.txt`.

## Important limitations

- This is an experimental/unsupported technique. Windows Sandbox normally gets Windows components from its base image; manually copying and registering a kernel minifilter can be rejected by servicing, code-integrity, or build-mismatch checks.
- The package deliberately copies the driver, DLL, and complete `PrjFlt` registry configuration from the same host build. Do not substitute files from another machine or Windows build.
- Secure Boot/code integrity remains enforced. The Microsoft-signed host binary should load only when compatible with the Sandbox kernel.
- Windows Sandbox is disposable. All in-sandbox system changes disappear when it closes; logs survive only through the writable mapped folder.
- Networking is disabled by the supplied `.wsb` file.

## Manual launch

After host preparation, launch `C:\Sandbox\ProjFS-Sandbox.wsb` directly.
