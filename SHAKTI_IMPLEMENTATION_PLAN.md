# 🚀 SHAKTI-OMNI - FULL IMPLEMENTATION PLAN

## PROJECT STATUS: 30% COMPLETE ⚡

### ✅ Currently Implemented
- Firebase Authentication (Phone OTP)
- Emergency Contacts UI
- Medical Data Service
- Home Screen Layout
- Firebase Infrastructure

### ❌ Missing Components
- 70% of core features need implementation

---

## 📋 DETAILED IMPLEMENTATION ROADMAP

### PHASE 1: CORE INFRASTRUCTURE (Complete Foundation First)

#### 1️⃣ Emergency Contacts Service ⭐ CRITICAL
**Status:** UI exists, but no backend service
**File to Create:** `lib/services/emergency_contacts_service.dart`
**Tasks:**
- Create model class for emergency contacts
- Methods: `addContact()`, `getContacts()`, `updateContact()`, `deleteContact()`
- Store in Firestore: `users/{userId}/emergencyContacts/`
- Real-time sync with `StreamBuilder`

**Estimated Time:** 2-3 hours
**Dependencies:** cloud_firestore, uuid

---

#### 2️⃣ Location System ⭐ CRITICAL
**Status:** Not started
**Files to Create:**
- `lib/services/location_service.dart`
- `lib/services/maps_service.dart`
- `lib/screens/maps/map_view_screen.dart`

**Tasks:**
- Implement live location tracking
- Get current location periodically
- Store location update in Firestore
- Display on Google Maps
- Detect nearby police stations

**Estimated Time:** 8-10 hours
**Dependencies:** geolocator, google_maps_flutter, google_places_api

**Android Permissions (AndroidManifest.xml):**
```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
```

**iOS Permissions (Info.plist):**
```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>We need location to share with emergency contacts</string>
```

---

#### 3️⃣ User Profile Service ⭐ CRITICAL
**Status:** Partially done
**File to Create:** `lib/services/user_profile_service.dart`
**Firestore Structure:**
```json
users/{userId} = {
  name: string,
  phone: string,
  email: string,
  bloodType: string,
  emergencyContacts: reference[],
  medicalData: reference,
  createdAt: timestamp,
  updatedAt: timestamp
}
```

**Estimated Time:** 2-3 hours

---

### PHASE 2: EMERGENCY RESPONSE SYSTEM

#### 4️⃣ SOS System - Multiple Triggers ⭐ CRITICAL
**Status:** Only UI button exists, no functionality
**Files to Create:**
- `lib/services/sos_service.dart`
- `lib/services/recording_service.dart`
- `lib/services/alert_service.dart`
- `lib/models/sos_event.dart`

**Implementation Steps:**
1. **Power Button Detection** (5× press)
   - Use `accessibility_service` or native Android code
   - Track consecutive presses with timestamp
   - Trigger SOS if 5 presses within 5 seconds

2. **Shake Detection**
   - Use `sensors_plus` package
   - Monitor accelerometer data
   - Detect shake intensity threshold
   - Trigger SOS on high-intensity shake

3. **Voice Keyword Detection**
   - Use `speech_to_text` or `google_speech_api`
   - Listen for keywords: "Help", "Bachao", "Emergency"
   - Keep audio stream minimal to battery
   - Must work in background

4. **Manual SOS Button**
   - Already designed in UI
   - Implement `onLongPress` for press-and-hold

5. **SOS Trigger Flow:**
```
SOS Triggered
    ↓
1. Record user location
2. Start audio recording (5 min)
3. Start front camera recording (background)
4. Send alert to all emergency contacts
5. Share live location link
6. Display alert countdown (user can cancel)
7. Store evidence in local storage
```

**Estimated Time:** 15-20 hours
**Dependencies:** 
- sensors_plus
- speech_to_text
- camera
- record (audio)
- connectivity_plus

---

#### 5️⃣ Evidence Recording System ⭐ CRITICAL
**Status:** Not started
**Files to Create:**
- `lib/services/recording_service.dart`
- `lib/models/evidence.dart`

**Features:**
- Auto record audio when SOS triggered
- Capture front camera video (self-recording)
- Capture back camera video (surroundings)
- Compress to ZIP format
- Upload to Firebase Storage with encryption
- Save evidence metadata to Firestore

**Recording Quality:**
- Audio: AAC, 128kbps
- Video: H.264, 720p, 30fps, 2Mbps bitrate
- Max record time: 5 minutes (extendable)

**Storage Path:** `users/{userId}/evidence/{eventId}/`

**Estimated Time:** 12-15 hours
**Dependencies:**
- camera
- record (audio)
- archive (ZIP compression)
- firebase_storage
- permission_handler

