# مستندات اتصال و دیباگ ریموت — rVPN iOS

> این سند توضیح میدهد ZCode سیستم اول چطور به سیستم دوم (ویندوزی که آیفون به آن وصل است)
> متصل میشود، چطور خروجی میگیرد، چطور اپ را روی گوشی نصب میکند و چطور لاگ گوشی را زنده میخواند.

---

## ۱. معماری کلی

```
┌────────────────────┐         SSH (LAN)         ┌──────────────────────┐    USB    ┌─────────┐
│   سیستم اول (من)    │ ───────────────────────► │      سیستم دوم        │◄────────► │ iPhone  │
│  D:\Projects\...    │   192.168.1.112 → .104   │  DESKTOP-R6V9RDR      │           │ iOS 27  │
└────────┬───────────┘                           └──────────┬───────────┘           └─────────┘
         │                                                  │
         │  GitHub API (push → CI بیلد → artifact)           │ libimobiledevice + pymobiledevice3
         │                                                  │ (ideviceinstaller, idevicesyslog, syslog live)
         ▼                                                  ▼
   github.com/iappdevs/rvpn-ios                     نصب ipa / خواندن لاگ os_log
```

- **سیستم اول**: ماشین توسعه (این سیستم). سورس‌ها، اسکریپتها و اتصال SSH اینجاست.
- **سیستم دوم**: `192.168.1.104` — ویندوز، SSH سرور فعال، آیفون با کابل USB وصل.
- **گوشی**: iPhone با iOS 27.0.1 — UDID: `00008130-000261140141001C`

---

## ۲. اتصال SSH به سیستم دوم

### مشخصات اتصال

| مورد | مقدار |
|---|---|
| IP (LAN) | `192.168.1.104` |
| Port | `22` |
| User | `zdebug` |
| Password | `Zcode#2026!` |
| Hostname | `DESKTOP-R6V9RDR` |

### روش اتصال (از پایتون با paramiko)

```python
import paramiko
ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('192.168.1.104', username='zdebug', password='Zcode#2026!', timeout=15)

# اجرای دستور:
_, out, err = ssh.exec_command('ipconfig', timeout=30)
print(out.read().decode('utf-8', 'replace'))

# انتقال فایل:
sftp = ssh.open_sftp()
sftp.put('local/file.ipa', 'C:/rvpn-agent/file.ipa')

ssh.close()
```

### راهاندازی اولیه (یکبار روی سیستم دوم انجام شد)

```powershell
# PowerShell ادمین — OpenSSH سرور پرتابل در C:\Program Files\OpenSSH نصب شد
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0   # (در صورت در دسترس بودن Windows Update)
Start-Service sshd; Set-Service sshd -StartupType Automatic
net user zdebug Zcode#2026! /add; net localgroup Administrators zdebug /add
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

> نکته: مسیر `Add-WindowsCapability` روی آن سیستم هنگ کرد؛ نسخه پرتابل OpenSSH از
> ریپوی `PowerShell/Win32-OpenSSH` در `C:\Program Files\OpenSSH` نصب شد.

---

## ۳. ابزارهای نصب‌شده روی سیستم دوم

### ۳.۱ libimobiledevice (پرتابل)

```
مسیر:   C:\libim\iFred09-libimobiledevice-windows-80a5db8\
منبع:   github.com/iFred09/libimobiledevice-windows (زیپ مستقیم از ریپو)
```

ابزارهای مهم:

| ابزار | کاربرد |
|---|---|
| `idevice_id -l` | لیست UDID دستگاههای وصل |
| `ideviceinfo -k ProductVersion` | نسخه iOS و مشخصات |
| `ideviceinstaller -i <ipa>` | **نصب ipa امضاشده روی گوشی** |
| `ideviceinstaller -U <bundle-id>` | حذف اپ |
| `ideviceinstaller -l` | لیست اپهای نصب‌شده |
| `idevicesyslog` | لاگ قدیمی syslog (روی iOS جدید تقریبا بیفایده) |

پیشنیاز: سرویس `AppleMobileDeviceService` باید در حال اجرا باشد (هست).

### ۳.۲ pymobiledevice3 (لاگ مدرن os_log)

```powershell
# نصب (پایتون 3.14 روی سیستم دوم نصب است):
python -m pip install -U pymobiledevice3

