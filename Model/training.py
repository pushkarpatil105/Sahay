from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.inspection import permutation_importance
from sklearn.metrics import (
    make_scorer,
    mean_absolute_error,
    mean_squared_error,
    r2_score,
)
from sklearn.model_selection import RandomizedSearchCV, train_test_split
from xgboost import XGBRegressor


BASE_DIR = Path(__file__).resolve().parent
DATASET_PATH = BASE_DIR / "safe_route_synthetic_dataset.csv"
MODEL_OUTPUT = BASE_DIR / "safe_route_xgb_model.pkl"

RANDOM_SEED = 42
DATASET_ROWS = 10_000
SAFE_MAX = 0.40
DANGEROUS_MIN = 0.65
EARLY_STOPPING_ROUNDS = 50


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
    "nighttime_score",
]

TARGET_COLUMN = "risk_probability"

COUNT_COLUMNS = [
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
]

FLOAT_COLUMNS = [
    "isolation_score",
    "redzone_overlap_score",
    "incident_density",
    "avg_incident_severity",
    "temporal_risk_score",
    "nighttime_score",
    "risk_probability",
]


def clip(value, lower, upper):
    return max(lower, min(value, upper))


def sample_interval(rng, intervals):
    weights = np.array([weight for weight, _, _ in intervals], dtype=float)
    weights = weights / weights.sum()
    index = rng.choice(len(intervals), p=weights)
    _, start, end = intervals[index]
    if start < end:
        return rng.uniform(start, end)
    if start > end:
        span = (24 - start) + end
        value = start + rng.uniform(0, span)
        return value if value < 24 else value - 24
    return float(start)


def bounded_poisson(rng, lam, max_value):
    return int(min(rng.poisson(max(lam, 0.01)), max_value))


def choose_subtype(rng, target_bucket):
    subtype_weights = {
        "safe": [("protected_dense", 0.52), ("community_suburb", 0.48)],
        "moderate": [("mixed_commute", 0.58), ("aging_corridor", 0.42)],
        "dangerous": [("isolated_redzone", 0.56), ("nightlife_hotspot", 0.44)],
    }
    subtypes, weights = zip(*subtype_weights[target_bucket])
    return rng.choice(subtypes, p=np.array(weights) / np.sum(weights))


def sample_hour(rng, target_bucket, subtype):
    if target_bucket == "safe":
        intervals = [(0.62, 7.0, 18.5), (0.23, 18.5, 22.0), (0.15, 5.0, 7.0)]
    elif target_bucket == "moderate":
        intervals = [(0.33, 7.0, 10.0), (0.28, 16.0, 20.5), (0.24, 10.0, 16.0), (0.15, 20.5, 1.5)]
    elif subtype == "nightlife_hotspot":
        intervals = [(0.54, 20.0, 2.5), (0.26, 2.5, 5.5), (0.20, 16.0, 20.0)]
    else:
        intervals = [(0.60, 21.0, 5.5), (0.25, 18.0, 21.0), (0.15, 5.5, 9.0)]
    return sample_interval(rng, intervals)


def sample_distance_m(rng, subtype):
    configs = {
        "protected_dense": (3.0, 1800, 1500, 11000),
        "community_suburb": (3.3, 2100, 2200, 13000),
        "mixed_commute": (3.6, 2300, 2600, 15000),
        "aging_corridor": (3.8, 2500, 3200, 16500),
        "isolated_redzone": (4.2, 2600, 4500, 18000),
        "nightlife_hotspot": (3.1, 2200, 2800, 14000),
    }
    shape, scale, lower, upper = configs[subtype]
    return int(clip(rng.gamma(shape, scale), lower, upper))


