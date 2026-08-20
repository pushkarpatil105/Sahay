# Nari Shakti: Technical Deep-Dive & Architecture Manual

This document provides a exhaustive, step-by-step technical explanation of how Nari Shakti functions, mapping every major feature to its specific code files and dependencies.

---

## 1. High-Level SOS Lifecycle (Step-Wise)

### Step 1: Detection (The Triggers)
The app monitors for 4 types of triggers simultaneously:
1.  **UI Manual Tap**: User taps the SOS button in `home_screen.dart`.
2.  **Shake Gesture**: `ShakeDetectionForegroundService.kt` (Android Sensor) monitors the accelerometer.
3.  **Hardware Buttons**: `VolumeButtonAccessibilityService.kt` intercepts 5x Volume Down presses.d
4.  **Voice Keyword**: `protection_service.dart` (Dart) uses the microphone to listen for "Bachao" or "Help Me".

### Step 2: Immediate Intervention (The Countdown)
- If triggered via background (Shake/Volume/Voice), the **Native Android Layer** launches `SosCountdownActivity.kt`.
- This activity uses `setShowWhenLocked(true)` and `WindowManager` flags to **pierce the lock screen**.
- It shows a 5-second countdown with an "I AM SAFE" cancel button.

### Step 3: SOS Activation (The Core)
When the timer hits zero, a `MethodChannel` signal is sent to `sos_service.dart`.
- An **SOS Document ID** is instantly pre-generated locally.
- The UI is immediately pushed to `sos_active_screen.dart`.
- Simultaneously, a background thread starts:
    - **Firestore**: Creates an entry in `sos_events` with `status: active`.
    - **Live Tracking**: Pushes sub-second coordinates to `live_location/UID` in **Firebase Realtime Database**.

### Step 4: Evidence & Notification
`evidence_service.dart` and `video_recording_service.dart` orchestrate the payload:
- **Location**: Continuous GPS pings.
- **SMS**: Sends SMS with the user's name and Google Maps link via `MainActivity.kt`'s native SMS bridge.
- **Audio/Video**: Records ambient evidence files.

### Step 5: Preservation (The Upload)
- Once the user cancels or the app stops, all files are bundled into a `.zip` by `archive`.
- `upload_queue_service.dart` attempts to push this to the cloud.
- If it fails (no internet), it is saved in a **Persistent Queue** inside `shared_preferences` for later retry.

---

## 2. File-by-File Technical Breakdown

### Core Services (`lib/core/services/`)

| File Name | Responsibility | Tech/Dependency Used |
| :--- | :--- | :--- |
| `sos_service.dart` | Orchestrates the start and stop of an emergency event. | `firebase_auth`, `cloud_firestore`, `firebase_database` |
| `evidence_service.dart` | Manages location logging, audio recording, and SMS firing. | `geolocator`, `record`, `flutter_sms` |
| `upload_queue_service.dart` | A persistent background worker that retries failed evidence uploads. | `connectivity_plus`, `shared_preferences` |
| `protection_service.dart` | The background "heartbeat" that keeps voice detection alive. | `flutter_foreground_task`, `speech_to_text` |
| `sos_countdown_service.dart` | Manages the Dart-side countdown timer for Voice SOS. | `MainActivity` MethodChannels |
| `lock_screen_sos_service.dart` | Bridges native "Lock Screen" signals (Shake/Buttons) to Dart logic. | `MethodChannel('com.narishakti.app/shake_service')` |

### Native Android Layer (`android/app/src/main/kotlin/...`)

| File Name | Responsibility | Specific Implementation |
| :--- | :--- | :--- |
| `MainActivity.kt` | The "Bridge". Handles SMS, app foregrounding, and permission redirects. | `MethodChannel`, `Intent.FLAG_ACTIVITY_NEW_TASK` |
| `ShakeDetectionForegroundService.kt` | Monitors hardware sensors 24/7. | `SensorEventListener`, `PowerManager.WakeLock` |
| `VolumeButtonAccessibilityService.kt` | Intercepts physical hardware clicks. | `AccessibilityService`, `onKeyEvent` |
| `SosCountdownActivity.kt` | The native UI that shows over the lock screen. | `setShowWhenLocked`, `setTurnScreenOn` |

### UI Layer (`lib/screens/`)

| Folder/File | Responsibility | Key Feature |
| :--- | :--- | :--- |
| `home/home_screen.dart` | Main Dashboard. | Custom `onTapDown` SOS button logic. |
| `sos/sos_active_screen.dart` | The "Emergency View". | Live countdown, "I am Safe" button, status indicators. |
| `map/safety_map_screen.dart` | Integrated Safety. | Heatmaps, Google Maps integration (`google_maps_flutter`). |

---

## 3. Package & Dependency Mapping

**Why did we use these specific packages?**

1.  **`firebase_database` (Realtime Database)**:
    - *Purpose*: Standard Firestore is too slow for "Live Tracking". RTDB allows <100ms latency for updating your location on the Safety Map during a chase.
2.  **`flutter_foreground_task`**:
    - *Purpose*: Android kills apps in the background. This package creates a "Foreground Service" (the persistent notification) that prevents the OS from killing our Voice and Shake listeners.
3.  **`geolocator`**:
    - *Purpose*: Fetches location with `LocationAccuracy.high`. Used in `sos_service.dart` to pin exactly where the user is within 5-10 meters.
4.  **`record`**:
    - *Purpose*: Lightweight audio recording. Used in `evidence_service.dart` to capture ambient sound evidence without draining the battery like video.
5.  **`archive`**:
    - *Purpose*: Bundles audio files + JSON location logs into a single `SOS_Evidence.zip`. This makes the upload much more reliable on weak 2G/3G signals.
6.  **`connectivity_plus`**:
    - *Purpose*: Inside `upload_queue_service.dart`, this triggers an immediate upload attempt the moment it detects the user has regained internet access.

---

## 4. Backend & Database Structure

### Firestore Schema
-   **`users/`**: Stores UID, name, and `emergency_contacts` (List of Map).
-   **`sos_events/`**: Tracks every trigger. Stores `user_id`, `timestamp`, `location` (lat/lng), `triggered_by` (shake/voice/manual), and `status` (active/cancelled).
-   **`notifications/`**: Stores user-specific alerts about danger zones or SOS activations.

### Cloud Storage
-   **Upload Pipeline**: Evidence ZIPs -> Cloudinary (External) -> URL saved back to Firestore Event.
-   This split prevents your Firebase Storage from filling up with large raw forensic data while keeping the metadata fast in Firestore.