---

#### 6️⃣ Live Location Sharing
**Status:** Not started
**Files to Create:**
- `lib/services/live_location_service.dart`
- `lib/screens/location/live_tracking_screen.dart`

**Features:**
- Generate shareable link for each SOS event
- Real-time location updates (3-5 second intervals)
- Update Firestore with location every 3 seconds
- Share via SMS, WhatsApp, or direct link
- Trackable by emergency contacts

**Estimated Time:** 8-10 hours
**Dependencies:**
- geolocator
- share_plus
- url_launcher

---

#### 7️⃣ Alert Service
**Status:** Not started
**Files to Create:**
- `lib/services/alert_service.dart`
- `lib/models/alert.dart`

**Alert Sending Methods:**
1. **Firebase Cloud Messaging (FCM)** - Primary
   - Push notification with location
   - Emergency details
   - Live tracking link

2. **SMS Fallback** - No internet required
   - Send to emergency contacts
   - Location + SOS event ID

3. **WhatsApp Integration** - Optional
   - Send message via WhatsApp Business API
   - Include location link

**Estimated Time:** 10-12 hours
**Dependencies:**
- firebase_messaging
- twilio_flutter (SMS)
- whatsapp_unilink (WhatsApp)

---

### PHASE 3: SAFETY INTELLIGENCE FEATURES

#### 8️⃣ Crowd Density Safety Map
**Status:** Not started
**Files to Create:**
- `lib/services/safety_map_service.dart`
- `lib/screens/safety/safety_map_screen.dart`
- `lib/models/safety_zone.dart`

**Features:**
- Display map with color-coded zones:
  - 🟢 Green = Safe (Low crime)
  - 🟡 Yellow = Medium (Moderate activity)
  - 🔴 Red = Dangerous (High crime/activity)

**Data Sources:**
- Crime database API
- User-reported incidents
- Public crowd density data
- Historical crime data

**Estimated Time:** 10-12 hours
**Dependencies:**
- google_maps_flutter
- Firebase Realtime Database or external API

---

#### 9️⃣ Nearby Police Station Locator
**Status:** Not started
**Files to Create:**
- `lib/services/police_station_service.dart`
- `lib/screens/safety/police_locator_screen.dart`

**Features:**
- Find nearest police stations
- Show on map with distance
- Navigation directions (Google Maps app)
- Direct call button
- Emergency SOS from this screen

**Estimated Time:** 5-6 hours
**Dependencies:**
- google_places_flutter
- maps_launcher

---

### PHASE 4: SMART SAFETY FEATURES

#### 🔟 Safe Code Timer
**Status:** Not started
**Files to Create:**
- `lib/services/safe_timer_service.dart`
- `lib/screens/safety/safe_timer_screen.dart`

**Use Case:** User traveling alone
**Flow:**
1. User starts timer (5-30 minutes configurable)
2. Timer displays on screen
3. When timer ends → prompt for "Safe Code"
4. If user doesn't enter code → Trigger SOS
5. Safe code = 4-digit user-set PIN

**Estimated Time:** 6-8 hours
**Dependencies:**
- local_auth (biometric backup)

---

#### 1️⃣1️⃣ Dead Man Switch
**Status:** Not started
**Files to Create:**
- `lib/services/dead_man_switch_service.dart`
- `lib/screens/safety/dead_man_switch_screen.dart`

**Use Case:** Taxi/Uber travel or isolated situations
**Flow:**
1. User starts ride
2. Set timer (20-30 minutes)
3. Every 5 minutes → show alert to confirm safety
4. If unconfirmed for 2 consecutive alerts → Trigger SOS
5. Automatic if phone is locked/inactive

**Features:**
- Background task execution
- Vibration alerts
- Sound alerts
- Emergency contacts notified

**Estimated Time:** 8-10 hours
**Dependencies:**
- workmanager (background tasks)
- wakelock (keep screen on option)

---

#### 1️⃣2️⃣ Offline Support - Works Without Internet
**Status:** Not started
**Files to Create:**
- `lib/services/offline_service.dart`
- `lib/services/sync_service.dart`

**Fallback Systems:**
1. **SMS Alerts** - Send via Twilio/Fast2SMS
2. **Last Known Location** - Store locally
3. **Bluetooth Sharing** - Optional future feature
4. **Local Storage** - Queue events while offline
5. **Auto-Sync** - When connection restored

**Estimated Time:** 8-10 hours
**Dependencies:**
- connectivity_plus
- sqflite (local database)
- shared_preferences (cache)

---

### PHASE 5: MEDICAL EMERGENCY SYSTEM

