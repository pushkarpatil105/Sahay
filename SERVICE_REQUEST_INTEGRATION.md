# Service Request Integration — Shared Spec

**Purpose of this doc:** This is the single source of truth for how the User App (Pushkar) and the Admin Dashboard (teammate) talk to each other through Firebase Firestore. Both sides build independently against this doc. If either side needs to change a field name or status value, it must be updated here first and confirmed with the other person before changing code — do not improvise field names locally.

## 1. The Story / What We're Building

We are building a two-sided emergency/roadside-assistance platform for a hackathon demo:

- **User App** (mobile, built by Pushkar): lets a user request help — ambulance or towing — either from live demo simulation cards or from real static operator listings (Indore towing data, already built).
- **Admin Dashboard** (web, built by teammate): lets a provider (hospital / towing operator, played by teammate at demo time) see incoming requests in real time and Accept / Reject them. Also hosts a separate CCTV accident-detection AI feature, unrelated to this request flow.

**Not included for the hackathon:** real phone calls, real ambulance dispatch, or production deployment. Demo requests are Firestore documents with `is_demo: true`.

### Live demo

1. User taps a **Demo Ambulance Request** card.
2. A request appears immediately on the admin dashboard.
3. Admin rejects it; the phone shows reassigning and receives the new provider assignment.
4. Admin accepts the new assignment; the phone shows accepted and the ETA.
5. User cancels; the dashboard receives the cancellation.
6. Static Indore towing contacts remain below the demo cards and are informational only.

## 2. Architecture

- **Database:** Firebase Firestore in the existing Sahay Firebase project.
- **No custom backend:** both apps read/write Firestore directly using their Firebase SDKs.
- **Real-time sync:** use Firestore snapshot listeners; never poll.
- **Reassignment:** simple client-side admin logic for the hackathon; no Cloud Function required.

## 3. Firestore Collections

Firestore creates collections on first write. Seed 2–3 static `providers` documents manually in Firebase Console.

### 3.1 `service_requests`

One collection handles every service type. Do not make separate collections.

```json
{
  "request_id": "req_001",
  "user_id": "user_123",
  "user_name": "Pushkar",
  "service_type": "ambulance",
  "status": "pending",
  "location": { "lat": 22.7196, "lng": 75.8577 },
  "assigned_provider_id": null,
  "assigned_provider_name": null,
  "is_demo": true,
  "escalation_count": 0,
  "created_at": "server_timestamp",
  "updated_at": "server_timestamp"
}
```

Allowed `service_type` values: `ambulance`, `towing`.

Allowed `status` values: `pending`, `assigned`, `accepted`, `rejected`, `reassigned`, `en_route`, `completed`, `cancelled`.

| Field | Written by |
|---|---|
| `request_id`, `user_id`, `user_name`, `service_type`, `location`, `is_demo`, `created_at` | User App on creation only |
| `status`, `assigned_provider_id`, `assigned_provider_name`, `escalation_count`, `updated_at` | Admin Dashboard, except User App can write `status: "cancelled"` |

### 3.2 `providers`

Static seed data entered in Firebase Console:

```json
{
  "provider_id": "provider_001",
  "name": "City Hospital",
  "service_type": "ambulance",
  "status": "available",
  "is_demo": true
}
```

Suggested providers: `provider_001` City Hospital (ambulance), `provider_002` Backup Hospital (ambulance), and `provider_003` Speedy Towing Co. (towing).

## 4. Event Signal Reference

### 4.1 User creates a request

Create a new `service_requests` document with the shape above, `status: "pending"`, and null provider fields.

### 4.2 Admin listens

Query `is_demo == true AND status == "pending"`, plus `assigned_provider_id == currentProviderId` for routed requests.

### 4.3 Admin accepts or rejects

Patch the existing document (do not create a new one):

```json
{
  "status": "accepted",
  "assigned_provider_id": "provider_001",
  "assigned_provider_name": "City Hospital",
  "updated_at": "server_timestamp"
}
```

Use `status: "rejected"` with the same provider fields to record a rejection.

### 4.4 Reassignment after rejection

```json
{
  "status": "reassigned",
  "assigned_provider_id": "provider_002",
  "assigned_provider_name": "Provider 2",
  "escalation_count": 1,
  "updated_at": "server_timestamp"
}
```

### 4.5 User cancellation

```json
{ "status": "cancelled", "updated_at": "server_timestamp" }
```

### 4.6 User live status

Listen to `service_requests/{request_id}`. Every status or provider change updates the UI automatically.

## 5. Responsibilities

### User App

- Demo ambulance and towing request cards create requests.
- A live status tracker listens to each request.
- A Cancel button writes `cancelled`.
- Existing static Indore operator cards remain unrelated to Firestore.

### Admin Dashboard

- Incoming request panel listens for pending requests.
- Accept / Reject buttons update the existing document.
- Reassignment on rejection updates the same document.
- Progress buttons set `en_route` and `completed`.
- The CCTV AI feature is a separate page/tab with no shared request-flow logic.

## 6. Before UI Work

1. Confirm both apps point to the same Sahay Firebase project.
2. Run a joint smoke test: one side writes a request, the other reads every field, updates status, and the writer receives the live update.
3. Start parallel UI work only after this round trip succeeds.
