# ADB Suite - GUI ADB for iPhone 4S / iOS 6 (armv7)

Modern ADB over Wi-Fi (Android 11+ wireless debugging: TLS 1.3 pairing with a 6-digit code, dynamic
connect port, mDNS discovery) with a UIKit app. Also works with `adb tcpip` (port 5555) devices.

## Tabs
- **Devices** - scan the network (mDNS), pair with code, connect, saved devices, public key.
- **Remote** - D-pad, media/volume/TV keys, number pad, text entry, touchpad (tap/swipe).
- **Terminal** - persistent shell session (cd works), history.
- **Files** - browse /sdcard etc., upload, download, view text/images, rename, delete, new folder, properties.
- **Apps** - list user/system packages, launch (also Android TV launcher), force stop, clear, disable/enable,
  uninstall, info, extract APK, install APK.
- **Screen** - screenshot, live view, touch-through control, save to Photos, screen recording.
- **Logcat** - live stream with level + text filter, pause, clear, save.
- **Tools** - device info (battery, memory, storage, network, processes...), power, quick settings
  (Wi-Fi, BT, brightness, volume, display size...), open URL / am start, tcpip 5555, port forwarding.

## Build (on the phone, Theos + iOS 6.1 SDK)
    sh build-deps.sh                  # once: OpenSSL 1.1.1 -> ~/ios6-openssl (downloads itself)
    make package install              # then respring / open "ADB Suite"
If OpenSSL lives elsewhere:  make OPENSSL=/path/to/prefix
Downloads / APKs / logs / recordings go to ~/Documents/ADBSuite/ (Downloads, APKs, Logs, Recordings).
The ADB key lives in ~/Library/ADBSuite/.adbi/adbkey (first key generation takes a while on a 4S).

## First use
Android: Developer options > Wireless debugging > on.
Devices tab > "Pair new device..." (or tap the PAIR entry found by the scan), enter the code, then tap the
CONNECT entry. The connect port changes whenever wireless debugging is toggled; Scan again.

## Notes
- core/ is plain C (OpenSSL only; SPAKE2 implemented with BIGNUM). Tested on Linux against a BoringSSL-based
  mock adbd (pairing, STLS, shell v2, sync, port forward) - see test/.
- UI code was syntax-checked against iOS SDK headers with an iOS 6.0 deployment target (no newer APIs used),
  but not run on a device by the author.