#### 1️⃣3️⃣ Medical Info Card Display
**Status:** Partially done (service created, UI missing)
**Files to Create:**
- `lib/screens/profile/medical_profile_screen.dart` (complete)
- `lib/screens/emergency/medical_display_card.dart` (for responders)

**Display When:**
- SOS triggered
- During emergency contacts notification
- Accessible without authentication

**Features:**
- Prominent display of:
  - Blood type (large, bold)
  - All allergies
  - Current medications
  - Medical conditions
  - Pregnancy status
  - Emergency info notes
- Edit/Update information
- Last updated timestamp

**Estimated Time:** 4-5 hours
**Dependencies:** Already have medical_data_service

---

## 📦 DEPENDENCIES TO ADD TO pubspec.yaml

```yaml
dependencies:
  # Location & Maps
  geolocator: ^10.1.0
  google_maps_flutter: ^2.5.0
  
  # Recording
  camera: ^0.10.5
  record: ^4.4.4
  
  # Sensors
  sensors_plus: ^1.4.0
  
  # Permissions
  permission_handler: ^11.4.4
  
  # State Management
  provider: ^6.1.0
  
  # Connectivity
  connectivity_plus: ^5.0.2
  
  # Background Tasks
  workmanager: ^0.5.1
  
  # Utilities
  uuid: ^4.0.0
  share_plus: ^7.2.1
  url_launcher: ^6.2.4
  intl_phone_number_input: ^0.7.4
  local_auth: ^2.1.0
  archive: ^3.4.0
  
  # SMS & Messaging
  twilio_flutter: ^0.1.0
  firebase_messaging: ^14.7.0  # Already have
  
  # Speech
  speech_to_text: ^6.4.0
  
  # Local Storage
  sqflite: ^2.3.0
  shared_preferences: ^2.2.2
  
  # Vibration & Sound
  vibration: ^1.8.4
  audioplayers: ^5.2.1
```

---

## 🗂️ FOLDER STRUCTURE TO CREATE

```
lib/
├── services/
│   ├── emergency_contacts_service.dart       ⭐
│   ├── location_service.dart                 ⭐
│   ├── maps_service.dart
│   ├── user_profile_service.dart             ⭐
│   ├── sos_service.dart                      ⭐
│   ├── recording_service.dart                ⭐
│   ├── alert_service.dart
│   ├── live_location_service.dart
│   ├── safety_map_service.dart
│   ├── police_station_service.dart
│   ├── safe_timer_service.dart
│   ├── dead_man_switch_service.dart
│   ├── offline_service.dart
│   └── medical_data_service.dart             ✅ (created)
├── models/
│   ├── emergency_contact.dart                ⭐
│   ├── sos_event.dart                        ⭐
│   ├── evidence.dart
│   ├── alert.dart
│   ├── safety_zone.dart
│   ├── medical_data.dart                     ✅ (in service)
│   └── user_profile.dart
├── screens/
│   ├── auth/                                 ✅ (exists)
│   ├── home/                                 ✅ (exists)
│   ├── profile/
│   │   ├── emergency_contacts_screen.dart    ✅ (exists)
│   │   ├── medical_profile_screen.dart       (partial)
│   │   └── profile_setup_screen.dart         (exists)
│   ├── maps/                                 ⭐
│   │   ├── map_view_screen.dart
│   │   └── live_tracking_screen.dart
│   ├── safety/                               ⭐
│   │   ├── safety_map_screen.dart
│   │   ├── police_locator_screen.dart
│   │   ├── safe_timer_screen.dart
│   │   └── dead_man_switch_screen.dart
│   ├── emergency/                            ⭐
│   │   ├── sos_activation_screen.dart
│   │   ├── sos_confirmation_screen.dart
│   │   └── medical_display_card.dart
│   └── splash_screen.dart                    ✅ (exists)
├── widgets/                                  ⭐
│   ├── sos_button.dart
│   ├── contact_card.dart
│   ├── medical_info_card.dart
│   └── danger_zone_map.dart
├── providers/                                ⭐
│   ├── auth_provider.dart
│   ├── location_provider.dart
│   ├── sos_provider.dart
│   ├── emergency_contacts_provider.dart
│   └── offline_provider.dart
└── utils/
    ├── constants.dart
    ├── validators.dart
    └── storage_helper.dart
```

---

## 📊 IMPLEMENTATION PRIORITY (By Value & Dependencies)

### Week 1: CRITICAL FOUNDATION
1. **Emergency Contacts Service** (2-3 hrs) - Blocks other features
2. **User Profile Service** (2-3 hrs) - Needed for all data
3. **Location Service** (8-10 hrs) - Needed for SOS & tracking

