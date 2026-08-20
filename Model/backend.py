"""
FASTAPI BACKEND FOR SAFE ROUTE AI
==================================
REST API endpoint that scores candidate routes using the XGBoost model
integrated with Google Directions and Firebase incident data.

Usage:
    uvicorn backend:app --host 0.0.0.0 --port 5050

Environment variables:
    - GOOGLE_API_KEY: Google Places/Directions API key
    - MODEL_PATH: Path to safe_route_xgb_model.pkl
    - FIREBASE_CREDENTIALS_PATH: Path to Firebase service account JSON (optional)
"""

import os
import logging
import socket
import sys
from uuid import uuid4
from datetime import datetime
from typing import List, Optional, Tuple
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Header, Depends
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
import firebase_admin
from firebase_admin import credentials, firestore,auth

from predict_route_risk import RouteRiskPredictor
from incident_feature_engine import IncidentFeatureEngine
from incident_intelligence import IncidentIntelligenceClient

# ============================================================
# LOAD ENVIRONMENT VARIABLES
# ============================================================
# Load .env file from parent directory
env_path = Path(__file__).parent.parent / ".env"
load_dotenv(dotenv_path=env_path)

# ============================================================
# LOGGING
# ============================================================

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ============================================================
# ENVIRONMENT & CONFIG
# ============================================================

GOOGLE_API_KEY = os.getenv("GOOGLE_API_KEY", "")
MODEL_PATH = os.getenv("MODEL_PATH", "./safe_route_xgb_model.pkl")
FIREBASE_CREDS = os.getenv("FIREBASE_CREDENTIALS_PATH", "")

if not GOOGLE_API_KEY:
    logger.warning("[WARN] GOOGLE_API_KEY not set in environment")

if not os.path.exists(MODEL_PATH):
    logger.error(f"[ERROR] Model not found at {MODEL_PATH}")

# Initialize Firebase
firestore_client = None
try:
    if FIREBASE_CREDS and os.path.exists(FIREBASE_CREDS):
        cred = credentials.Certificate(FIREBASE_CREDS)
        firebase_admin.initialize_app(cred)
        firestore_client = firestore.client()
        logger.info("[OK] Firebase initialized")
    else:
        logger.warning("[WARN] Firebase credentials not configured; incident features will be empty")
except Exception as e:
    logger.error(f"[ERROR] Firebase init error: {e}")

# ============================================================
# REQUEST/RESPONSE MODELS
# ============================================================


class LatLng(BaseModel):
    """Latitude/Longitude pair."""
    lat: float = Field(..., ge=-90, le=90)
    lng: float = Field(..., ge=-180, le=180)


class ScoreRoutesRequest(BaseModel):
    """Request to score candidate routes."""
    user_id: str = Field(default="anonymous", description="User identifier")
    origin: LatLng = Field(..., description="Starting point")
    destination: LatLng = Field(..., description="Destination")
    trip_time: Optional[datetime] = Field(
        default_factory=datetime.utcnow,
        description="Planned trip datetime (ISO 8601)"
    )
    travel_mode: str = Field(default="driving", pattern="^(driving|walking|transit)$")


class SafetyScore(BaseModel):
    """Safety score for a single route."""
    id: str
    rank: int
    risk_probability: float = Field(..., ge=0, le=1)
    safety_score: float = Field(..., ge=0, le=1)
    risk_bucket: str
    explanation: str
    distance_m: int
    duration_s: int
    polyline_encoded: str
    incident_density: float = Field(default=0.0, ge=0)
    redzone_overlap_score: float = Field(default=0.0, ge=0, le=1)
    avg_incident_severity: float = Field(default=0.0, ge=0)
    temporal_risk_score: float = Field(default=0.0, ge=0)
    risk_factors: dict = Field(default_factory=dict)


class ScoreRoutesResponse(BaseModel):
    """Response with scored routes."""
    success: bool
    routes: List[SafetyScore]
    meta: dict


# ============================================================
# FASTAPI APP
# ============================================================

