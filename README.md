# Apple‑OS On‑Device Benchmarking

A tiny SwiftUI app for stress‑testing Apple’s on‑device **LanguageModelSession** (LLM) APIs.  It runs a bank of reasoning + generative prompts multiple times, logs latency/throughput metrics, and exports full CSVs—perfect for quick performance pokes at iPhone/iPad hardware.

---

## ✨ Features

* Warm-start benchmarking mode with configurable trial count (cold-start still a WIP)
* Automatic retry of failed prompts with error logging
* Mean ± SD bar charts for **Latency**, **Tokens**, **TTFT**, and **TPS**
* One‑click CSV export of *all* trial data + separate failure log

---

## 🔧 Requirements

| Tool / OS             | Minimum Version | Notes                                                 |
| --------------------- | --------------- | ----------------------------------------------------- |
| **macOS**             | 14.0 (Sonoma)   |                             |
| **Xcode**             | 16 β or later   | Must include the *iOS 26* & *macOS 15* SDKs           |
| **iOS device**        | iOS 26 β        | iPhone/iPad with an A17/M‑class chip for best results |
| **Developer account** | Free or paid    | Needed to sign & run on physical devices              |

> **Heads‑up:** The app uses the new `FoundationModels` framework (`LanguageModelSession`).  That SDK ships only with Xcode 16+.

---

## 🚀 Quick Start

```bash
# 1. Clone
$ git clone https://github.com/singhh5050/apple-os-on-device-benchmarking.git
$ cd apple-os-on-device-benchmarking

# 2. Open the Xcode project
$ open apple-os-on-device-benchmarking.xcodeproj
```

### Deploy to iPhone (iOS 26)

1. **Plug in** (or pair wirelessly) an iOS 26 device.
2. Allow the *“Trust This Computer”* prompt and enable **Developer Mode** on the phone (Settings ▸ Privacy & Security ▸ Developer Mode).
3. In Xcode, choose your device from the run‑target drop‑down.
4. Xcode will prompt for a signing team—pick your Apple ID (or any team).
5. Press **▶︎ Run**.  The app installs and launches on‑device.
6. Tap **Run Benchmarks**. (and select your desired settings) There's a link to export to *benchmark\_results.csv* when done.

---

## 📂 Project Layout

```
apple-os-on-device-benchmarking
├── Assets.xcassets/          # App icon + accent colour
├── apple_os_on_device_benchmarkingApp.swift  # main SwiftUI file (all logic/UI)
└── apple-os-on-device-benchmarking.xcodeproj/ # Xcode project
```

---

## 🗜️ CSV Columns

| Column       | Meaning                       |
| ------------ | ----------------------------- |
| `prompt`     | Full prompt text              |
| `difficulty` | easy / medium / hard          |
| `type`       | reasoning / generative        |
| `tokens`     | Tokens generated              |
| `ttftMs`     | Time‑to‑first‑token (ms)      |
| `latencyMs`  | Total generation latency (ms) |
| `tps`        | Tokens per second             |

Failures are logged separately with `prompt`, `difficulty`, and the error message.

---

## 🛡️ License

MIT © 2025 Harsh Singh
