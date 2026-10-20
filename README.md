# VM Guest File Copy

**Version 0.13**

A small GUI over PowerCLI's `Copy-VMGuestFile` for copying files to and from a VM's guest OS through VMware Tools. It's a PowerShell script using WPF, so you don't need to install anything.

![VM Guest File Copy window](docs/screenshot.png)

## Features

- Connect to a vCenter Server or a standalone ESXi host.
- Keep a favourites list of servers, each with its certificate setting. Usernames and passwords are never saved.
- An **Ignore certificate errors** checkbox for self-signed certificates.
- A VM list you can filter, showing power state, VMware Tools status, guest OS and host.
- Copy **Local → Guest** or **Guest → Local**. You can pick several local files or a whole folder.
- **Force** creates the destination folder if it doesn't exist.
- The window stays responsive during long copies because PowerCLI runs in a background runspace.

## Folder layout

```
VMGuestFileCopy.ps1        <- the GUI
Get-PowerCLIPortable.ps1   <- one-off helper to fetch PowerCLI
Modules\                   <- portable PowerCLI (created by the helper; not in the repo)
```

## Starting the tool

Either of these works:

- From a PowerShell prompt in the tool's folder, run `.\VMGuestFileCopy.ps1`.
- Right-click `VMGuestFileCopy.ps1` and choose **Run with PowerShell**.

If Windows refuses to run the script because it was downloaded from the internet, unblock it once. Right-click the file, choose **Properties**, and tick **Unblock**. Or run `Get-ChildItem -Recurse | Unblock-File` in the folder.

## Requirements on the server

| Requirement | Notes |
|---|---|
| Windows PowerShell 5.1 + WPF | Built into Windows Server 2016 and later |
| .NET Framework 4.7.2+ | Built into Server 2019/2022/2025. **Server 2016 ships with 4.6.2**, which current PowerCLI can't use |
| PowerCLI (`VMware.VimAutomation.Core`) | Doesn't need installing. Put it in `.\Modules` (see below). If it's already installed, the script uses that copy |
| Network | TCP 443 to vCenter **and to the ESXi hosts**. The file data goes straight to the host running the VM, not through vCenter |
| Guest | VMware Tools running, plus a guest OS account |

## Getting portable PowerCLI (one-off)

On any machine with internet access, run:

```powershell
.\Get-PowerCLIPortable.ps1
```

This saves only `VMware.VimAutomation.Core` and the modules it depends on into `.\Modules`. Then copy the whole folder to the server(s).

If you have no gallery access, download the PowerCLI offline ZIP from the Broadcom developer portal. Extract `VMware.VimAutomation.Core` and the modules it depends on (`VMware.VimAutomation.Common`, `VMware.VimAutomation.Sdk`, `VMware.Vim`, `VMware.VimAutomation.Cis.Core`) into `Modules\`.

## Usage notes

- Favourites are stored in `%APPDATA%\VMGuestFileCopy\favourites.json`. Each Windows user has their own list.
- End guest destination folders with a separator, for example `C:\Temp\` or `/tmp/`. Otherwise the last part of the path is treated as a file name.
- Guest paths are typed by hand. Copy-VMGuestFile can't browse the guest file system.
- To copy several files at once, separate the source paths with `;`.

## Versioning

The version is recorded in two places at the top of `VMGuestFileCopy.ps1`:

- the **`.NOTES`** section of the header comment
- **`$script:AppVersion`**, which is what the window shows in its title, in the bottom-right corner and as the first line of the log

Every change increases the version by 0.01: 0.1, 0.11, 0.12 and so on. When you change the version, update both places in the script, the line at the top of this README, and the table below.

| Version | Changes |
|---|---|
| 0.13 | Removed the `.cmd` launcher and the window icon. The tool is now just the PowerShell script. |
| 0.12 | The vCenter/ESXi password field is cleared as soon as the connection succeeds. If the connection fails, the password is kept so you can retry. |
| 0.11 | The selected VM stays highlighted when you click into another field. It also stays selected when you change the filter or refresh the VM list, as long as it's still in the list. |
| 0.1 | First versioned release. Copies files to and from guests and keeps a favourites list (server and certificate setting only). |
