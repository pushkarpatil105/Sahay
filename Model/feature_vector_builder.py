"""
Feature Vector Builder - AI-Ready Feature Pipeline
Merges route and incident features into a locked 22-feature vector for model inference.
"""

from typing import Dict, List

import pandas as pd

# ============================================================
# LOCKED FEATURE ORDER (IMMUTABLE)
# ============================================================

LOCKED_FEATURE_ORDER = [
    "route_distance_m",
    "route_eta_sec",
    "atm_count",
    "bank_count",
    "restaurant_count",
    "pharmacy_count",
    "cafe_count",
    "shopping_mall_count",
    "supermarket_count",
    "hospital_count",
    "police_count",
    "bus_station_count",
    "train_station_count",
    "commercial_activity_score",
    "emergency_presence_score",
    "transport_activity_score",
    "isolation_score",
    "redzone_overlap_score",
    "incident_density",
    "avg_incident_severity",
    "temporal_risk_score",
    "nighttime_score",
]

FEATURE_COUNT = len(LOCKED_FEATURE_ORDER)

# ============================================================
# DEFAULT SAFE VALUES
# ============================================================

DEFAULT_SAFE_VALUES = {
    "route_distance_m": 5000,
    "route_eta_sec": 600,
    "atm_count": 0,
    "bank_count": 0,
    "restaurant_count": 0,
    "pharmacy_count": 0,
    "cafe_count": 0,
    "shopping_mall_count": 0,
    "supermarket_count": 0,
    "hospital_count": 0,
    "police_count": 0,
    "bus_station_count": 0,
    "train_station_count": 0,
    "commercial_activity_score": 0,
    "emergency_presence_score": 0,
    "transport_activity_score": 0,
    "isolation_score": 85.0,
    "redzone_overlap_score": 0.0,
    "incident_density": 0.0,
    "avg_incident_severity": 0.0,
    "temporal_risk_score": 0.0,
    "nighttime_score": 0.0,
}


# ============================================================
# FEATURE VECTOR BUILDER
# ============================================================

class FeatureVectorBuilder:
    """Builds AI-ready feature vectors with strict schema validation."""

    @staticmethod
    def compute_nighttime_score(current_hour: float) -> float:
        """Compute nighttime score: abs(hour - 12) / 12."""
        return abs(current_hour - 12) / 12

    @staticmethod
    def validate_feature_count(features: Dict) -> bool:
        """Ensure exactly 22 features are present."""
        return len(features) == FEATURE_COUNT

    @staticmethod
    def fill_missing_features(features: Dict) -> Dict:
        """Fill missing features with safe defaults."""
        filled = DEFAULT_SAFE_VALUES.copy()
        filled.update(features)
        return filled

    @staticmethod
    def build_feature_vector(
        route_features: Dict,
        incident_features: Dict,
        current_hour: float = 12.0,
    ) -> Dict:
        """Build complete 22-feature vector."""
        nighttime_score = FeatureVectorBuilder.compute_nighttime_score(current_hour)

        merged = {
            **route_features,
            **incident_features,
            "nighttime_score": nighttime_score,
        }

        filled = FeatureVectorBuilder.fill_missing_features(merged)

        ordered = {key: filled[key] for key in LOCKED_FEATURE_ORDER}

        return ordered

    @staticmethod
    def build_dataframe(
        batch_routes: List[Dict],
        batch_incidents: List[Dict],
        current_hour: float = 12.0,
    ) -> pd.DataFrame:
        """Build pandas DataFrame from batch of routes."""
        vectors = []

        for route_features, incident_features in zip(batch_routes, batch_incidents):
            vector = FeatureVectorBuilder.build_feature_vector(
                route_features, incident_features, current_hour
            )
            vectors.append(vector)

        df = pd.DataFrame(vectors)

        for col in LOCKED_FEATURE_ORDER:
            if col not in df.columns:
                df[col] = DEFAULT_SAFE_VALUES[col]

        return df[LOCKED_FEATURE_ORDER]

    @staticmethod
    def get_feature_order() -> List[str]:
        """Return locked feature order."""
        return LOCKED_FEATURE_ORDER.copy()

    @staticmethod
    def get_feature_count() -> int:
        """Return total feature count."""
        return FEATURE_COUNT
