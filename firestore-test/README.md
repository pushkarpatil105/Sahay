# Firestore demo-service request test

This folder is independent from the Flutter app. It uses the Firebase Admin SDK and a Firebase service-account key to write, listen to, and update a demo request in Cloud Firestore.

## 1. Create and save a service-account key

1. Open the [Firebase Console](https://console.firebase.google.com/) and select the Firebase project to test.
2. Click the gear icon next to **Project Overview**, then select **Project settings**.
3. Open the **Service accounts** tab.
4. Click **Generate new private key**, then confirm the download.
5. Save the downloaded JSON key in this folder as `service-account-key.json`.

Do not commit this key or share it. It has administrator access to the Firebase project. `service-account-key.json` is ignored by Git in this test folder.

## 2. Set `GOOGLE_APPLICATION_CREDENTIALS`

Use the absolute path to the JSON file you downloaded.

### Mac/Linux

```bash
cd firestore-test
export GOOGLE_APPLICATION_CREDENTIALS="$PWD/service-account-key.json"
```

To make this persistent, add the `export` command to your shell profile, such as `~/.zshrc` or `~/.bashrc`.

### Windows PowerShell

```powershell
cd firestore-test
$env:GOOGLE_APPLICATION_CREDENTIALS = "$PWD\service-account-key.json"
```

This applies to the current PowerShell window. Set it again in every new terminal, or add it through Windows Environment Variables if you need it permanently.

### Windows Command Prompt

```bat
cd firestore-test
set GOOGLE_APPLICATION_CREDENTIALS=%CD%\service-account-key.json
```

## 3. Install dependencies

From the project root:

```bash
cd firestore-test
npm install
```

## 4. Run the real-time test

Open three terminals. In every terminal, first change into `firestore-test` and set `GOOGLE_APPLICATION_CREDENTIALS` as shown above.

1. In terminal one, start the listener and leave it running:

   ```bash
   npm run listen
   ```

2. In terminal two, create the pending test request:

   ```bash
   npm run write
   ```

3. In terminal three (or terminal two again), update that request:

   ```bash
   npm run update
   ```

The listener must log an `ADDED` event when `write-request.js` creates `service_requests/req_test_001`, followed by a `MODIFIED` event when `update-request.js` changes its status to `accepted`. Press `Ctrl+C` in the listener terminal when finished.

## Scripts

- `write-request.js` writes `service_requests/req_test_001` with the exact requested demo-request fields and Firestore server timestamps.
- `listen-requests.js` listens in real time to `service_requests` where `is_demo == true` and prints every added, modified, or removed document with its full data.
- `update-request.js` updates `req_test_001` to `accepted`, assigns `provider_001` / `City Hospital`, and refreshes `updated_at` with a server timestamp.
