# ============================================================
# SAFE ROUTE AI MODEL TESTER
# ============================================================
#
# PURPOSE:
#
# 1. Load trained XGBoost model
# 2. Simulate candidate routes
# 3. Pass route features into model
# 4. Predict risk_probability
# 5. Rank routes
# 6. Print safest route
#
# ============================================================

# ============================================================
# IMPORTS
# ============================================================

import pandas as pd
import numpy as np
import joblib

# ============================================================
# LOAD TRAINED MODEL
# ============================================================

MODEL_PATH = "safe_route_xgb_model.pkl"

print("\n================================================")
print("LOADING MODEL")
print("================================================")

model = joblib.load(MODEL_PATH)

print("\nModel Loaded Successfully")

# ============================================================
# LOCKED FEATURE ORDER
# ============================================================

FEATURE_COLUMNS = [

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
    "nighttime_score"
]

# ============================================================
# TEST ROUTES
# ============================================================
#
# Simulating:
# Route A
# Route B
# Route C
#
# ============================================================

routes = [

    # ========================================================
    # ROUTE A
    # HIGH RISK
    # ========================================================

    {
        "route_name": "Route A",
        "route_distance_m": 7200,
        "route_eta_sec": 950,
        "atm_count": 1,
        "bank_count": 1,
        "restaurant_count": 2,
        "pharmacy_count": 0,
        "cafe_count": 0,
        "shopping_mall_count": 0,
        "supermarket_count": 0,
        "hospital_count": 0,
        "police_count": 0,
        "bus_station_count": 0,
        "train_station_count": 0,
        "commercial_activity_score": 2,
        "emergency_presence_score": 0,
        "transport_activity_score": 0,
        "isolation_score": 96,
        "redzone_overlap_score": 0.82,
        "incident_density": 8.5,
        "avg_incident_severity": 8.2,
        "temporal_risk_score": 7.5,
        "nighttime_score": 0.95
    },

    # ========================================================
    # ROUTE B
    # MEDIUM RISK
    # ========================================================

    {
        "route_name": "Route B",

        "route_distance_m": 6100,
        "route_eta_sec": 780,

        "atm_count": 2,
        "bank_count": 2,
        "restaurant_count": 5,
        "pharmacy_count": 1,
        "cafe_count": 2,
        "shopping_mall_count": 0,
        "supermarket_count": 1,
        "hospital_count": 1,
        "police_count": 0,
        "bus_station_count": 2,
        "train_station_count": 0,

        "commercial_activity_score": 8,
        "emergency_presence_score": 1,
        "transport_activity_score": 2,
        "isolation_score": 78,

        "redzone_overlap_score": 0.38,
        "incident_density": 4.1,
        "avg_incident_severity": 5.3,
        "temporal_risk_score": 3.0,

        "nighttime_score": 0.55
    },

    # ========================================================
    # ROUTE C
    # SAFEST
    # ========================================================

    {
        "route_name": "Route C",

        "route_distance_m": 8000,
        "route_eta_sec": 1100,

        "atm_count": 4,
        "bank_count": 3,
        "restaurant_count": 12,
        "pharmacy_count": 3,
        "cafe_count": 5,
        "shopping_mall_count": 1,
        "supermarket_count": 3,
        "hospital_count": 2,
        "police_count": 1,
        "bus_station_count": 5,
        "train_station_count": 1,

        "commercial_activity_score": 21,
        "emergency_presence_score": 3,
        "transport_activity_score": 6,
        "isolation_score": 40,

        "redzone_overlap_score": 0.08,
        "incident_density": 1.2,
        "avg_incident_severity": 2.0,
        "temporal_risk_score": 0.5,

        "nighttime_score": 0.35
    }
]

# ============================================================
# BUILD DATAFRAME
# ============================================================

df = pd.DataFrame(routes)

# ============================================================
# EXTRACT FEATURES
# ============================================================

X = df[FEATURE_COLUMNS]

# ============================================================
# PREDICT
# ============================================================

print("\n================================================")
print("RUNNING MODEL PREDICTIONS")
print("================================================")

predictions = model.predict(X)

df["predicted_risk_probability"] = predictions

# ============================================================
# RISK BUCKETS
# ============================================================

def risk_bucket(x):

    if x < 0.40:
        return "SAFE"

    elif x < 0.65:
        return "MODERATE"

    else:
        return "DANGEROUS"

df["risk_bucket"] = df[
    "predicted_risk_probability"
].apply(risk_bucket)

# ============================================================
# SORT SAFEST FIRST
# ============================================================

df = df.sort_values(
    by="predicted_risk_probability"
)

# ============================================================
# OUTPUT RESULTS
# ============================================================

print("\n================================================")
print("ROUTE RISK ANALYSIS")
print("================================================")

for _, row in df.iterrows():

    print("\n----------------------------------------")

    print(f"Route: {row['route_name']}")

    print(
        f"Predicted Risk: "
        f"{row['predicted_risk_probability']:.4f}"
    )

    print(f"Risk Bucket: {row['risk_bucket']}")

    print(f"ETA (sec): {row['route_eta_sec']}")

    print(f"Distance (m): {row['route_distance_m']}")

    print("----------------------------------------")

# ============================================================
# FINAL RECOMMENDATION
# ============================================================

best_route = df.iloc[0]

print("\n================================================")
print("SAFEST ROUTE RECOMMENDATION")
print("================================================")

print(
    f"\nRecommended Route: "
    f"{best_route['route_name']}"
)

print(
    f"Predicted Risk Probability: "
    f"{best_route['predicted_risk_probability']:.4f}"
)

print(
    f"Risk Bucket: "
    f"{best_route['risk_bucket']}"
)

print("\n================================================")
print("TEST COMPLETE")
print("================================================")