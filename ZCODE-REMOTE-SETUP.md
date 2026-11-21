# ماموریت: آماده‌سازی این سیستم برای دیباگ remotely اپ rVPN iOS

> **این سند برای ZCode است** (دستیار هوش مصنوعی روی سیستم دوم).
> سیستمی که این را می‌خواند: ویندوزی است که یک iPhone از طریق Sideloadly به آن سایدلود شده.
> ZCode سیستم اول (سیستم اصلی توسعه) بعد از این مراحل از راه دور وصل می‌شود.

## زمینه

اپ iOS ما (R-VPN) روی گوشی نصب شده ولی بعد از Connect، Tunnel IP می‌گیرد و بعد قطع می‌شود.
می‌خواهیم لاگ زنده گوشی را با `idevicesyslog` بگیریم تا علت مشخص شود. برای این کار ZCode سیستم اول
باید SSH به همین سیستم بزند. **وظیفه تو: فعال‌سازی SSH و گزارش اطلاعات اتصال.**

---

## قدم ۱ — دانلود فایل ipa دیباگ

در PowerShell (نیازی به ادمین نیست) این را اجرا کن:

```powershell
$token = "GITHUB_TOKEN_PLACEHOLDER"
$headers = @{ Authorization = "token $token"; Accept = "application/vnd.github+json" }
$arts = Invoke-RestMethod "https://api.github.com/repos/iappdevs/rvpn-ios/actions/runs/44911446650/artifacts" -Headers $headers
$zipUrl = "https://api.github.com/repos/iappdevs/rvpn-ios/actions/artifacts/$($arts.artifacts[0].id)/zip"
Invoke-WebRequest $zipUrl -Headers $headers -OutFile "$env:USERPROFILE\Desktop\rvpn-dbg.zip"
Expand-Archive "$env:USERPROFILE\Desktop\rvpn-dbg.zip" -DestinationPath "$env:USERPROFILE\Desktop" -Force
```

فایل `RVPN.ipa` روی دسکتاپ ظاهر می‌شود. **این را بعداً به کاربر بگو تا با Sideloadly نصب کند** (همان Apple ID قبلی، تا جایگزین نسخه قدیمی شود).

اگر دانلود شکست خورد (فیلترینگ): به کاربر بگو فایل را از مسیر
`D:\Projects\rvpn-ios-dist\R-VPN-0.1.0-49-debug.ipa` از سیستم اول کپی کند.

---

## قدم ۲ — فعال‌سازی SSH Server (نیاز به کلیک Yes روی UAC دارد)

از یک PowerShell معمولی این را اجرا کن (پنجره UAC باز می‌شود، کاربر Yes می‌زند):

```powershell
Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-Command',@
"Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0;
 Start-Service sshd;
 Set-Service sshd -StartupType Automatic;
 net user zdebug Zcode#2026! /add;
 net localgroup Administrators zdebug /add;
 New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null"
```

**تأیید** (در PowerShell معمولی):

```powershell
Start-Service sshd -ErrorAction SilentlyContinue
(Get-Service sshd).Status          # باید Running باشد
Test-NetConnection 127.0.0.1 -Port 22 | Select-Object TcpTestSucceeded   # باید True باشد
```

### اگر قدم ۲ شکست خورد (ویندوز آپدیت در دسترس نیست)

جایگزین بدون ادمین — تونل معکوس از سرور ما؛ **این پنجره را باز نگه دار**:

```powershell
ssh -N -R 127.0.0.1:9500:127.0.0.1:22 root@91.107.154.88
# پسورد سرور را که پرسید وارد کن؛ پنجره باید باز بماند
```

(برای این حالت هم SSH سرور محلی لازم است، ولی بدون Windows Update از سورس دوم:
اگر Add-WindowsCapability نشد، همین تونل را با `ssh` فقط گزارش بده تا راه دیگری بدهیم.)

---

## قدم ۳ — جمع‌آوری اطلاعات گزارش

```powershell
"=== IP ==="
(Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*'} | Select-Object -ExpandProperty IPAddress) -join ', '
"=== sshd ==="
(Get-Service sshd).Status
"=== iPhone connected? ==="
Get-PnpDevice -PresentOnly | Where-Object {$_.FriendlyName -match 'Apple|iPhone'} | Select-Object -First 3 FriendlyName, Status
"=== iTunes installed? ==="
Test-Path 'C:\Program Files\iTunes\iTunes.exe'
```

---

## قدم ۴ — گزارش نهایی به کاربر (این متن را نشان بده)

```
اتصال آماده است — این اطلاعات را به ZCode سیستم اول بده:

  IP:       <از قدم ۳>
  Port:     22
  User:     zdebug
  Password: Zcode#2026!

  iPhone: <متصل/غیرمتصل>
  ipa روی دسکتاپ: <هست/نیست>
```

بعد از اتمام کار دیباگ، برای امنیت:
```powershell
Stop-Service sshd; Set-Service sshd -StartupType Disabled; net user zdebug /delete
```

---

## بعد از اتصال، ZCode سیستم اول این کارها را خواهد کرد (اطلاع تو)

1. `scp`/`ssh` به همین سیستم
2. نصب libimobiledevice پرتابل (بدون نصب، فقط زیپ)
3. اجرای `idevicesyslog` با فیلتر `[RVPN]`
4. تحلیل لاگ هنگام Connect شدن کاربر روی گوشی
