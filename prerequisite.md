# Prerequisites for Running Nari Shakti

This project is a Flutter app with Firebase, location, audio, camera, and background-service dependencies. Follow this guide before running it on a new device to avoid version mismatches and dependency clashes.

## 1. Required Software

- Flutter SDK `3.11.1` or compatible with the version pinned by this repository.
- Dart SDK that ships with the installed Flutter SDK.
- Android Studio with the Android SDK installed.
- Git.
- A physical Android phone for the full experience. Some features rely on sensors, background services, SMS, Bluetooth, or permission flows that are limited in emulators.

## 2. Recommended Environment

- On Windows, use the Android Studio bundled JBR 21 for Gradle builds:
  `D:\Android-Studio\android studio\jbr`
- If you already have another Java version installed, do not let Gradle pick Java 26.x for this project. That is a common source of build failures.
- If a build fails after changing Java versions, run a clean rebuild because Kotlin caches can become stale.

## 3. Files This Project Needs

These files must be present for the app to run correctly:

- `android/app/google-services.json`
- `lib/firebase_options.dart`
- `.env`

The first two are already part of the project setup. The `.env` file is intentionally ignored by Git, so each person running the app needs their own local copy or a securely shared copy with matching values.

## 4. Environment Variables

Create a `.env` file in the project root with the values expected by the app. Use the same variable names below:

```env
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_PHONE_NUMBER=

CLOUDINARY_CLOUD_NAME=
CLOUDINARY_API_KEY=
CLOUDINARY_API_SECRET=

FIREBASE_API_KEY=
FIREBASE_AUTH_DOMAIN=
FIREBASE_DATABASE_URL=
FIREBASE_PROJECT_ID=
FIREBASE_STORAGE_BUCKET=
FIREBASE_MESSAGING_SENDER_ID=
FIREBASE_APP_ID=
```

Notes:

- These values must match the Firebase and third-party services configured for the app.
- Do not commit `.env` to Git.
- If the project owner gives you a working `.env`, keep it private and local.

## 5. First-Time Setup

1. Clone the repository.
2. Open the project root in VS Code or Android Studio.
3. Verify that the files listed above exist.
4. Make sure Flutter is on your PATH.
5. On Windows, confirm Gradle is using the Android Studio JBR 21 path mentioned above.
6. Run `flutter pub get` to fetch packages.

## 6. Run The App

```bash
flutter clean
flutter pub get
flutter run
```

If you are targeting a specific device, connect it first and use `flutter devices` to confirm it is visible.

## 7. Common Fixes If It Fails

- If dependency resolution is inconsistent, delete `.dart_tool`, run `flutter clean`, and then run `flutter pub get` again.
- If Android builds fail with Java-related errors, switch Gradle back to the Android Studio bundled JBR 21.
- If Firebase features fail, check that `google-services.json`, `lib/firebase_options.dart`, and `.env` all belong to the same Firebase project.
- If permissions or background features do not work, test on a real Android device instead of an emulator.

## 8. Quick Checklist For A Friend

- Install Flutter and Android Studio.
- Use JBR 21 on Windows.
- Get the project files: `google-services.json`, `firebase_options.dart`, and `.env`.
- Run `flutter pub get`.
- Run `flutter run` on a real Android phone.