def sample_context(rng, target_bucket, subtype):
    if subtype == "protected_dense":
        return {
            "urban_density": rng.uniform(0.72, 0.98),
            "emergency_hub": rng.uniform(0.40, 0.85),
            "transport_hub": rng.uniform(0.35, 0.80),
            "nightlife_factor": rng.uniform(0.08, 0.28),
            "isolated_factor": rng.uniform(0.02, 0.18),
            "hotspot_factor": rng.uniform(0.04, 0.18),
        }
    if subtype == "community_suburb":
        return {
            "urban_density": rng.uniform(0.42, 0.74),
            "emergency_hub": rng.uniform(0.18, 0.55),
            "transport_hub": rng.uniform(0.16, 0.50),
            "nightlife_factor": rng.uniform(0.00, 0.14),
            "isolated_factor": rng.uniform(0.10, 0.30),
            "hotspot_factor": rng.uniform(0.00, 0.10),
        }
    if subtype == "mixed_commute":
        return {
            "urban_density": rng.uniform(0.34, 0.76),
            "emergency_hub": rng.uniform(0.14, 0.52),
            "transport_hub": rng.uniform(0.24, 0.76),
            "nightlife_factor": rng.uniform(0.08, 0.30),
            "isolated_factor": rng.uniform(0.15, 0.42),
            "hotspot_factor": rng.uniform(0.12, 0.32),
        }
    if subtype == "aging_corridor":
        return {
            "urban_density": rng.uniform(0.18, 0.54),
            "emergency_hub": rng.uniform(0.04, 0.32),
            "transport_hub": rng.uniform(0.08, 0.40),
            "nightlife_factor": rng.uniform(0.00, 0.12),
            "isolated_factor": rng.uniform(0.32, 0.60),
            "hotspot_factor": rng.uniform(0.05, 0.18),
        }
    if subtype == "isolated_redzone":
        return {
            "urban_density": rng.uniform(0.04, 0.30),
            "emergency_hub": rng.uniform(0.00, 0.18),
            "transport_hub": rng.uniform(0.00, 0.22),
            "nightlife_factor": rng.uniform(0.00, 0.08),
            "isolated_factor": rng.uniform(0.62, 0.98),
            "hotspot_factor": rng.uniform(0.04, 0.14),
        }
    return {
        "urban_density": rng.uniform(0.62, 0.96),
        "emergency_hub": rng.uniform(0.10, 0.36),
        "transport_hub": rng.uniform(0.34, 0.82),
        "nightlife_factor": rng.uniform(0.62, 1.00),
        "isolated_factor": rng.uniform(0.06, 0.24),
        "hotspot_factor": rng.uniform(0.56, 0.98),
    }


def sample_redzone_overlap(rng, subtype, isolated_factor, hotspot_factor):
    alpha_beta = {
        "protected_dense": (1.4, 9.0),
        "community_suburb": (1.6, 8.3),
        "mixed_commute": (2.2, 3.8),
        "aging_corridor": (2.5, 3.0),
        "isolated_redzone": (4.4, 1.6),
        "nightlife_hotspot": (3.2, 1.9),
    }
    alpha, beta = alpha_beta[subtype]
    overlap = rng.beta(alpha, beta)
    overlap += 0.06 * isolated_factor + 0.05 * hotspot_factor + rng.normal(0, 0.02)
    return clip(overlap, 0.0, 1.0)


def compute_route_eta_sec(rng, distance_m, hour, context):
    rush_hour = (
        np.exp(-((hour - 8.5) / 1.9) ** 2) + np.exp(-((hour - 18.0) / 2.1) ** 2)
    )
    free_flow_speed = (
        12.5
        - 4.6 * context["urban_density"]
        + 2.0 * context["isolated_factor"]
        - 1.2 * context["nightlife_factor"]
        + rng.normal(0, 0.8)
    )
    congestion = (
        0.88
        + 0.50 * rush_hour
        + 0.22 * context["hotspot_factor"]
        + 0.16 * context["urban_density"]
        - 0.10 * (abs(hour - 12) / 12)
        + rng.normal(0, 0.05)
    )
    speed_mps = clip(free_flow_speed / max(congestion, 0.55), 2.8, 16.0)
    return int(clip(distance_m / speed_mps, 300, 5400))


