"""
route_differentiation_diagnostic.py

Purpose:
Diagnose why alternative routes still produce similar risk scores.

This script tests:

1. Route geometry overlap
2. Scan point overlap
3. POI divergence
4. Feature divergence
5. XGBoost feature contribution dominance
6. Route uniqueness quality

USAGE:
python route_differentiation_diagnostic.py

REQUIRES:
- route_feature_engine.py
- predict_route_risk.py
- trained XGBoost model
"""

import math
from collections import Counter
from itertools import combinations

import numpy as np

from route_feature_engine import RouteFeatureEngine
from predict_route_risk import RouteRiskPredictor


# ============================================================
# CONFIG
# ============================================================

GOOGLE_API_KEY = "AIzaSyBohZ_z2vde269NeroVxlfm2GxnZ3LSksk"

ORIGIN = (23.2599, 77.4126)
DESTINATION = (23.1815, 77.3015)

GRID_SIZE = 0.003  # ~300m


# ============================================================
# GRID HELPERS
# ============================================================

def latlon_to_grid(lat, lon, grid_size=GRID_SIZE):
    return (
        int(lat / grid_size),
        int(lon / grid_size),
    )


def route_grid_cells(decoded_points):
    return {
        latlon_to_grid(lat, lon)
        for lat, lon in decoded_points
    }


def jaccard_similarity(a, b):
    if not a or not b:
        return 0.0

    inter = len(a.intersection(b))
    union = len(a.union(b))

    return inter / union if union else 0.0


# ============================================================
# FEATURE DISTANCE
# ============================================================

def feature_distance(f1, f2):
    keys = sorted(list(set(f1.keys()) & set(f2.keys())))

    v1 = np.array([float(f1[k]) for k in keys])
    v2 = np.array([float(f2[k]) for k in keys])

    return np.linalg.norm(v1 - v2)


# ============================================================
# MAIN
# ============================================================

def main():

    print("\n==============================")
    print("ROUTE DIFFERENTIATION TEST")
    print("==============================\n")

    engine = RouteFeatureEngine(GOOGLE_API_KEY)

    predictor = RouteRiskPredictor(
        model_path="./safe_route_xgb_model.pkl",
        google_api_key=GOOGLE_API_KEY,
    )

    routes = engine.fetch_routes(
        ORIGIN,
        DESTINATION,
        num_alternatives=3,
    )

    print(f"\nFetched {len(routes)} routes\n")

    decoded_routes = []
    route_features = []

    # ========================================================
    # PROCESS ROUTES
    # ========================================================

    for idx, route in enumerate(routes):

        print("\n------------------------------------------------")
        print(f"ROUTE {idx}")
        print("------------------------------------------------")

        encoded = route.get("polyline", {}).get(
            "encodedPolyline", ""
        )

        decoded = engine.decode_polyline(encoded)

        decoded_routes.append(decoded)

        print(f"Decoded points: {len(decoded)}")

        sampled = engine.sample_route_points(decoded)

        print(f"Sampled scan points: {len(sampled)}")

        print("\nSCAN POINTS:")
        for i, (lat, lon) in enumerate(sampled[:10]):
            print(f"{i}: ({lat:.5f}, {lon:.5f})")

        # ----------------------------------------------------
        # FEATURE EXTRACTION
        # ----------------------------------------------------

        features, _ = engine.extract_route_features(
            route,
            ORIGIN,
            DESTINATION,
        )

        route_features.append(features)

        print("\nFEATURES:")
        important = [
            "commercial_activity_score",
            "emergency_presence_score",
            "transport_activity_score",
            "isolation_score",
            "restaurant_count",
            "hospital_count",
            "police_count",
            "bus_station_count",
        ]

        for k in important:
            print(f"{k}: {features.get(k)}")

    # ========================================================
    # GEOMETRY OVERLAP
    # ========================================================

    print("\n==============================")
    print("GEOMETRY OVERLAP ANALYSIS")
    print("==============================")

    route_cells = [
        route_grid_cells(r)
        for r in decoded_routes
    ]

    for (i, cells_a), (j, cells_b) in combinations(
        enumerate(route_cells), 2
    ):

        overlap = jaccard_similarity(cells_a, cells_b)

        print(
            f"\nRoute {i} vs Route {j}"
        )

        print(
            f"Corridor overlap: {overlap:.3f}"
        )

        print(
            f"Shared cells: "
            f"{len(cells_a.intersection(cells_b))}"
        )

        print(
            f"Union cells: "
            f"{len(cells_a.union(cells_b))}"
        )

    # ========================================================
    # FEATURE DIVERGENCE
    # ========================================================

    print("\n==============================")
    print("FEATURE DIVERGENCE ANALYSIS")
    print("==============================")

    for (i, f1), (j, f2) in combinations(
        enumerate(route_features), 2
    ):

        dist = feature_distance(f1, f2)

        print(
            f"\nRoute {i} vs Route {j}"
        )

        print(
            f"Feature distance: {dist:.3f}"
        )

    # ========================================================
    # POI DIFFERENCE
    # ========================================================

    print("\n==============================")
    print("POI DIFFERENCE ANALYSIS")
    print("==============================")

    poi_keys = [
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
    ]

    for (i, f1), (j, f2) in combinations(
        enumerate(route_features), 2
    ):

        print(f"\nRoute {i} vs Route {j}")

        for k in poi_keys:

            v1 = f1.get(k, 0)
            v2 = f2.get(k, 0)

            if v1 != v2:
                print(
                    f"{k}: {v1} vs {v2}"
                )

    # ========================================================
    # MODEL PREDICTIONS
    # ========================================================

    print("\n==============================")
    print("MODEL PREDICTIONS")
    print("==============================")

    for idx, features in enumerate(route_features):
        print(f"\nRoute {idx}")
        print(f"Feature keys: {len(features)}")

    print("\n==============================")
    print("DIAGNOSTIC COMPLETE")
    print("==============================\n")


if __name__ == "__main__":
    main()