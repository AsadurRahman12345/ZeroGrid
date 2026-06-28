<p align="center">
  <img src="https://raw.githubusercontent.com/AsadurRahman12345/ZeroGrid/main/assets/zerogrid_logo.png" alt="ZeroGrid Logo" width="200" onerror="this.style.display='none'"/>
</p>

<h1 align="center">ZeroGrid</h1>

<p align="center">
  <strong>An Off-Grid, Serverless, End-to-End Encrypted Mesh Messaging Network.</strong>
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#architecture">Architecture</a> •
  <a href="#getting-started">Getting Started</a> •
  <a href="#tech-stack">Tech Stack</a>
</p>

---

## 🚀 Overview

**ZeroGrid** is a decentralized, peer-to-peer (P2P) messaging application built for environments where the internet is unavailable, restricted, or compromised. It uses **Google Nearby Connections** (Bluetooth LE & Wi-Fi Direct) to form localized mesh networks, allowing messages to hop securely across devices until they reach their intended recipient. 

Whether you're off the grid, at a crowded festival, or dealing with an internet outage, ZeroGrid keeps you connected.

## ✨ Features

- **🌐 100% Serverless & Offline:** No internet, no cell towers, no central servers.
- **🛡️ End-to-End Encryption (E2EE):** Every message is encrypted using X25519 ECDH key exchange and AES-256-GCM. 
- **🔗 Multi-Hop Mesh Routing:** If your target is out of range, ZeroGrid seamlessly routes your encrypted message through intermediate peers (`hopCount`).
- **📱 Background Persistence:** Runs securely in the background using Android Foreground Services and iOS Background Tasks to keep the mesh alive.
- **💾 Local Storage:** Messages and Peer Keys are persisted locally using Hive (NoSQL).
- **🎨 OLED Dark Theme:** Beautiful, futuristic UI written in Flutter with Cyber Teal accents and OLED absolute black backgrounds.

## 🛠️ Architecture

ZeroGrid utilizes a `P2P_CLUSTER` strategy to maximize connection resiliency. 

1. **Discovery:** Devices simultaneously advertise and scan using Bluetooth Low Energy (BLE).
2. **Connection:** When a peer is found, a high-bandwidth Wi-Fi Direct socket is negotiated.
3. **Key Exchange:** Ephemeral ECDH public keys are immediately exchanged.
4. **Transmission:** Messages are serialized to bytes and transmitted securely across the mesh. Intermediate nodes can relay packets but cannot decrypt them.

## 💻 Tech Stack

- **Frontend:** [Flutter](https://flutter.dev/) (Dart)
- **P2P Engine:** [Nearby Connections API](https://developers.google.com/nearby/connections/overview) 
- **Cryptography:** [cryptography](https://pub.dev/packages/cryptography) package (X25519, AES-256-GCM)
- **Database:** [Hive](https://docs.hivedb.dev/) (Local Key-Value Store)
- **Background Execution:** `flutter_background_service`

## 🏁 Getting Started

### Prerequisites
- Flutter SDK (`>=3.0.0`)
- Android Studio / Xcode

### Installation
1. Clone the repository:
   ```bash
   git clone https://github.com/AsadurRahman12345/ZeroGrid.git
   cd ZeroGrid
   ```
2. Install dependencies:
   ```bash
   flutter pub get
   ```
3. Run the app:
   ```bash
   flutter run
   ```

*(Note: P2P connections require physical devices; simulators do not support Wi-Fi Direct / BLE scanning).*

## 🔒 Security Notice
ZeroGrid is designed to be highly resilient and secure. However, as with all mesh networks, metadata (such as the volume of traffic or packet routing paths) may be visible to intermediate nodes, even though the message payload itself remains strictly end-to-end encrypted.

---
<p align="center">Built with 💙 using Flutter.</p>