### Week 2: CORE SOS
4. **SOS System - Manual Button** (3-4 hrs) - Simplest SOS trigger
5. **Alert Service** (10-12 hrs) - Keeps system reliable
6. **Recording Service** (12-15 hrs) - Evidence collection

### Week 3: ADVANCED SOS
7. **Power Button Detection** (6-8 hrs) - Complex native code
8. **Shake Detection** (3-4 hrs) - Easier than power button
9. **Voice Keyword Detection** (8-10 hrs) - Requires ML/Speech API

### Week 4: SAFETY FEATURES
10. **Safe Code Timer** (6-8 hrs) - Simple timer logic
11. **Dead Man Switch** (8-10 hrs) - Background tasks needed
12. **Offline Support** (8-10 hrs) - Fallback mechanism

### Week 5: INTELLIGENCE & PROFILE
13. **Police Station Locator** (5-6 hrs) - Maps integration easy
14. **Safety Map** (10-12 hrs) - Data sources required
15. **Medical Profile UI** (4-5 hrs) - Display only

---

## 🔐 FIRESTORE SECURITY RULES

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    
    // User documents
    match /users/{userId} {
      allow read, write: if request.auth.uid == userId;
      
      // Emergency contacts - user only
      match /emergencyContacts/{document=**} {
        allow read, write: if request.auth.uid == userId;
      }
      
      // Medical data - user only
      match /medicalData/{document=**} {
        allow read, write: if request.auth.uid == userId;
      }
      
      // SOS events - user & emergency contacts
      match /sosEvents/{eventId} {
        allow read: if request.auth.uid == userId || 
                       userId in request.auth.token.emergencyContacts;
        allow write: if request.auth.uid == userId;
      }
      
      // Location tracking - real-time
      match /locations/{document=**} {
        allow read, write: if request.auth.uid == userId;
      }
    }
    
    // Deny all other access
    match /{document=**} {
      allow read, write: if false;
    }
  }
}
```

---

## 📱 ANDROID MANIFEST PERMISSIONS

Add to `android/app/src/main/AndroidManifest.xml`:

```xml
<!-- Location -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>

<!-- Camera & Recording -->
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>

<!-- SMS & Calling -->
<uses-permission android:name="android.permission.SEND_SMS"/>
<uses-permission android:name="android.permission.CALL_PHONE"/>

<!-- Phone State -->
<uses-permission android:name="android.permission.READ_PHONE_STATE"/>

<!-- Contacts -->
<uses-permission android:name="android.permission.READ_CONTACTS"/>
<uses-permission android:name="android.permission.WRITE_CONTACTS"/>

<!-- Internet & Networking -->
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>

<!-- Sensors -->
<uses-permission android:name="android.permission.BODY_SENSORS"/>

<!-- Files -->
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"/>

<!-- Background -->
<uses-permission android:name="android.permission.WAKE_LOCK"/>

<!-- Accessibility (for power button detection) -->
<uses-permission android:name="android.permission.BIND_ACCESSIBILITY_SERVICE"/>
```

---

## 🎯 NEXT IMMEDIATE STEPS

1. **Add dependencies to pubspec.yaml** (5 min)
   ```bash
   flutter pub add geolocator google_maps_flutter sensors_plus permission_handler
   ```

2. **Create Emergency Contacts Service** (2-3 hrs)
   - Model for emergency contacts
   - CRUD operations
   - Firestore integration

3. **Implement User Profile Service** (2-3 hrs)
   - Save full user profile
   - Link to medical & emergency data

4. **Start Location Service** (8-10 hrs)
   - Get current location
   - Periodic updates
   - Permission handling

---

## ⚠️ ESTIMATED TOTAL TIMELINE

| Phase | Duration | Status |
|-------|----------|--------|
| Phase 1 (Core) | 2 weeks | 30% done |
| Phase 2 (SOS) | 2 weeks | Not started |
| Phase 3 (Intelligence) | 1.5 weeks | Not started |
| Phase 4 (Smart) | 1.5 weeks | Not started |
| Phase 5 (Medical) | 3-4 days | 20% done |
| Testing & Fixes | 1 week | Pending |
| **TOTAL** | **~8 weeks** | **30% Complete** |

---

## 📞 KEY CONSIDERATIONS

- ✅ **Always request permissions before using**
- ✅ **Handle offline scenarios gracefully**
- ✅ **Log all SOS events for security audit**
- ✅ **Encrypt sensitive data (recordings, locations)**
- ✅ **Test on real devices (not emulator)**
- ✅ **Battery optimization for background services**
- ✅ **GDPR compliance for location tracking**
- ✅ **Accessibility features for emergency buttons**

---

Generated: March 11, 2026
Project: Nari Shakti (SHAKTI-OMNI)
