# اتصال ZCode به سیستم ویندوزی دوم (دیباگ اپ iOS)

هدف: از سیستم اول (جایی که ZCode هست) به سیستم ویندوزی که آیفون با Sideloadly بهشه وصله، وصل شیم تا:
- نصب/آپدیت اپ روی گوشی
- گرفتن لاگ زنده گوشی (`idevicesyslog`) موقع کانکت شدن
- تست و دیباگ مشکل دیسکانکت

دو راه هست — بسته به اینکه دو سیستم **تو یه شبکه‌ان یا نه**:

---

## راه A: دو سیستم تو یه LAN هستن (مثل یه وای‌فای)

### قدم ۱ — روی سیستم دوم، PowerShell رو **Run as Administrator** باز کن و این دو خط رو بزن:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd ; Set-Service -Name sshd -StartupType Automatic
```

(اگه خطای عدم دسترسی به اینترنت/ویندوز آپدیت داد، راه B رو برو)

### قدم ۲ — فایروال (همون PowerShell ادمین):

```powershell
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

### قدم ۳ — IP سیستم دوم رو پیدا کن:

```powershell
ipconfig | Select-String "IPv4"
```

### قدم ۴ — یه کاربر رمزدار برای SSH (اگه ویندوزت رمز نداره):

```powershell
net user zdebug Zcode#2026! /add
net localgroup Administrators zdebug /add
```

### قدم ۵ — این اطلاعات رو به ZCode بده:

```
IP سیستم دوم:  192.168.x.x
یوزر:          zdebug
پسورد:         Zcode#2026!
```

---

## راه B: دو سیستم تو شبکه‌های مختلفن (تونل معکوس از سرور)

هیچ ادمینی لازم نیست — فقط یه پنجره PowerShell باز نگه‌دار (روی سیستم دوم):

```powershell
ssh -N -R 127.0.0.1:9500:127.0.0.1:22 root@91.107.154.88
```

- پسورد سرور رو که می‌پرسه بزن و **پنجره رو باز نگه‌دار**
- این یعنی پورت ۹۵۰۰ روی سرور → پورت SSH همون سیستم دوم
- برای این راه، قدم‌های ۱ تا ۳ راه A باز هم لازمه (SSH سرور باید روشن باشه)

---

## بعد از اتصال، ZCode چی می‌کنه؟

1. **چک محیط**: iTunes/Sideloadly، دسترسی USB به گوشی، نسخه iOS
2. **نصب ابزار libimobiledevice** (پرتابل — بدون نصب):
   - `idevicesyslog` → لاگ زنده کل گوشی، فیلترشده روی اپ R-VPN
   - `idevicecrashreport` → کرش‌لاگ‌ها اگه کرش کرده باشه
3. **سناریوی تست**: تو روی گوشی دکمه Connect رو می‌زنی، من همزمان لاگ رو می‌بینم:
   - هندشیک WebSocket و X3DH درست رد میشه؟
   - Double Ratchet راه می‌افته؟
   - چرا state از Connected میره روی Disconnected؟ (تایم‌اوت؟ ساسپند شدن اپ؟ پمپ پکت؟)
4. **فیکس و بیلد جدید**: علت که پیدا شد، کد اصلاح میشه، ipa جدید ساخته میشه و روی گوشی دوباره سایدلود میشه

---

## نکته درباره مشکلات فعلی که گفتی

| علامت | توضیح |
|---|---|
| «درخواست پروفایل VPN نمی‌کنه» | **طبیعیه** — NetworkExtension هنوز به اپ اضافه نشده (قدم بعدی توسعه‌ست). اپ الان فقط موتور رو تست می‌کنه، نه VPN سیستمی |
| «Tunnel IP می‌گیره ولی دیسکانکت میشه» | دقیقاً همینه که با لاگ باید ببینیم — احتمالاً پمپ پکت iOS FFI (wait_for_packet) توی اپ اصلی صدا زده نمیشه یا iOS اپ رو suspend می‌کنه |

## امنیت

- بعد از تموم شدن دیباگ، SSH رو خاموش کن:
  ```powershell
  Stop-Service sshd ; Set-Service sshd -StartupType Disabled
  net user zdebug /delete
  ```