# گرفتن لاگ زنده os_log (لاگ اپهای third-party را هم نشان میدهد):
python -m pymobiledevice3 syslog live
```

> **مهم**: `idevicesyslog` قدیمی فقط لاگ دیمنهای سیستم را میدهد؛ لاگ اپهای کاربر فقط با
> `pymobiledevice3 syslog live` (relay مدرن os_log) دیده میشود.

### ۳.۳ ایجنت دائمی (RVPNWatch)

```
مسیر:  C:\rvpn-agent\watch.ps1
```

کارهای ایجنت (حلقه ۳ ثانیهای):
1. اگر پروسه capture لاگ زنده مرده بود، دوباره راه میاندازد
2. **کانال دستور**: اگر فایل `C:\rvpn-agent\command.ps1` وجود داشته باشد اجرایش میکند و
   خروجی را در `C:\rvpn-agent\last_result.txt` مینویسد (سپس فایل دستور را پاک میکند)

```powershell
# اجرای دستور از راه دور از طریق کانال ایجنت:
# 1) ساخت command.ps1 روی سیستم دوم (با sftp)
# 2) صبر تا last_result.txt آپدیت شود
# 3) خواندن نتیجه
```

راهاندازی دستی ایجنت (اگر ریبوت شد):

```powershell
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:/rvpn-agent/watch.ps1'
```

---

## ۴. خط تولید و نصب خودکار اپ (Deploy Pipeline)

کل چرخه بدون دخالت دستی:

```
git push (سیستم اول)
   → GitHub Actions (macOS runner) — .github/workflows/dev-deploy.yml
      1. cargo build rvpn-mobile (aarch64-apple-ios)
      2. xcodebuild اپ اصلی (SwiftPM)
      3. xcodegen + xcodebuild اکستنشن VPN (RVPN Tunnel.appex)
      4. امضای هر دو با سرتیفیکات Apple Development (legacy p12: PBE-SHA1-3DES + macalg sha1)
      5. ساخت ipa → آپلود artifact
   → دانلود artifact (از سیستم اول با GitHub API)
   → sftp به C:/rvpn-agent/RVPN-dev.ipa روی سیستم دوم
   → ideviceinstaller -U org.rvpn.ios (حذف قبلی) + -i (نصب جدید)
```

### اسکریپت دیپلوی یکپارچه (سیستم اول)

```
فایل:  D:\Projects\asc-signing\deploy_ipa.py
کار:   دانلود آخرین artifact + sftp + نصب روی گوشی
اجرا:  python D:/Projects/asc-signing/deploy_ipa.py
```

### امضا (Signing)

| مورد | مقدار |
|---|---|
| Cert (App) | `Apple Development: Created via API (73FS36X6P9)` — ID: `Z5FF955N57` |
| Cert (توزیع TestFlight) | `Apple Distribution: Nima Soroush (R7KJBVMP46)` — ID: `L24JA2T9YA` |
| Team ID | `R7KJBVMP46` |
| Profile اپ | `RVPN Dev Debug` (org.rvpn.ios + device KK9YDSQMJ2) |
| Profile اکستنشن | `RVPN Tunnel Dev` (org.rvpn.ios.tunnel) — ID: `7VXNX6W9AV` |
| پسورد p12 | `RvpnDev2024!` |
| App ID اکستنشن | `7555VGYPU6` با capability `NETWORK_EXTENSIONS` |

Secrets در گیتهب (`iappdevs/rvpn-ios`):
`APPLE_DEV_P12`, `APPLE_DEV_P12_PASSWORD`, `APPLE_DEV_PROFILE`, `APPLE_TUNNEL_PROFILE`,
`APPLE_TEAM_ID`, `APPLE_API_KEY_P8`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`,
`APPLE_DISTRIBUTION_P12`, `APPLE_DISTRIBUTION_P12_PASSWORD`, `APPLE_MOBILEPROVISION`

> **درس آموختهشده**: secret های GitHub باید **UTF-8** باشند — فایل باینری p12 باید
> base64 شود و متن base64 بهعنوان مقدار secret ذخیره شود، وگرنه workflow با
> `startup_failure` (بدون هیچ خطایی!) میمیرد.

---

## ۵. گرفتن لاگ زنده گوشی

### ۵.۱ استریم دائمی (روش اصلی)

```
فایل:  D:\Projects\asc-signing\live_log.py
اجرا:  python D:/Projects/asc-signing/live_log.py <مدت_به_ثانیه>   # مثلا 2700 برای ۴۵ دقیقه
خروجی:  - همه لاگها → D:\Projects\asc-signing\live_oslog.txt
        - خطوط مرتبط RVPN → زنده روی کنسول
```

مکانیزم: کانال SSH دائمی به سیستم دوم → اجرای `python -u -m pymobiledevice3 syslog live`
→ خواندن جریان بهصورت پیوسته.

فیلترهای کلیدی (KEYWORDS): `[RVPN]`, `[RVPN-TUNNEL]`, `IOS_TUN_FFI`, `IosTun`,
`Double Ratchet`, `FlowConnector`, `DohClient`, `DnsServer`

### ۵.۲ جستجوی لاگ ثبتشده

```bash
# آخرین رویدادهای اپ:
grep -aE "\[RVPN" D:/Projects/asc-signing/live_oslog.txt | tail -50

# رویدادهای اکستنشن VPN:
grep -aE "RVPN-TUNNEL" D:/Projects/asc-signing/live_oslog.txt | tail -20

# فیلتر زمانی (ساعت گوشی، محلی):
grep -aE "\[RVPN\]" live_oslog.txt | grep -a "20:2[0-9]"
```

