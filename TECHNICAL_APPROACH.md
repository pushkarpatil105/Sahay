# 🛠️ Nari Shakti: Technical Approach & Innovation Strategy

### Overview
Nari Shakti is not just a "safety app"—it is a **Proactive Safety Agent**. The technical approach centers on bypassing traditional mobile operating system limitations to ensure help is accessible in high-stress, zero-time situations where unlocking a phone is impossible.

---

## 1. Core Innovation: The "Hardware-First" Architecture
Most safety apps fail because they require the user to:
1. Unlock the phone.
2. Find the app icon.
3. Press a button.

**Our Approach**: We shifted the primary triggers to the **Hardware and OS Kernel level** using Native Android MethodChannels and Specialized Services.

### A. The "Lock-Screen Pierce" Maneuver
Using Android's `WindowManager` flags (`FLAG_SHOW_WHEN_LOCKED`, `FLAG_TURN_SCREEN_ON`, `FLAG_DISMISS_KEYGUARD`), we developed a custom UI bridge. This allows our SOS interface to "rip" through the lock screen instantly upon a trigger, enabling immediate user interaction without a passcode.

### B. OS-Level Hardware Listeners
- **Accessibility Service Interception**: We utilize a custom `AccessibilityService` to listen for global key events. By counting exactly 5 rapid presses of the `VOLUME_DOWN` key, we trigger an emergency event without the user ever touching the screen.
- **Native Sensor Fusion**: A Kotlin-based `ForegroundService` monitors the accelerometer at 50Hz. We use a high-pass filter to distinguish between a "phone drop" and an "intentional emergency shake."

---

## 2. Agentic Safety Engine (Always-On Intelligence)
We implemented a **Multi-Layered Detection Engine** that operates as a background agent.

- **Proactive Voice Guard**: Using the `flutter_foreground_task` wrapper, we maintain a persistent Dart isolate that performs continuous Speech-to-Text (STT) analysis. It filters for specific "Panic Keywords" using local NLP matching.
- **Fail-Safe Timer (Dead Man's Switch)**: For high-risk situations (e.g., entering a taxi), users can set a `SafeTimer`. If the user does not manually "Check-In" before the timer expires, the Agent transition from "Monitoring" to "Emergency" mode automatically.

---

## 3. Resilient Forensic Pipeline
In an emergency, data is evidence. We built a **Write-Ahead Logging (WAL)** style evidence pipeline to ensure data survives even if the device is powered off or destroyed.

1. **Chunked Encoding**: Instead of recording one long video, we capture evidence in 30-second encrypted chunks.
2. **Local Atomic Packaging**: Chunks, metadata, and GPS logs are immediately bundled into an `archive (ZIP)` file with a forensic manifest.
3. **The "Resilient Queue" Pattern**: We implemented a `PersistentUploadQueueService`. It stores ZIP paths in local storage and uses a exponential-backoff retry strategy integrated with `ConnectivityPlus`. If a user loses internet in a basement, the app will "hunt" for a signal and flush the evidence the moment it's restored.

---

## 4. Hybrid Cloud & Real-time Sync
We opted for a split-backend strategy to optimize for **speed** and **reliability**:

| Component | Technology | Rationale |
| :--- | :--- | :--- |
| **Live Tracking** | Firebase Realtime DB | Lowest latency for sub-second GPS streaming. |
| **SOS State** | Cloud Firestore | ACID compliance for critical event status changes. |
| **Evidence Bundles** | Cloudinary / HTTP | Optimized for large binary file handling and secure direct link sharing via SMS. |

---

## 5. Security & Privacy by Design
- **Secure Link Sharing**: Links sent to emergency contacts are obfuscated and point to private storage buckets.
- **Permissions Matrix**: We implemented a rigorous `PermissionHandler` flow to ensure the app has "Draw Over Other Apps" and "Accessibility" permissions, which is critical for the hardware triggers to function.

---

## 🏗️ Future Technical Roadmap
- **Edge AI Fall Detection**: Implementing TensorFlow Lite models on-device to detect physical struggles or falls without cloud latency.
- **Distributed Mesh Alerts**: Using Bluetooth Low Energy (BLE) to alert nearby "Nari Shakti" users even when cellular networks are unavailable.

---
**Technical Vision**: *Moving from reactive apps to proactive hardware-integrated safety agents.*
