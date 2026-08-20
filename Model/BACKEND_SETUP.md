# Safe Route AI Backend

XGBoost-powered route safety scoring with Firebase incident intelligence and Google Maps integration.

## Overview

This backend orchestrates:
1. **Route Fetching** - Google Directions API (multiple alternatives)
2. **Route Feature Extraction** - POI counting, activity scores, distance/duration
3. **Incident Intelligence** - Firebase Firestore queries for unsafe reports & SOS events
4. **Risk Prediction** - XGBoost model scoring (0-1 risk probability)
5. **Response Ranking** - Top-3 safest routes with explanations

## Architecture

```
Client (Flutter App)
    ↓
FastAPI Backend (/api/v1/scoreRoutes)
    ↓
├─ RouteFeatureEngine
│  ├─ Google Directions API → candidate routes
│  ├─ Google Places API → POI counts
│  └─ Feature extraction → route_distance_m, POI counts, activity scores, isolation_score
│
├─ IncidentEngine
│  ├─ Firestore: unsafe_reports collection
│  ├─ Firestore: sos_events collection
│  └─ Feature computation → incident_density, avg_incident_severity, temporal_risk_score, redzone_overlap_score
│
├─ Route Risk Scan Store
│  └─ Firestore: route_risk_scans collection
│     ├─ Per-request route snapshot
│     ├─ Stores the locked 22-feature payload per route
│     └─ Persists incident_density, redzone_overlap_score, avg_incident_severity, temporal_risk_score
│
└─ FeatureVectorBuilder
   ├─ Merge route + incident features
   ├─ Validate feature vector
   └─ Build locked column order for XGBoost
       ↓
   XGBoost Model (safe_route_xgb_model.pkl)
       ↓
   risk_probability (0-1) per route
       ↓
   Sort & rank top-3 by safety
       ↓
   Return JSON with scores + explanations
```

## Setup

### 1. Environment Variables

Create a `.env` file in this directory:

```bash
# Google APIs
GOOGLE_API_KEY=your_google_places_directions_api_key

# Model path
MODEL_PATH=./safe_route_xgb_model.pkl

# Firebase credentials (path to service account JSON)
FIREBASE_CREDENTIALS_PATH=./firebase-service-account.json
```

### 2. Install Dependencies

```bash
pip install -r requirements.txt
```

### 3. Firebase Setup

Download your Firebase service account JSON from Firebase Console → Project Settings → Service Accounts.
Place it at `./firebase-service-account.json` (or set `FIREBASE_CREDENTIALS_PATH`).

### 4. Train the Model (if needed)

```bash
python training.py
```

This generates `safe_route_synthetic_dataset.csv` and trains `safe_route_xgb_model.pkl`.

### 5. Run the Backend

```bash
python backend.py
```

Or with uvicorn directly:

```bash
uvicorn backend:app --host 0.0.0.0 --port 8000 --reload
```

Server will be at `http://localhost:8000`

## API Endpoints

### POST `/api/v1/scoreRoutes`

Score candidate routes and return top-3 by safety.

**Request:**

```json
{
  "user_id": "user_123",
  "origin": {
    "lat": 37.7749,
    "lng": -122.4194
  },
  "destination": {
    "lat": 37.8199,
    "lng": -122.4783
  },
  "trip_time": "2026-05-13T20:00:00Z",
  "travel_mode": "driving"
}
```

**Headers:**

```
Authorization: Bearer <Firebase_ID_Token>
```

**Response:**

