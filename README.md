# 🚨 Nari Shakti: Empowering Women through Agentic Safety

[![Flutter](https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev)
[![Firebase](https://img.shields.io/badge/Firebase-039BE5?style=for-the-badge&logo=Firebase&logoColor=white)](https://firebase.google.com/)
[![Cloudinary](https://img.shields.io/badge/Cloudinary-3448C5?style=for-the-badge&logo=Cloudinary&logoColor=white)](https://cloudinary.com/)
[![Twilio](https://img.shields.io/badge/Twilio-F22F46?style=for-the-badge&logo=Twilio&logoColor=white)](https://www.twilio.com/)

**Nari Shakti** is a next-generation personal safety application designed to provide women with a robust, automated, and multi-layered safety net. By leveraging background intelligence, hardware triggers, and cloud-synchronized evidence collection, Nari Shakti ensures that help is only a gesture away, even in the most critical situations.

---

## 🌟 Key Features

### 1. Multi-Dimensional SOS Triggers
Never struggle to unlock your phone in an emergency. Nari Shakti listens when it matters:
- **📳 Shake-to-SOS**: Works even when the phone is locked via a high-performance native Android background service.
- **🗣️ Voice Activation**: Recognizes emergency keywords like *"Help"*, *"Bachao"*, or *"Help Me"* using integrated Speech-to-Text.
- **🔘 Hardware Trigger**: Rapidly press the **Volume Down button 5 times** to trigger SOS instantly via Accessibility Services.
- **🔔 Lock Screen Overlay**: A permanent notification button for one-tap SOS without needing to unlock the device.

### 2. Autonomous Evidence Collection
The app acts as a digital witness when the user cannot:
- **🎥 Stealth Recording**: Automatically captures background video and audio in encrypted chunks.
- **📍 GPS Path Tracking**: Logs a continuous location path, stored locally and synced to the cloud.
- **📦 Evidence Packaging**: Zips all media and logs into a forensic-ready package for legal support.

### 3. Intelligent Cloud & Real-time Integration
- **📡 Live Tracking**: Real-time location sharing via Firebase Realtime Database for pinpoint accuracy.
- **☁️ Cloudinary Evidence Sync**: Automatic background upload of evidence chunks, ensuring data survives even if the phone is destroyed.
- **📥 Upload Queue**: A resilient background service that persists evidence uploads across app restarts and network drops.

### 4. Smart Escalation & Notification
- **📲 SMS Alerts**: Immediate SMS to all emergency contacts with a live Google Maps link.
- **☎️ Twilio Voice Escalation**: If the SOS isn't cancelled within 30 seconds, the app triggers automated voice calls to emergency contacts.
- **⏱️ 2-Minute Safety Net**: An automated "fail-safe" that ends the SOS, uploads all remaining evidence, and notifies contacts if the user doesn't press "I Am Safe" within 2 minutes.

### 5. Community & Prevention
- **🗺️ Safety Heatmap**: Visualize safe and unsafe zones in your city based on real-time community reports.
- **⏲️ Safe Timer**: A proactive "Taxi Mode" or "Walk Home" timer. If not cancelled by the user, SOS triggers automatically.
- **🏥 Medical ID**: Instant access to Blood Group, Allergies, and Emergency Contacts for first responders.

---

## 🏗️ Tech Stack

| Layer | Technology |
| :--- | :--- |
| **Frontend** | Flutter (Dart 3.x) |
| **Authentication** | Firebase Auth (Phone/OTP) |
| **Database** | Cloud Firestore & Firebase Realtime DB |
| **Cloud Storage** | Cloudinary (Evidence Media) |
| **Background Services** | Flutter Foreground Task & Native Android MethodChannels |
| **Hardware Integration** | MethodChannels (Shake Sensors, Accessibility Service) |
| **Communication** | Twilio API (Voice) & Native SMS Manager |

---

## 🚀 Installation & Setup

### Prerequisites
- Flutter SDK (^3.11.1)
- Firebase Account
- Cloudinary Account
- Twilio Account (for voice calls)

### Step-by-Step Selection
1. **Clone the Repository**
   ```bash
   git clone https://github.com/pushkarpatil105/nari_shakti.git
   cd nari_shakti
   ```

2. **Configuration**
   Create a `.env` file in the root directory and add your credentials:
   ```env
   CLOUDINARY_CLOUD_NAME=your_cloud_name
   CLOUDINARY_API_KEY=your_api_key
   CLOUDINARY_API_SECRET=your_api_secret
   TWILIO_ACCOUNT_SID=your_sid
   TWILIO_AUTH_TOKEN=your_token
   TWILIO_PHONE_NUMBER=your_twilio_num
   ```

3. **Install Dependencies**
   ```bash
   flutter pub get
   ```

4. **Run the App**
   ```bash
   flutter run
   ```

---

## 🛡️ Security & Privacy
Nari Shakti prioritizes user privacy. All recorded evidence is stored in private Cloudinary folders and is only accessible via the secure links sent to your trusted emergency contacts or retrieved through your authenticated account.

## 🏆 Hackathon Vision
Nari Shakti was built to demonstrate how **Agentic AI**—AI that can take proactive actions in the physical world—can solve systemic safety issues. By moving away from "Reactive" apps (that wait for a button press) to "Proactive" agents (that detect danger via sensors), we aim to significantly reduce response times in critical emergencies.

## 📖 Additional Documentation
For deep-dives into the system design and implementation details, check out:
- [🏗️ App Architecture Deep Dive](file:///d:/Hacksagon/nari_shakti/APP_ARCHITECTURE_DEEP_DIVE.md)
- [🛠️ Technical Documentation](file:///d:/Hacksagon/nari_shakti/TECHNICAL_DOCUMENTATION.md)
- [📅 Shakti Implementation Plan](file:///d:/Hacksagon/nari_shakti/SHAKTI_IMPLEMENTATION_PLAN.md)

---

**Built with ❤️ for a Safer Future.**
