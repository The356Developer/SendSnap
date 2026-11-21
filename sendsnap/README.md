<div align="center">

  <img src="sendsnap/assets/icon/app_icon.png" width="120" height="120" alt="SendSnap Logo" />

  # SendSnap
  ### Lightning-Fast Offline P2P File Sharing

  [![Version](https://img.shields.io/badge/Version-2.2.6-3B5BFE?style=flat)](https://github.com/Youssef0356/SendSnap/releases/tag/v2.2.6)
  [![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
  [![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart&logoColor=white)](https://dart.dev)
  [![Platforms](https://img.shields.io/badge/Platforms-Android%20%7C%20Windows-blue)](https://youssef0356.github.io/sendsnap_website/)
  [![Speed](https://img.shields.io/badge/Speed-Up%20to%20100%20MB%2Fs-success)](https://youssef0356.github.io/sendsnap_website/)
  [![Ad-Free](https://img.shields.io/badge/100%25%20Ad--Free-Zero%20Tracking-00C853)](PRIVACY_POLICY.md)
  [![License](https://img.shields.io/badge/License-MIT-purple.svg)](../LICENSE)

  <p>
    <b>SendSnap</b> is an ultra-fast, privacy-first peer-to-peer file transfer application designed for <b>Android</b> and <b>Windows PC</b>.<br/>
    Transfer gigabytes of photos, 4K videos, documents, and folders at up to <b>100 MB/s</b> with <b>zero internet or cellular data usage</b>.
  </p>

  <p>
    <a href="https://youssef0356.github.io/sendsnap_website/">
      <img src="https://img.shields.io/badge/🌐%20Official%20Website-Visit%20Site-0078D4?style=for-the-badge" alt="Official Website" />
    </a>
    &nbsp;
    <a href="https://play.google.com/store/apps/details?id=com.the356company.sendsnap">
      <img src="https://img.shields.io/badge/Google_Play-Get%20on%20Android-00C853?style=for-the-badge&logo=google-play&logoColor=white" alt="Google Play Store" />
    </a>
    &nbsp;
    <a href="https://youssef0356.github.io/sendsnap_website/downloads/sendsnap-windows-x64.rar">
      <img src="https://img.shields.io/badge/Windows%20PC-Download%20(.rar)-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Download Windows Executable (.rar)" />
    </a>
    &nbsp;
    <a href="https://youssef0356.github.io/sendsnap_website/downloads/sendsnap-windows-x64.zip">
      <img src="https://img.shields.io/badge/Windows%20PC-Download%20(.zip)-0A58CA?style=for-the-badge&logo=windows&logoColor=white" alt="Download Windows Executable (.zip)" />
    </a>
  </p>

</div>

---

## ⚡ Highlights (v2.2.6)

- 🚀 **Gigabit Local Speeds**: Transfer at up to **100 MB/s** using high-frequency local Wi-Fi or Personal Hotspot.
- ⚡ **Zero-Delay Smart Discovery & Direct Wi-Fi**: Pre-warmed LAN + mDNS/NSD discovery and automatic Direct Wi-Fi / Local Hotspot pairing with instant QR auto-join (no manual hotspot switching needed).
- 🖥️ **Desktop Multi-File Finish Studio**: Two-pane Windows completion screen where you can inspect, preview, or open any transferred file in your batch, browse in multi-item Media Viewer gallery, or return home in one click via **`CLOSE ALL & MAIN MENU`**.
- 📴 **100% Offline, Private & Ad-Free**: Zero ads, zero tracking SDKs, zero cloud uploads, zero account registration, and zero data tracking. Files transfer directly between devices.
- 💻 **True Cross-Platform**: Share files effortlessly between **Android** and **Windows PC** with native high performance.
- 🃏 **Interactive Multi-File Cards Tray**:
  - View selected files as physical cards with **live image thumbnails** and file type badges.
  - **Drop file-per-file** onto specific devices and continue sending remaining files seamlessly.
  - Grab the **`DRAG ALL`** header handle to send the entire queue in an elevated 3D batch deck.
- 🌌 **Segmented Edge Portal Dock**: Drag files directly to the screen bezel with ethereal feathered radial aura glows for tactile AirDrop-like drops.
- 📷 **Instant QR & Manual IP Connect**: One camera scan connects devices immediately; fallback direct IP socket pairing connects across complex corporate/campus subnets.
- 📲 **System Integration**:
  - **Android**: Supports native Android Share Sheet (`SEND` / `SEND_MULTIPLE`) directly from file managers and photo galleries.
  - **Windows**: Explorer context menu integration (*"Send with SendSnap"*), system tray background mode, and `SendTo` shortcut.
- 👁️ **Built-in Multi-File Media Viewer**: Preview full-resolution photos with pinch/wheel zoom, keyboard arrow gallery switching, and quick system-app or folder reveal actions.

---

## 📥 Downloads (v2.2.6)

| Platform | Format | Link |
| :--- | :--- | :--- |
| **Android** | Google Play Store | [Get SendSnap on Google Play](https://play.google.com/store/apps/details?id=com.the356company.sendsnap) |
| **Windows (64-bit)** | Portable Zip Archive (`.zip`) | [Download `sendsnap-windows-x64.zip` (v2.2.6)](https://youssef0356.github.io/sendsnap_website/downloads/sendsnap-windows-x64.zip) |
| **Windows (64-bit)** | Standalone RAR Archive (`.rar`) | [Download `sendsnap-windows-x64.rar` (v2.2.6)](https://youssef0356.github.io/sendsnap_website/downloads/sendsnap-windows-x64.rar) |
| **Official Website** | GitHub Pages Release Portal | [https://youssef0356.github.io/sendsnap_website/](https://youssef0356.github.io/sendsnap_website/) |
| **GitHub Release** | Source & Tag `v2.2.6` | [View Release `v2.2.6` on GitHub](https://github.com/Youssef0356/SendSnap/releases/tag/v2.2.6) |

---

## 🛠️ Architecture & Tech Stack

- **Framework**: [Flutter](https://flutter.dev) (Dart 3.x) with custom platform channels
- **Discovery Protocol**: UDP Multicast broadcast over local subnet (Port `53317`)
- **Transfer Engine**: High-throughput multi-threaded TCP sockets (Port `53318`) with streaming chunk buffers
- **Drag & Drop**: Native desktop drag-and-drop (`desktop_drop`) and Flutter gesture physics
- **Design Language**: Frosted glassmorphism (`BackdropFilter`), ambient radial gradient orbs, and Apple-grade fluid typography

---

## 🚀 Building from Source

### Prerequisites
- Flutter SDK (v3.24+ recommended)
- Android Studio / Android SDK (for Android builds)
- Visual Studio 2022 / 2026 with *Desktop development with C++* (for Windows builds)

### 1. Clone the repository
```bash
git clone https://github.com/Youssef0356/SendSnap.git
cd SendSnap/sendsnap
```

### 2. Install dependencies
```bash
flutter pub get
```

### 3. Run on connected device or desktop
```bash
# Run on Windows Desktop
flutter run -d windows

# Run on Android phone / emulator
flutter run -d android
```

### 4. Build Release Packages
```bash
# Build Android APK
flutter build apk --release

# Build Windows Release Executable (.exe)
flutter build windows --release
```
The Windows release executable is output to `build/windows/x64/runner/Release/sendsnap.exe`.

---

## 💬 Feedback & Support

- **Bug Reports & Feature Requests**: [Open a GitHub Issue](https://github.com/Youssef0356/SendSnap/issues)
- **Direct Developer Email**: [nejiyoussef081@gmail.com](mailto:nejiyoussef081@gmail.com)
- **Website**: [https://youssef0356.github.io/sendsnap_website/](https://youssef0356.github.io/sendsnap_website/)

---

<div align="center">
  <sub>Crafted with ❤️ by Youssef Neji • © 2026 SendSnap</sub>
</div>