```json
{
  "success": true,
  "routes": [
    {
      "id": "0",
      "rank": 1,
      "risk_probability": 0.2847,
      "safety_score": 0.7153,
      "risk_bucket": "SAFE",
      "explanation": "Safest route: Well-lit, populated area",
      "distance_m": 8000,
      "duration_s": 900,
      "polyline_encoded": "encoded_polyline_string"
    },
    {
      "id": "1",
      "rank": 2,
      "risk_probability": 0.5234,
      "safety_score": 0.4766,
      "risk_bucket": "MODERATE",
      "explanation": "Moderate risk: Some reports in area",
      "distance_m": 6100,
      "duration_s": 780,
      "polyline_encoded": "encoded_polyline_string"
    },
    ...
  ],
  "meta": {
    "scored_at": "2026-05-13T19:00:00.123456",
    "model_version": "v1.0",
    "elapsed_seconds": 2.34,
    "routes_scored": 3
  }
}
```

### GET `/health`

Health check.

```json
{
  "status": "ok",
  "model_loaded": true,
  "firebase": true
}
```

### GET `/api/v1/debug/testPrediction`

Debug: test with a hardcoded San Francisco route.

## Integration with Flutter App

### 1. Call Backend from Navigation Screen

In [lib/screens/navigation_screen.dart](../../lib/screens/navigation_screen.dart):

```dart
Future<void> _requestSafeRoutes() async {
  final idToken = await FirebaseAuth.instance.currentUser!.getIdToken();
  final response = await http.post(
    Uri.parse('$BACKEND_URL/api/v1/scoreRoutes'),
    headers: {
      'Authorization': 'Bearer $idToken',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'user_id': FirebaseAuth.instance.currentUser!.uid,
      'origin': {'lat': _currentPosition!.latitude, 'lng': _currentPosition!.longitude},
      'destination': {'lat': destLat, 'lng': destLng},
      'trip_time': DateTime.now().toIso8601String(),
      'travel_mode': 'driving',
    }),
  );

  if (response.statusCode == 200) {
    final result = jsonDecode(response.body);
    _displaySafeRoutes(result['routes']);  // Show top-3 on map
  }
}
```

### 2. Display Routes on Map

```dart
void _displaySafeRoutes(List<dynamic> routes) {
  for (final route in routes) {
    final polylinePoints = PolylinePoints.decodePolyline(route['polyline_encoded']);
    final color = route['risk_bucket'] == 'SAFE' ? Colors.green : Colors.orange;
    
    _polylines.add(Polyline(
      polylineId: PolylineId(route['id']),
      points: polylinePoints,
      color: color,
      width: 4,
    ));
  }
}
```

### 3. Show Safety Scores in UI

Display the top-3 routes in a bottom sheet or list:

```dart
_showRoutesBottomSheet(routes);
// Each route shows: rank, safety_score, risk_bucket, explanation
```

## Feature Details

### Route Features (RouteFeatureEngine)

- `route_distance_m`: Total distance (meters)
- `route_eta_sec`: Estimated time (seconds)
- `atm_count`, `bank_count`, `restaurant_count`, ...: POI counts
- `commercial_activity_score`: restaurants + cafes + malls + supermarkets
- `emergency_presence_score`: hospitals + police stations
- `transport_activity_score`: buses + trains
- `isolation_score`: inverse of activity (100 - activity-weighted sum)
- `nighttime_score`: 0 (noon) to 1 (midnight)

### Incident Features (IncidentEngine)

Queries Firestore collections:
- `unsafe_reports`: lat, lng, reason, timestamp, upvotes, expiresAt
- `sos_events`: location (GeoPoint), timestamp, status

Computes:
- `incident_density`: incidents per km along route
- `avg_incident_severity`: average severity (weighted by report type)
- `temporal_risk_score`: recency-weighted severity (exponential decay)
- `redzone_overlap_score`: fraction of route in high-concentration zones (0-1)

### Route Risk Scan Collection (`route_risk_scans`)

Written by the backend after each successful `/api/v1/scoreRoutes` request.

Document fields:
- `scan_id`: unique request identifier
- `user_id`: authenticated user id or anonymous fallback
- `origin`, `destination`, `trip_time`, `travel_mode`
- `feature_schema`: locked model schema marker
- `route_count`: number of scored alternatives
- `routes[]`: per-route snapshot containing
  - `risk_probability`
  - `safety_score`
  - `risk_bucket`
  - `incident_density`
  - `redzone_overlap_score`
  - `avg_incident_severity`
  - `temporal_risk_score`
  - `nighttime_score`
  - `distance_m`, `duration_s`, `polyline_encoded`
