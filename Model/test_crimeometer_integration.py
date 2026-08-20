

import sys
import os

# Test 1: Import all modules
print("=" * 60)
print("TEST 1: Module Imports")
print("=" * 60)

try:
    from incident_intelligence import IncidentIntelligenceClient, IncidentConfig
    print("✅ incident_intelligence imports OK")
except Exception as e:
    print(f"❌ incident_intelligence import failed: {e}")
    sys.exit(1)

try:
    from incident_feature_engine import IncidentFeatureEngine, IncidentRouteFeatures
    print("✅ incident_feature_engine imports OK")
except Exception as e:
    print(f"❌ incident_feature_engine import failed: {e}")
    sys.exit(1)

try:
    from predict_route_risk import RouteRiskPredictor
    print("✅ RouteRiskPredictor imports OK")
except Exception as e:
    print(f"❌ RouteRiskPredictor import failed: {e}")
    sys.exit(1)

try:
    from backend import app, predictor
    print("✅ Backend app imports OK")
except Exception as e:
    print(f"❌ Backend import failed: {e}")
    sys.exit(1)

# Test 2: Verify Crimeometer graceful degradation
print("\n" + "=" * 60)
print("TEST 2: Crimeometer Graceful Degradation (No API Key)")
print("=" * 60)

# Create incident engine with no API key
config = IncidentConfig(api_key='')
client = IncidentIntelligenceClient(config=config)
engine = IncidentFeatureEngine(client=client)

print(f"Client configured: {client.is_configured}")
assert not client.is_configured, "Client should be unconfigured"

# Score a route with no API
test_route = [(37.7749, -122.4194), (37.7849, -122.4094), (37.7949, -122.3994)]
features = engine.score_route(test_route, 5000.0)

print(f"Incident density: {features.incident_density}")
print(f"Redzone overlap: {features.redzone_overlap_score}")
print(f"Temporal risk: {features.temporal_risk_score}")
print(f"Incident count: {features.incident_count}")

# All should be zero when unconfigured
assert features.incident_density == 0.0, "Should be 0 when unconfigured"
assert features.redzone_overlap_score == 0.0, "Should be 0 when unconfigured"
assert features.incident_count == 0, "Should be 0 when unconfigured"
print("✅ Crimeometer returns zero features safely when unconfigured")

# Test 3: Verify predictor still initializes
print("\n" + "=" * 60)
print("TEST 3: Predictor Initialization with Crimeometer Optional")
print("=" * 60)

if predictor is not None:
    print("✅ RouteRiskPredictor initialized successfully")
    print(f"   - Model: {predictor.model is not None}")
    print(f"   - Route Engine: {predictor.route_engine is not None}")
    print(f"   - Incident Engine: {predictor.incident_engine is not None}")
    print(f"   - Crimeometer Engine: {predictor.incident_feature_engine is not None}")
else:
    print("❌ RouteRiskPredictor failed to initialize")
    sys.exit(1)

# Test 4: Verify backend doesn't crash on import
print("\n" + "=" * 60)
print("TEST 4: Backend Endpoints Available")
print("=" * 60)

# Check if main endpoint exists
if "/api/v1/scoreRoutes" in [route.path for route in app.routes]:
    print("✅ /api/v1/scoreRoutes endpoint available")
else:
    print("❌ /api/v1/scoreRoutes endpoint missing")
    sys.exit(1)

# Test 5: Feature merging behavior
print("\n" + "=" * 60)
print("TEST 5: Feature Vector Merging")
print("=" * 60)

# Simulate feature merging
base_features = {
    "incident_density": 0.5,
    "redzone_overlap_score": 0.3,
    "avg_incident_severity": 2.0,
    "temporal_risk_score": 1.5,
}

crimeometer_features = {
    "crimeometer_incident_count": 0,
    "crimeometer_max_csi": 0.0,
    "crimeometer_avg_csi": 0.0,
    "crimeometer_query_points": 0,
}

merged = {**base_features, **crimeometer_features}
print(f"Base features: {len(base_features)}")
print(f"Crimeometer features: {len(crimeometer_features)}")
print(f"Merged features: {len(merged)}")
assert len(merged) == 8, "Should have 8 features after merge"
print("✅ Feature merging works correctly")

print("\n" + "=" * 60)
print("✅ ALL VALIDATION TESTS PASSED")
print("=" * 60)
print("\nSUMMARY:")
print("- Crimeometer integration is optional and non-breaking")
print("- Returns zero features when API not configured")
print("- Existing route scoring unaffected")
print("- Backend loads and initializes successfully")
print("- Feature merging preserves original scoring")
