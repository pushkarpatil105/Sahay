"""
PREDICT ROUTE RISK (FIXED VERSION)
==================
Main orchestrator: fetches routes, extracts features (route + incident),
merges them, and runs XGBoost prediction to rank routes by safety.

FIXES APPLIED:
- Added pandas import
- Fixed FeatureVectorBuilder method calls
- Convert feature dict to DataFrame for XGBoost
- Fixed model prediction call
"""

import time
import pandas as pd
from feature_vector_builder import FeatureVectorBuilder, LOCKED_FEATURE_ORDER
from datetime import datetime
from typing import Dict, List, Optional, Tuple
import joblib

from route_feature_engine import RouteFeatureEngine
from incident_engine import IncidentEngine
from incident_feature_engine import IncidentFeatureEngine
from incident_intelligence import IncidentIntelligenceClient
from feature_vector_builder import FeatureVectorBuilder


class RouteRiskPredictor:
    """Orchestrates complete route risk prediction pipeline."""

    # Risk score buckets
    SAFE_THRESHOLD = 0.40
    DANGEROUS_THRESHOLD = 0.65

    def __init__(
        self,
        model_path: str,
        google_api_key: str,
        firestore_client=None,
    ):
        """
        Initialize predictor.
        
        Args:
            model_path: Path to saved XGBoost model pickle
            google_api_key: Google Places/Directions API key
            firestore_client: firebase_admin.firestore.Client (optional)
        """
        print(f"[RouteRiskPredictor] Loading model from {model_path}")
        self.model = joblib.load(model_path)
        self.route_engine = RouteFeatureEngine(google_api_key)
        self.incident_engine = IncidentEngine(firestore_client)
        
        # Initialize Crimeometer incident intelligence for enhanced analysis (optional)
        self.incident_feature_engine = None
        try:
            incident_client = IncidentIntelligenceClient()
            if incident_client.is_configured:
                self.incident_feature_engine = IncidentFeatureEngine(client=incident_client)
                print("[RouteRiskPredictor] [OK] Crimeometer Incident Intelligence Engine initialized")
            else:
                print("[RouteRiskPredictor] [INFO] Crimeometer not configured - continuing with existing features")
        except Exception as e:
            print(f"[RouteRiskPredictor] [INFO] Crimeometer integration optional: {e}")
            self.incident_feature_engine = None
            
        print("[RouteRiskPredictor] Model and engines initialized")

    def _risk_bucket(self, risk_probability: float) -> str:
        """Classify risk into SAFE / MODERATE / DANGEROUS."""
        if risk_probability < self.SAFE_THRESHOLD:
            return "SAFE"
        elif risk_probability < self.DANGEROUS_THRESHOLD:
            return "MODERATE"
        else:
            return "DANGEROUS"

    def _generate_explanation(
        self,
        route_id: str,
        risk_prob: float,
        features: Dict,
        rank: int,
    ) -> str:
        """Generate human-readable explanation for route risk."""
        bucket = self._risk_bucket(risk_prob)

        # Key risk factors
        factors = []

        if features.get("incident_density", 0) > 3.0:
            factors.append("high incident density")
        elif features.get("incident_density", 0) > 1.0:
            factors.append("moderate incidents reported")

        if features.get("redzone_overlap_score", 0) > 0.5:
            factors.append("overlaps high-risk zones")

        if features.get("isolation_score", 0) > 70:
            factors.append("isolated area")
        elif features.get("emergency_presence_score", 0) > 2:
            factors.append("near emergency services")

        if features.get("nighttime_score", 0) > 0.7:
            factors.append("late night hours")

        # Build explanation
        if bucket == "SAFE":
            if rank == 1:
                return f"Safest route: {', '.join(factors) if factors else 'Well-lit, populated area'}"
            else:
                return f"Safe route: {', '.join(factors[:2]) if factors else 'Low incident history'}"
        elif bucket == "MODERATE":
            return f"Moderate risk: {', '.join(factors[:2]) if factors else 'Some reports in area'}"
        else:
            return f"[WARNING] Higher risk: {', '.join(factors) if factors else 'Avoid if possible'}"

    def score_routes(
        self,
        origin: Tuple[float, float],
        destination: Tuple[float, float],
        trip_timestamp: datetime,
        travel_mode: str = "driving",
        user_id: str = "anonymous",
    ) -> Dict:
        """
        Score candidate routes and return top-3 ranked by safety.
        
        Args:
            origin: (lat, lng)
            destination: (lat, lng)
            trip_timestamp: datetime of planned trip
            travel_mode: "driving", "walking", etc.
            user_id: User identifier (for logging)
        
        Returns:
            Dict with:
            - success: bool
            - routes: List of top-3 routes, each with:
              - id
              - risk_probability (0-1)
              - safety_score (1-0, inverse of risk)
              - risk_bucket (SAFE/MODERATE/DANGEROUS)
              - rank (1, 2, 3)
              - explanation
              - distance_m, duration_s
            - meta: {scored_at, model_version, error (if any)}
        """
        result = {
            "success": False,
            "routes": [],
            "meta": {
                "scored_at": datetime.utcnow().isoformat(),
                "model_version": "v1.0",
                "origin": origin,
                "destination": destination,
            }
        }

        try:
            start_time = time.time()

            # Step 1: Fetch candidate routes from Google Directions API
            print(f"[RouteRiskPredictor] Fetching routes for {user_id}: {origin} -> {destination}")
            candidate_routes = self.route_engine.fetch_routes(
                origin=origin,
                destination=destination,
                num_alternatives=3,
                travel_mode=travel_mode,
            )

            if not candidate_routes:
                result["meta"]["error"] = "Could not fetch routes from Google API"
                return result

            print(f"[RouteRiskPredictor] Got {len(candidate_routes)} candidate routes")

            # Step 2: Extract features for each route and predict risk
            routes_with_scores = []

            for route in candidate_routes:
                try:
                    route_id = route.get("id", str(len(routes_with_scores)))

                    # Extract route features (POI, distance, ETA, isolation, etc.)
                    route_features, _ = self.route_engine.extract_route_features(
                        route=route,
                        origin=origin,
                        destination=destination,
                    )

                    # Get sampled polyline points for incident queries
                    decoded_points = self.route_engine.decode_polyline(
                        route.get("polyline", {}).get("encodedPolyline", "")
                    )
                    sampled_points = self.route_engine.sample_route_points(
                        decoded_points
                    )

                    # Extract incident features (density, severity, temporal, redzone)
                    incident_features = self.incident_engine.compute_incident_features(
                        sampled_points=sampled_points,
                        route_distance_m=route_features.get("route_distance_m", 1000),
                        current_time=trip_timestamp.timestamp(),
                    )

                    # Enhance with Crimeometer incident intelligence data
                    if self.incident_feature_engine:
                        try:
                            route_coords = [(lat, lng) for lat, lng in sampled_points]
                            crimeometer_features = self.incident_feature_engine.score_route(
                                route_points=route_coords,
                                route_distance_m=route_features.get("route_distance_m", 1000),
                                trip_time=trip_timestamp,
                            )
                            # Merge crimeometer metrics for comprehensive analysis
                            incident_features.update({
                                "crimeometer_incident_count": crimeometer_features.incident_count,
                                "crimeometer_max_csi": crimeometer_features.max_csi,
                                "crimeometer_avg_csi": crimeometer_features.avg_csi,
                                "crimeometer_query_points": crimeometer_features.query_points,
                            })
                        except Exception as e:
                            print(f"[RouteRiskPredictor] Crimeometer enrichment skipped for route {route_id}: {e}")

                    # DEBUG: log raw features to diagnose identical scores
                    print(f"[DEBUG] Route {route_id} route_features: dist={route_features.get('route_distance_m')}m "
                          f"isolation={route_features.get('isolation_score')} "
                          f"commercial={route_features.get('commercial_activity_score')} "
                          f"emergency={route_features.get('emergency_presence_score')}")
                    print(f"[DEBUG] Route {route_id} incident_features: "
                          f"density={incident_features.get('incident_density'):.4f} "
                          f"redzone={incident_features.get('redzone_overlap_score'):.4f} "
                          f"severity={incident_features.get('avg_incident_severity'):.4f} "
                          f"temporal={incident_features.get('temporal_risk_score'):.4f}")

                    # ===== FIX #1: Build feature vector correctly =====
                    # Get trip hour for nighttime score
                    hour = trip_timestamp.hour
                    
                    # Build feature vector (this merges route + incident + computes nighttime)
                    feature_vector = FeatureVectorBuilder.build_feature_vector(
                        route_features,
                        incident_features,
                        current_hour=float(hour),
                    )

                    # Validate feature count
                    if not FeatureVectorBuilder.validate_feature_count(feature_vector):
                        print(f"[RouteRiskPredictor] Feature count mismatch for route {route_id}")
                        continue

                    # ===== FIX #2: Convert dict to DataFrame for XGBoost =====
                    # XGBoost needs DataFrame or numpy array, NOT dict
                    feature_df = pd.DataFrame([feature_vector])
                    # Ensure column order matches training
                    feature_df = feature_df[LOCKED_FEATURE_ORDER]

                    # ===== FIX #3: Predict with DataFrame =====
                    risk_probability = float(self.model.predict(feature_df)[0])
                    safety_score = 1.0 - risk_probability  # Invert: higher = safer

                    routes_with_scores.append({
                        "id": route_id,
                        "risk_probability": risk_probability,
                        "safety_score": safety_score,
                        "features": feature_vector,
                        "risk_factors": {
                            "incident_density": feature_vector.get("incident_density", 0.0),
                            "redzone_overlap_score": feature_vector.get("redzone_overlap_score", 0.0),
                            "avg_incident_severity": feature_vector.get("avg_incident_severity", 0.0),
                            "temporal_risk_score": feature_vector.get("temporal_risk_score", 0.0),
                        },
                        "distance_m": route_features.get("route_distance_m", 0),
                        "duration_s": route_features.get("route_eta_sec", 0),
                        "polyline_encoded": route.get("polyline", {}).get("encodedPolyline", ""),
                    })

                    print(
                        f"[RouteRiskPredictor] Route {route_id}: risk={risk_probability:.3f}, "
                        f"safety={safety_score:.3f}"
                    )

                except Exception as e:
                    print(f"[RouteRiskPredictor] Error processing route: {e}")
                    continue

            if not routes_with_scores:
                result["meta"]["error"] = "No valid routes could be scored"
                return result

            # Step 3: Sort by safety (lowest risk first)
            routes_with_scores.sort(key=lambda r: r["risk_probability"])

            # Step 4: Format response (top 3)
            for rank, route in enumerate(routes_with_scores[:3], 1):
                explanation = self._generate_explanation(
                    route_id=route["id"],
                    risk_prob=route["risk_probability"],
                    features=route["features"],
                    rank=rank,
                )

                result["routes"].append({
                    "id": route["id"],
                    "rank": rank,
                    "risk_probability": round(route["risk_probability"], 4),
                    "safety_score": round(route["safety_score"], 4),
                    "risk_bucket": self._risk_bucket(route["risk_probability"]),
                    "explanation": explanation,
                    "distance_m": int(route["distance_m"]),
                    "duration_s": int(route["duration_s"]),
                    "polyline_encoded": route["polyline_encoded"],
                    "risk_factors": route.get("risk_factors", {}),
                })

            result["success"] = True
            result["meta"]["elapsed_seconds"] = round(time.time() - start_time, 2)
            result["meta"]["routes_scored"] = len(routes_with_scores)

            print(f"[RouteRiskPredictor] Scoring complete in {result['meta']['elapsed_seconds']}s")

        except Exception as e:
            print(f"[RouteRiskPredictor] Unexpected error: {e}", exc_info=True)
            result["meta"]["error"] = str(e)

        return result