- `meta`: backend scoring metadata
- `source_collections`: upstream Firestore sources used by the feature engine
- `created_at`: server timestamp

### Risk Thresholds

- `SAFE`: risk_probability < 0.40
- `MODERATE`: 0.40 ≤ risk_probability < 0.65
- `DANGEROUS`: risk_probability ≥ 0.65

## Performance

- **Model inference:** ~10ms per route
- **Feature extraction:** ~1-2s per route (includes API calls)
- **Total end-to-end:** ~2-3s for 3 routes

### Optimization Tips

1. **Cache POI queries** using SpatialGridCache (already implemented)
2. **Sample fewer polyline points** for longer routes
3. **Pre-compute redzone clusters** in Firestore
4. **Batch Firestore queries** instead of individual reads
5. **Use async prediction** for latency-sensitive apps (return heuristic score first, AI score later)

## Troubleshooting

### Model not loading

```
FileNotFoundError: safe_route_xgb_model.pkl
```

Solution: Run `training.py` first, or ensure `MODEL_PATH` env var points to the pickle file.

### Firebase auth errors

```
Invalid Firebase ID token
```

Solution:
1. Verify token is fresh (< 1 hour old)
2. Check Firebase project ID matches your app
3. In development, can skip auth by removing Authorization header

### Google API errors

```
REQUEST_DENIED: The key is invalid or not authorized
```

Solution:
1. Verify `GOOGLE_API_KEY` has Places + Directions API enabled
2. Check API quota limits in Google Cloud Console

### Firestore query timeout

```
Timeout: Firestore query took > 5s
```

Solution:
1. Add indexes to Firestore for (active, expiresAt) on unsafe_reports
2. Reduce route buffer radius from 500m to 300m
3. Cache recent incident queries

## Deployment

### Cloud Run (Recommended)

```bash
gcloud run deploy safe-route-api \
  --source . \
  --platform managed \
  --region us-central1 \
  --set-env-vars GOOGLE_API_KEY=xxx,MODEL_PATH=/app/safe_route_xgb_model.pkl,FIREBASE_CREDENTIALS_PATH=/app/firebase.json
```

### Docker

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
CMD ["uvicorn", "backend:app", "--host", "0.0.0.0", "--port", "8000"]
```

```bash
docker build -t safe-route-api .
docker run -p 8000:8000 \
  -e GOOGLE_API_KEY=xxx \
  -e FIREBASE_CREDENTIALS_PATH=/app/firebase.json \
  safe-route-api
```

## Testing

### Unit Test

```python
from predict_route_risk import RouteRiskPredictor

predictor = RouteRiskPredictor(
    model_path="./safe_route_xgb_model.pkl",
    google_api_key="test_key",
)

result = predictor.score_routes(
    origin=(37.7749, -122.4194),
    destination=(37.8199, -122.4783),
    trip_timestamp=datetime.utcnow(),
)

assert result["success"]
assert len(result["routes"]) <= 3
assert all(r["risk_bucket"] in ["SAFE", "MODERATE", "DANGEROUS"] for r in result["routes"])
```

### Integration Test

```bash
curl -X POST http://localhost:8000/api/v1/scoreRoutes \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "user_id": "test_user",
    "origin": {"lat": 37.7749, "lng": -122.4194},
    "destination": {"lat": 37.8199, "lng": -122.4783},
    "travel_mode": "driving"
  }'
```

## Next Steps

- [ ] Add caching layer (Redis) for duplicate requests
- [ ] Implement request rate-limiting per user
- [ ] Add request/response logging and monitoring
- [ ] A/B test different risk thresholds
- [ ] Collect user feedback on route recommendations
- [ ] Fine-tune model with real incident data