app = FastAPI(
    title="Safe Route AI API",
    description="Route safety scoring using XGBoost + incident intelligence",
    version="1.0.0",
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Initialize predictor
try:
    predictor = RouteRiskPredictor(
        model_path=MODEL_PATH,
        google_api_key=GOOGLE_API_KEY,
        firestore_client=firestore_client,
    )
    logger.info("[OK] RouteRiskPredictor initialized")
except Exception as e:
    logger.error(f"[ERROR] Failed to initialize predictor: {e}")
    predictor = None

# Initialize incident intelligence (optional enhancement)
incident_client = None
incident_engine = None
try:
    incident_client = IncidentIntelligenceClient()
    if incident_client.is_configured:
        incident_engine = IncidentFeatureEngine(client=incident_client)
        logger.info("[OK] Crimeometer Incident Intelligence Engine initialized (optional)")
    else:
        logger.info("[INFO] Crimeometer not configured - proceeding with existing features")
except Exception as e:
    logger.warning(f"[INFO] Crimeometer integration optional, continuing: {e}")


ROUTE_RISK_SCAN_COLLECTION = "route_risk_scans"


# ============================================================
# MIDDLEWARE / AUTH
# ============================================================

async def verify_firebase_token(authorization: Optional[str] = Header(None)) -> dict:
    """
    Verify Firebase ID token from Authorization header.
    
    Format: Bearer <token>
    
    Args:
        authorization: Authorization header
    
    Returns:
        Decoded token dict with uid, etc.
    
    Raises:
        HTTPException if token is invalid
    """
    if not authorization:
        # Allow unauthenticated for now; in production, enforce
        logger.warning("Missing Authorization header; proceeding as anonymous")
        return {"uid": "anonymous"}

    try:
        parts = authorization.split(" ")
        if len(parts) != 2 or parts[0].lower() != "bearer":
            raise HTTPException(status_code=401, detail="Invalid Authorization header format")

        token = parts[1]
        decoded = auth.verify_id_token(token)

        logger.info(f"[OK] Token verified for uid={decoded.get('uid')}")
        return decoded

    except auth.InvalidIdTokenError:
        logger.error("[ERROR] Invalid ID token")
        raise HTTPException(status_code=401, detail="Invalid Firebase ID token")
    except Exception as e:
        logger.error(f"[ERROR] Auth error: {e}")
        raise HTTPException(status_code=401, detail=f"Auth error: {str(e)}")


def persist_route_risk_scan(
    request: ScoreRoutesRequest,
    decoded_token: dict,
    raw_result: dict,
) -> None:
    """Persist the scored route snapshot for analytics and debugging."""
    if firestore_client is None or not raw_result.get("success"):
        return

    try:
        user_id = decoded_token.get("uid", request.user_id or "anonymous")
        scan_id = f"{datetime.utcnow().strftime('%Y%m%dT%H%M%S%f')}_{uuid4().hex[:12]}"
        routes = []
        route_factor_summaries = []

        for route in raw_result.get("routes", []):
            features = route.get("features", {}) or {}
            risk_factors = route.get("risk_factors", {}) or {
                "incident_density": features.get("incident_density", 0.0),
                "redzone_overlap_score": features.get("redzone_overlap_score", 0.0),
                "avg_incident_severity": features.get("avg_incident_severity", 0.0),
                "temporal_risk_score": features.get("temporal_risk_score", 0.0),
            }
            routes.append(
                {
                    "id": route.get("id"),
                    "rank": route.get("rank"),
                    "risk_probability": route.get("risk_probability"),
                    "safety_score": route.get("safety_score"),
                    "risk_bucket": route.get("risk_bucket"),
                    "distance_m": route.get("distance_m"),
                    "duration_s": route.get("duration_s"),
                    "incident_density": risk_factors.get("incident_density", 0.0),
                    "redzone_overlap_score": risk_factors.get("redzone_overlap_score", 0.0),
                    "avg_incident_severity": risk_factors.get("avg_incident_severity", 0.0),
                    "temporal_risk_score": risk_factors.get("temporal_risk_score", 0.0),
                    "nighttime_score": features.get("nighttime_score", 0.0),
                    "polyline_encoded": route.get("polyline_encoded", ""),
                }
            )

            route_factor_summaries.append(
                {
                    "route_id": route.get("id"),
                    "rank": route.get("rank"),
                    "risk_factors": risk_factors,
                }
            )

        payload = {
            "scan_id": scan_id,
            "user_id": user_id,
            "origin": {"lat": request.origin.lat, "lng": request.origin.lng},
            "destination": {"lat": request.destination.lat, "lng": request.destination.lng},
            "trip_time": request.trip_time.isoformat() if request.trip_time else None,
            "travel_mode": request.travel_mode,
            "feature_schema": "locked_22_feature_v1",
            "route_count": len(routes),
            "routes": routes,
            "route_factor_summaries": route_factor_summaries,
            "meta": raw_result.get("meta", {}),
            "source_collections": ["unsafe_reports", "sos_events", "redzones"],
            "created_at": firestore.SERVER_TIMESTAMP,
        }

        firestore_client.collection(ROUTE_RISK_SCAN_COLLECTION).document(scan_id).set(payload)
        logger.info(
            "[OK] Stored route risk scan %s in Firestore collection %s",
            scan_id,
            ROUTE_RISK_SCAN_COLLECTION,
        )
    except Exception as e:
        logger.warning(f"[WARN] Failed to persist route risk scan: {e}")


# ============================================================
# ENDPOINTS
# ============================================================

@app.get("/health")
async def health():
    """Health check endpoint."""
    status = {
        "status": "ok",
        "model_loaded": predictor is not None,
        "firebase": firestore_client is not None,
    }
    return status


@app.post("/api/v1/scoreRoutes", response_model=ScoreRoutesResponse)
async def score_routes(
    request: ScoreRoutesRequest,
    decoded_token: dict = Depends(verify_firebase_token),
) -> ScoreRoutesResponse:
    """
    Score candidate routes for safety.
    
    Fetches alternative routes from Google Directions API,
    extracts route + incident features, and ranks by safety using XGBoost.
    
    Args:
        request: ScoreRoutesRequest with origin, destination, etc.
        decoded_token: Firebase decoded ID token (from header)
    
    Returns:
        ScoreRoutesResponse with top-3 routes ranked by safety
    
    Raises:
        HTTPException on model error or invalid inputs
    """
    if not predictor:
        logger.error("Predictor not initialized")
        raise HTTPException(status_code=503, detail="Model not available")

    try:
        origin = (request.origin.lat, request.origin.lng)
        destination = (request.destination.lat, request.destination.lng)
        user_id = decoded_token.get("uid", "anonymous")

        logger.info(
            f"[scoreRoutes] user={user_id}, origin={origin}, dest={destination}, "
            f"travel_mode={request.travel_mode}"
        )

        # Call predictor
        result = predictor.score_routes(
            origin=origin,
            destination=destination,
            trip_timestamp=request.trip_time,
            travel_mode=request.travel_mode,
            user_id=user_id,
        )

        if not result.get("success"):
            error_msg = result.get("meta", {}).get("error", "Unknown error")
            logger.error(f"Prediction failed: {error_msg}")
            raise HTTPException(status_code=400, detail=error_msg)

        persist_route_risk_scan(request, decoded_token, result)

        # Format response
        response = ScoreRoutesResponse(
            success=result["success"],
            routes=[SafetyScore(**route) for route in result["routes"]],
            meta=result["meta"],
        )

        logger.info(
            f"[scoreRoutes] Success: scored {len(response.routes)} routes in "
            f"{result['meta'].get('elapsed_seconds')}s"
        )

        return response

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"[scoreRoutes] Unexpected error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Server error: {str(e)}")


@app.post("/api/v1/debug/testPrediction")
async def test_prediction():
    """
    Debug endpoint: test with a hardcoded route example.
    
    Returns top-3 scored routes for San Francisco demo route.
    """
    try:
        # San Francisco demo: Union Square to GG Bridge
        origin = (37.7879, -122.4075)
        destination = (37.8199, -122.4783)

        result = predictor.score_routes(
            origin=origin,
            destination=destination,
            trip_timestamp=datetime.utcnow(),
            user_id="test_user",
        )

        return result

    except Exception as e:
        logger.error(f"Test prediction error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn

    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "5050"))

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if sock.connect_ex((host, port)) == 0:
            logger.error("Port %s is already in use. Stop the existing server or set PORT to a free port.", port)
            sys.exit(1)

    uvicorn.run(
        app,
        host=host,
        port=port,
        log_level="info",
    )