def generate_counts(rng, distance_m, context):
    route_km = max(distance_m / 1000.0, 1.0)
    exposure_scale = route_km ** 0.92
    urban_density = context["urban_density"]
    nightlife_factor = context["nightlife_factor"]
    emergency_hub = context["emergency_hub"]
    transport_hub = context["transport_hub"]
    hotspot_factor = context["hotspot_factor"]

    restaurant_count = bounded_poisson(
        rng,
        exposure_scale * (0.22 + 1.15 * urban_density + 1.80 * nightlife_factor),
        30,
    )
    cafe_count = bounded_poisson(
        rng,
        exposure_scale * (0.12 + 0.85 * urban_density + 1.20 * nightlife_factor),
        20,
    )
    shopping_mall_count = bounded_poisson(
        rng,
        exposure_scale * (0.03 + 0.18 * urban_density + 0.04 * hotspot_factor),
        6,
    )
    supermarket_count = bounded_poisson(
        rng,
        exposure_scale * (0.07 + 0.44 * urban_density),
        10,
    )
    atm_count = bounded_poisson(
        rng,
        exposure_scale * (0.08 + 0.34 * urban_density + 0.10 * nightlife_factor),
        12,
    )
    bank_count = bounded_poisson(
        rng,
        exposure_scale * (0.05 + 0.26 * urban_density),
        10,
    )
    pharmacy_count = bounded_poisson(
        rng,
        exposure_scale * (0.05 + 0.30 * urban_density),
        12,
    )
    hospital_count = bounded_poisson(
        rng,
        exposure_scale * (0.015 + 0.10 * urban_density + 0.28 * emergency_hub),
        6,
    )
    police_count = bounded_poisson(
        rng,
        exposure_scale * (0.015 + 0.08 * urban_density + 0.24 * emergency_hub),
        6,
    )
    bus_station_count = bounded_poisson(
        rng,
        exposure_scale * (0.05 + 0.34 * urban_density + 0.55 * transport_hub + 0.16 * hotspot_factor),
        18,
    )
    train_station_count = bounded_poisson(
        rng,
        exposure_scale * (0.01 + 0.08 * urban_density + 0.18 * transport_hub),
        5,
    )

    return {
        "atm_count": atm_count,
        "bank_count": bank_count,
        "restaurant_count": restaurant_count,
        "pharmacy_count": pharmacy_count,
        "cafe_count": cafe_count,
        "shopping_mall_count": shopping_mall_count,
        "supermarket_count": supermarket_count,
        "hospital_count": hospital_count,
        "police_count": police_count,
        "bus_station_count": bus_station_count,
        "train_station_count": train_station_count,
    }


