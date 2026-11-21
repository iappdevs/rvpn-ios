# R-VPN for iOS

iOS client for [rVPN](https://rvpn.org/) — built on the same production
Rust engine (`rvpn-mobile`) as the official macOS/Android apps and our
Windows client.

## Status: Source Complete — Needs macOS to Build

All Swift source code is written and ready. The Rust engine compiles for
`aarch64-apple-ios`. A GitHub Actions workflow builds on macOS.

To build locally you need **macOS with Xcode** (or use the CI/CD).

## Structure

```
rvpn-ios/
├── Package.swift              Swift Package Manager manifest
├── .github/workflows/
│   └── build-ios.yml          CI: macOS runner → .ipa
└── rvpn-ios-app/
    └── Sources/rvpn-ios-app/
        ├── RVPNApp.swift          Entry point
        ├── ContentView.swift      SwiftUI (Connect, Profiles, Settings)
        ├── AppState.swift         Connection state, profile store
        ├── RustBridge.swift       Swift wrapper for the Rust C API
        ├── RVPNTunnelProvider.swift  NEPacketTunnelProvider (VPN extension)
        └── rvpn_bridge.h          C header for the Rust FFI
```

## Building

### On macOS:
```bash
# 1. Build the Rust engine
cd rVPN-core/rvpn
cargo build --release --target aarch64-apple-ios \
  -p rvpn-mobile --no-default-features --features ios-direct-tun

# 2. Copy the static library
mkdir -p rvpn-ios/rvpn-ios-app/Sources/rvpn-ios-app/Libs
cp target/aarch64-apple-ios/release/librvpn_mobile.a \
   rvpn-ios/rvpn-ios-app/Sources/rvpn-ios-app/Libs/

# 3. Build the Swift app
cd rvpn-ios/rvpn-ios-app
swift build -c release
```

### On Windows/Linux (CI/CD):
Push to GitHub — the workflow in `.github/workflows/build-ios.yml`
builds on a macOS runner automatically.

## Features

- Full-tunnel VPN via NetworkExtension
- Profile management (add/edit/delete)
- TOFU server identity pinning
- DNS-over-HTTPS through the tunnel
- Split tunnel / bypass rules
- Ad blocking
- X3DH + Double Ratchet end-to-end encryption

## Requirements for Distribution

- Apple Developer account
- NetworkExtension entitlement (`com.apple.developer.networking.networkextension`)
- Personal VPN entitlement (`com.apple.developer.networking.vpn.api`)
- App ID with Packet Tunnel Provider capability

## License

AGPL-3.0-or-later (same as rVPN-core)