### ۵.۳ لاگ سرور VPN (91.107.154.88)

```python
ssh.connect('91.107.154.88', username='root', password='*76sw8df7687')
# journalctl -u rvpn-server --no-pager --since '16:05' --until '16:09'
```

---

## ۶. خواندن وضعیت گوشی / اپ

```powershell
# روی سیستم دوم:
C:\libim\...\idevice_id.exe -l                          # UDID
C:\libim\...\ideviceinfo.exe -k ProductVersion          # نسخه iOS
C:\libim\...\ideviceinstaller.exe -l                    # اپهای نصبشده + ورژن
```

نمونه بررسی سلامت از سیستم اول (paramiko → هر دستور بالا).

اسکرینشات گوشی: `idevicescreenshot` نیاز به Developer Disk Image دارد — روی iOS 27 در دسترس نیست؛
بجای آن از لاگهای os_log برای دیدن وضعیت استفاده میشود.

---

## ۷. فایلها و مسیرهای مرجع

### سیستم اول

| مسیر | توضیح |
|---|---|
| `D:\Projects\rvpn-ios\` | سورس اپ iOS (git → iappdevs/rvpn-ios) |
| `D:\Projects\rvpn-ios\rvpn-ios-app\Sources\rvpn-ios-app\` | سورس اپ (SwiftUI) |
| `D:\Projects\rvpn-ios\rvpn-ios-app\Sources\rvpn-tunnel-provider\` | سورس اکستنشن VPN |
| `D:\Projects\rvpn-ios\.github\workflows\dev-deploy.yml` | workflow بیلد+امضای dev |
| `D:\Projects\rvpn-ios\.github\workflows\testflight.yml` | workflow آپلود TestFlight |
| `D:\Projects\rvpn-ios\rvpn-ios-app\project.yml` | spec مربوط به xcodegen (اکستنشن) |
| `D:\Projects\asc-signing\` | ابزارهای ریموت (همه اسکریپتها) |
| `D:\Projects\asc-signing\live_log.py` | استریم لاگ زنده |
| `D:\Projects\asc-signing\deploy_ipa.py` | دیپلوی خودکار ipa |
| `D:\Projects\asc-signing\rscreen.py` | اسکرینشات (نیاز به DDI دارد) |
| `D:\Projects\asc-signing\live_oslog.txt` | بافر لاگ ثبتشده (چندصد مگابایت — قابل پاک کردن) |
| `D:\Projects\rvpn-ios-dist\` | ipa های دانلودشده |
| `D:\Projects\rvpn-windows\` | کلاینت ویندوز (ریلیز v0.1.4) |

### سیستم دوم

| مسیر | توضیح |
|---|---|
| `C:\rvpn-agent\` | خانه ایجنت (watch.ps1, command.ps1, last_result.txt, oslog.txt) |
| `C:\libim\` | ابزارهای libimobiledevice پرتابل |
| `C:\Users\zdebug\Desktop\RVPN.ipa` | نسخهای از ipa (قدیمی) |
| `D:\Sideloadly\sideloadly.exe` | Sideloadly (دیگر لازم نیست — نصب خودکار جایگزین شد) |

---

## ۸. عیبیابی سریع (Playbook)

| علامت | بررسی |
|---|---|
| SSH وصل نمیشود | `ping 192.168.1.104` → سرویس sshd روی سیستم دوم بالا است؟ |
| گوشی دیده نمیشود | `idevice_id -l` خالی؟ کابل/سرویس AppleMobileDeviceService |
| لاگ جریان ندارد | پروسه python/pymobiledevice3 روی سیستم دوم زنده است؟ (ایجنت) |
| بیلد CI fail | لاگ job از GitHub API؛ خطاهای Swift در `grep "error:" build.log` |
| `startup_failure` ورکفلو | secret غیر-UTF-8 (باینری بدون base64) |
| p12 import fail در CI | الگوریتمهای legacy: `-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1` |
| اکستنشن اجرا نمیشود | `NSExtensionPrincipalClass` باید `RVPN_Tunnel.RVPNTunnelProvider` باشد |
| `Failed to load identity key` | فایل identity در sandbox اکستنشن ناقص/مسیر اشتباه (در حال دیاگنوستیک) |

---

## ۹. پاکسازی بعد از اتمام کار (امنیت)

روی سیستم دوم (PowerShell ادمین):

```powershell
Stop-Service sshd; Set-Service sshd -StartupType Disabled
net user zdebug /delete
Remove-Item C:\rvpn-agent -Recurse -Force
Remove-Item C:\libim -Recurse -Force
Remove-NetFirewallRule -Name 'sshd' -ErrorAction SilentlyContinue
```

روی سیستم اول:

```powershell
Remove-Item D:\Projects\asc-signing\live_oslog.txt -Force   # بافر لاگ حجیم
```

و در GitHub: حذف secret های امضا در صورت پایان پروژه.