def build_route_features(rng, target_bucket):
    subtype = choose_subtype(rng, target_bucket)
    context = sample_context(rng, target_bucket, subtype)
    hour = sample_hour(rng, target_bucket, subtype)
    nighttime_score = abs(hour - 12) / 12

    route_distance_m = sample_distance_m(rng, subtype)
    route_eta_sec = compute_route_eta_sec(rng, route_distance_m, hour, context)

    counts = generate_counts(rng, route_distance_m, context)

    commercial_activity_score = (
        counts["restaurant_count"]
        + counts["cafe_count"]
        + counts["shopping_mall_count"]
        + counts["supermarket_count"]
    )
    emergency_presence_score = counts["hospital_count"] + counts["police_count"]
    transport_activity_score = counts["bus_station_count"] + counts["train_station_count"]

    isolation_score = max(
        0.0,
        100
        - (
            2.0 * commercial_activity_score
            + 1.5 * transport_activity_score
            + 2.0 * emergency_presence_score
        ),
    )
    isolation_score = clip(isolation_score, 0.0, 100.0)

    redzone_overlap_score = sample_redzone_overlap(
        rng,
        subtype,
        context["isolated_factor"],
        context["hotspot_factor"],
    )

    route_km = max(route_distance_m / 1000.0, 1.0)
    public_activity = 1 - np.exp(-commercial_activity_score / 10.0)
    isolation_norm = isolation_score / 100.0
    incident_density_signal = (
        0.18
        + 5.0 * (redzone_overlap_score ** 1.35)
        + 1.55 * nighttime_score
        + 1.15 * isolation_norm
        + 1.25 * context["hotspot_factor"]
        + 0.35 * public_activity
        + 0.18 * min(route_km / 12.0, 1.0)
        + rng.normal(0, 0.45)
    )
    incident_density_signal = max(incident_density_signal, 0.05)
    incident_count = int(
        rng.poisson(incident_density_signal * route_km * rng.uniform(0.78, 1.22))
    )
    incident_density = incident_count / route_km if route_km else 0.0

    if incident_count > 0:
        severity_center = (
            2.0
            + 2.7 * redzone_overlap_score
            + 0.9 * nighttime_score
            + 0.9 * context["isolated_factor"]
            + 0.6 * context["hotspot_factor"]
            + 0.4 * min(incident_density / 10.0, 1.0)
            + rng.normal(0, 0.45)
        )
        severity_values = np.clip(rng.normal(severity_center, 1.9, size=incident_count), 1, 10)
        avg_incident_severity = float(np.mean(severity_values))

        recency_scale_hours = clip(
            250
            - 120 * redzone_overlap_score
            - 90 * nighttime_score
            - 60 * context["hotspot_factor"]
            - 45 * isolation_norm
            + rng.normal(0, 35),
            6,
            420,
        )
        incident_ages_hours = np.clip(
            rng.exponential(scale=recency_scale_hours, size=incident_count),
            0.15,
            720,
        )
        recency_volatility = rng.lognormal(mean=-0.12, sigma=0.40, size=incident_count)
        temporal_risk_score = float(
            np.sum((severity_values * recency_volatility) * np.exp(-0.08 * incident_ages_hours))
        )
    else:
        avg_incident_severity = 0.0
        temporal_risk_score = 0.0

    incident_density_norm = min(incident_density / 10.0, 1.0)
    severity_norm = min(avg_incident_severity / 10.0, 1.0)
    temporal_norm = min(temporal_risk_score / 20.0, 1.0)
    distance_norm = min(route_distance_m / 15000.0, 1.0)
    eta_norm = min(route_eta_sec / 3600.0, 1.0)
    emergency_norm = min(emergency_presence_score / 5.0, 1.0)
    transport_norm = min(transport_activity_score / 10.0, 1.0)
    commercial_norm = 1 - np.exp(-commercial_activity_score / 8.0)
    redzone_effect = redzone_overlap_score ** 1.5
    incident_interaction = incident_density_norm * severity_norm

    base_risk_probability = (
        0.22 * redzone_effect
        + 0.18 * incident_density_norm
        + 0.12 * severity_norm
        + 0.10 * incident_interaction
        + 0.12 * isolation_norm
        + 0.08 * temporal_norm
        + 0.08 * nighttime_score
        + 0.03 * distance_norm
        + 0.02 * eta_norm
        + 0.03 * (1 - commercial_norm)
        + 0.01 * (1 - emergency_norm)
        + 0.01 * (1 - transport_norm)
    )

    uncertainty = 0.020 + 0.035 * (1 - abs(base_risk_probability - 0.5) * 2)
    hidden_exposure = 0.45 * context["hotspot_factor"] + 0.45 * context["isolated_factor"] + 0.10 * distance_norm
    hidden_context_noise = rng.normal(
        0,
        uncertainty * (0.8 + 0.4 * hidden_exposure),
    )
    unseen_event_surge = rng.uniform(-0.028, 0.028) * (
        0.25 + 0.50 * nighttime_score + 0.25 * min(route_km / 15.0, 1.0)
    )
    label_jitter = rng.uniform(-0.018, 0.018)
    risk_probability = clip(
        base_risk_probability + hidden_context_noise + unseen_event_surge + label_jitter,
        0.0,
        1.0,
    )

    return {
        "route_distance_m": route_distance_m,
        "route_eta_sec": route_eta_sec,
        **counts,
        "commercial_activity_score": commercial_activity_score,
        "emergency_presence_score": emergency_presence_score,
        "transport_activity_score": transport_activity_score,
        "isolation_score": isolation_score,
        "redzone_overlap_score": redzone_overlap_score,
        "incident_density": incident_density,
        "avg_incident_severity": avg_incident_severity,
        "temporal_risk_score": temporal_risk_score,
        "nighttime_score": nighttime_score,
        "risk_probability": risk_probability,
    }


def risk_band(value):
    if value < SAFE_MAX:
        return "safe"
    if value < DANGEROUS_MIN:
        return "moderate"
    return "dangerous"


def generate_dataset(rows=DATASET_ROWS, seed=RANDOM_SEED):
    rng = np.random.default_rng(seed)
    target_counts = {
        "safe": int(rows * 0.30),
        "moderate": int(rows * 0.40),
        "dangerous": rows - int(rows * 0.30) - int(rows * 0.40),
    }
    bucket_rows = {bucket: [] for bucket in target_counts}

    for bucket, target_count in target_counts.items():
        attempts = 0
        while len(bucket_rows[bucket]) < target_count:
            sample = build_route_features(rng, bucket)
            if risk_band(sample[TARGET_COLUMN]) == bucket:
                bucket_rows[bucket].append(sample)
            attempts += 1
            if attempts > target_count * 200:
                raise RuntimeError(f"Could not satisfy target distribution for {bucket}.")

    dataset = pd.DataFrame(
        bucket_rows["safe"] + bucket_rows["moderate"] + bucket_rows["dangerous"]
    )
    dataset = dataset.sample(frac=1.0, random_state=seed).reset_index(drop=True)

    for column in COUNT_COLUMNS:
        dataset[column] = dataset[column].round().astype(int)
    dataset["isolation_score"] = dataset["isolation_score"].round(1)
    for column in FLOAT_COLUMNS:
        dataset[column] = dataset[column].astype(float).round(6)

    return dataset


