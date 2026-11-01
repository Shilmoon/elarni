# CI Windows VM

CI's Windows jobs run on a self-hosted runner (`elarni-windows`) in a Windows Server 2022
evaluation VM on the Linux server, through [dockur/windows](https://github.com/dockur/windows) over KVM.
The VM gets 8 cores and 8 GB, which ballooning returns under host memory pressure; its disk
(64 GB, sparse) and the server-side state live in `~/elarni-windows`.

1. Copy this directory to the server and start the VM with the public key that may log in:
   `sh start ~/key.pub`. The first start downloads Windows from Microsoft and installs it unattended
   (about 30 minutes); `oem/install.ps1` then opens SSH. All ports listen on the server's 127.0.0.1:
   8006 (web console), 3389 (RDP), 2222 (SSH). The user is `elarni`, its password is in `~/elarni-windows/password`.
2. Get a registration token (`gh api -X POST repos/Shilmoon/elarni/actions/runners/registration-token --jq .token`),
   copy `provision.ps1` in and run it from the server:
   `scp -P 2222 provision.ps1 elarni@127.0.0.1:` then
   `ssh -p 2222 elarni@127.0.0.1 powershell -ExecutionPolicy Bypass -File provision.ps1 -Token TOKEN -Password PASSWORD`.
   It installs Git, Python, Visual Studio Build Tools (C++), the .NET SDK, rustup and the runner service;
   the workflow adds mise's tools and WiX.

The evaluation runs 180 days; `slmgr /rearm` extends it, or replace it with a licensed install.