def rmse_metric(y_true, y_pred):
    return np.sqrt(mean_squared_error(y_true, y_pred))


def print_header(title):
    print("\n" + "=" * 56)
    print(title)
    print("=" * 56)


def summarize_dataset(df):
    print_header("DATASET SUMMARY")
    print(f"Saved rows: {len(df):,}")
    print(f"Columns: {len(df.columns)}")
    print("\nRisk distribution:")
    safe_ratio = (df[TARGET_COLUMN] < SAFE_MAX).mean()
    moderate_ratio = ((df[TARGET_COLUMN] >= SAFE_MAX) & (df[TARGET_COLUMN] < DANGEROUS_MIN)).mean()
    dangerous_ratio = (df[TARGET_COLUMN] >= DANGEROUS_MIN).mean()
    print(f"safe       (< {SAFE_MAX:.2f}): {safe_ratio:.2%}")
    print(f"moderate   ({SAFE_MAX:.2f} - {DANGEROUS_MIN:.2f}): {moderate_ratio:.2%}")
    print(f"dangerous  (>= {DANGEROUS_MIN:.2f}): {dangerous_ratio:.2%}")
    print("\nFeature snapshot:")
    print(
        df[
            [
                "route_distance_m",
                "route_eta_sec",
                "commercial_activity_score",
                "isolation_score",
                "redzone_overlap_score",
                "incident_density",
                "avg_incident_severity",
                "temporal_risk_score",
                "nighttime_score",
                TARGET_COLUMN,
            ]
        ].describe()
    )


def split_data(X, y):
    risk_labels = pd.Series([risk_band(value) for value in y], index=y.index)
    (
        X_train_full,
        X_test,
        y_train_full,
        y_test,
        train_labels,
        test_labels,
    ) = train_test_split(
        X,
        y,
        risk_labels,
        test_size=0.15,
        random_state=RANDOM_SEED,
        stratify=risk_labels,
    )
    (
        X_train,
        X_val,
        y_train,
        y_val,
        train_labels,
        val_labels,
    ) = train_test_split(
        X_train_full,
        y_train_full,
        train_labels,
        test_size=0.176470588,
        random_state=RANDOM_SEED,
        stratify=train_labels,
    )
    return X_train, X_val, X_test, y_train, y_val, y_test, X_train_full, y_train_full, test_labels


def train_model(df):
    print_header("LOADING DATASET")
    print(f"Dataset path: {DATASET_PATH}")
    print(f"Dataset shape: {df.shape}")
    print("\nColumns:")
    print(df.columns.tolist())

    X = df[FEATURE_COLUMNS]
    y = df[TARGET_COLUMN]

    print_header("BUILDING TRAIN / VALIDATION / TEST SPLITS")
    (
        X_train,
        X_val,
        X_test,
        y_train,
        y_val,
        y_test,
        X_train_full,
        y_train_full,
        test_labels,
    ) = split_data(X, y)

    print(f"Train shape: {X_train.shape}")
    print(f"Validation shape: {X_val.shape}")
    print(f"Test shape: {X_test.shape}")

    scoring = {
        "MAE": make_scorer(mean_absolute_error, greater_is_better=False),
        "RMSE": make_scorer(rmse_metric, greater_is_better=False),
        "R2": "r2",
    }

    base_estimator = XGBRegressor(
        objective="reg:squarederror",
        tree_method="hist",
        random_state=RANDOM_SEED,
        n_jobs=1,
    )

    param_distributions = {
        "n_estimators": [300, 500, 700, 900, 1100, 1300],
        "max_depth": [3, 4, 5, 6, 7, 8],
        "learning_rate": np.linspace(0.02, 0.12, 11),
        "min_child_weight": [1, 2, 3, 4, 5, 6],
        "subsample": np.linspace(0.65, 1.0, 8),
        "colsample_bytree": np.linspace(0.60, 1.0, 9),
        "gamma": np.linspace(0.0, 0.40, 9),
        "reg_alpha": np.linspace(0.0, 0.50, 11),
        "reg_lambda": np.linspace(0.8, 2.2, 15),
    }

    print_header("RANDOMIZED SEARCH WITH 5-FOLD CV")
    search = RandomizedSearchCV(
        estimator=base_estimator,
        param_distributions=param_distributions,
        n_iter=24,
        scoring=scoring,
        refit="RMSE",
        cv=5,
        random_state=RANDOM_SEED,
        n_jobs=-1,
        verbose=1,
    )
    search.fit(X_train, y_train)

    best_index = search.best_index_
    cv_mae = -search.cv_results_["mean_test_MAE"][best_index]
    cv_rmse = -search.cv_results_["mean_test_RMSE"][best_index]
    cv_r2 = search.cv_results_["mean_test_R2"][best_index]

    print("\nBest parameters:")
    print(search.best_params_)
    print("\nBest 5-fold CV metrics:")
    print(f"MAE  : {cv_mae:.6f}")
    print(f"RMSE : {cv_rmse:.6f}")
    print(f"R2   : {cv_r2:.6f}")

    early_stop_params = {
        **search.best_params_,
        "objective": "reg:squarederror",
        "tree_method": "hist",
        "random_state": RANDOM_SEED,
        "n_jobs": -1,
        "eval_metric": "rmse",
        "early_stopping_rounds": EARLY_STOPPING_ROUNDS,
    }

    print_header("EARLY STOPPING FIT")
    early_stop_model = XGBRegressor(**early_stop_params)
    early_stop_model.fit(
        X_train,
        y_train,
        eval_set=[(X_val, y_val)],
        verbose=False,
    )

    best_iteration = getattr(early_stop_model, "best_iteration", None)
    optimal_n_estimators = (
        int(best_iteration + 1)
        if best_iteration is not None
        else int(search.best_params_["n_estimators"])
    )
    print(f"Optimal boosting rounds: {optimal_n_estimators}")

    final_params = {
        **search.best_params_,
        "n_estimators": optimal_n_estimators,
        "objective": "reg:squarederror",
        "tree_method": "hist",
        "random_state": RANDOM_SEED,
        "n_jobs": -1,
        "eval_metric": "rmse",
    }

    print_header("FINAL MODEL FIT")
    final_model = XGBRegressor(**final_params)
    final_model.fit(X_train_full, y_train_full, verbose=False)

    print_header("MODEL EVALUATION")
    y_pred = final_model.predict(X_test)
    mae = mean_absolute_error(y_test, y_pred)
    rmse = rmse_metric(y_test, y_pred)
    r2 = r2_score(y_test, y_pred)

    print(f"MAE  : {mae:.6f}")
    print(f"RMSE : {rmse:.6f}")
    print(f"R2   : {r2:.6f}")

    print_header("FEATURE IMPORTANCE ANALYSIS")
    gain_importance = pd.DataFrame(
        {
            "feature": FEATURE_COLUMNS,
            "gain_importance": final_model.feature_importances_,
        }
    ).sort_values("gain_importance", ascending=False)

    permutation = permutation_importance(
        final_model,
        X_test,
        y_test,
        n_repeats=10,
        random_state=RANDOM_SEED,
        scoring=make_scorer(rmse_metric, greater_is_better=False),
        n_jobs=-1,
    )
    permutation_importance_df = pd.DataFrame(
        {
            "feature": FEATURE_COLUMNS,
            "permutation_importance": permutation.importances_mean,
        }
    ).sort_values("permutation_importance", ascending=False)

    importance_report = gain_importance.merge(
        permutation_importance_df,
        on="feature",
        how="left",
    )
    print(importance_report.to_string(index=False))

    top_feature = gain_importance.iloc[0]
    top_five_share = gain_importance.head(5)["gain_importance"].sum()
    print("\nDominance check:")
    print(f"Top feature: {top_feature['feature']} ({top_feature['gain_importance']:.4f})")
    print(f"Top-5 cumulative gain importance: {top_five_share:.4f}")

    print_header("MODEL SAVE")
    joblib.dump(final_model, MODEL_OUTPUT)
    print(f"Saved model to: {MODEL_OUTPUT}")

    print_header("SAMPLE PREDICTION")
    sample_route = X_test.iloc[[0]]
    sample_prediction = final_model.predict(sample_route)[0]
    print(f"Predicted risk_probability: {sample_prediction:.6f}")
    print(f"Actual risk_probability   : {y_test.iloc[0]:.6f}")
    print(f"Test bucket               : {test_labels.iloc[0]}")


def main():
    print_header("SYNTHETIC DATASET GENERATION")
    df = generate_dataset()
    df.to_csv(DATASET_PATH, index=False)
    print(f"Saved dataset to: {DATASET_PATH}")
    summarize_dataset(df)
    train_model(df)
    print_header("PIPELINE COMPLETE")


if __name__ == "__main__":
    main()
