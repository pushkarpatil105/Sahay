"""
Route Feature Engine - Corridor-Aware Geospatial Intelligence
==============================================================
Transforms route scoring from waypoint-centric POI extraction into a production-grade
corridor-aware route intelligence engine that prevents spatial feature collapse.

Architecture:
1. Spatial Corridor Engine: Represent routes as grid-cell corridors
2. Route Overlap Analysis: Detect shared geography between routes (Jaccard similarity)
3. Unique Geography Extraction: Prioritize route-specific corridor regions
4. Stratified Sampling: Evenly distributed route sampling (0%, 25%, 50%, 75%, 100%)
5. Corridor-Aware Places Scanning: Scan unique cells preferentially
6. Weighted POI Aggregation: Weight POIs by corridor uniqueness
7. Production Caching: Fine-grained spatial cache to prevent contamination
8. Route Differentiation Metrics: Expose corridor_overlap_score, unique_corridor_ratio, etc.

The 22-feature XGBoost schema remains unchanged. New metrics are metadata only.
"""

import math
import time
from collections import defaultdict
from typing import Dict, List, Tuple, Set, Optional

import numpy as np
import polyline
import requests

# ============================================================
# CONFIGURATION
# ============================================================

PLACES_RADIUS = 200  # Reduced from 500m to prevent overlap contamination
ROUTE_SAMPLE_DISTANCE = 5  # Legacy fallback for backward compatibility
REQUEST_DELAY = 0.1
GRID_CELL_SIZE = 0.005  # ~500m at equator; finer than cache grid for corridor mapping
CACHE_GRID_SIZE = 0.01  # ~1km; coarser grid for Places API caching

# Diversity constraints
CORRIDOR_OVERLAP_REJECTION_THRESHOLD = 0.35  # Reject routes with >35% overlap (stricter)
MIDPOINT_PERTURBATION_DISTANCE = 0.05  # ~5km perturbation radius (larger)
MAX_DIVERSITY_ITERATIONS = 8  # Max attempts to find diverse routes
MIN_UNIQUE_ROUTES_REQUIRED = 2  # Minimum geographically distinct routes

TARGET_TYPES = {
    "atm": "atm_count",
    "bank": "bank_count",
    "restaurant": "restaurant_count",
    "pharmacy": "pharmacy_count",
    "cafe": "cafe_count",
    "shopping_mall": "shopping_mall_count",
    "supermarket": "supermarket_count",
    "hospital": "hospital_count",
    "police": "police_count",
    "bus_station": "bus_station_count",
    "train_station": "train_station_count",
}

# ============================================================
# SPATIAL CORRIDOR ENGINE
# ============================================================

class SpatialCorridorEngine:
    """
    Represents routes as spatial corridors (sets of grid cells).
    Enables overlap analysis and unique geography extraction.
    """

    def __init__(self, grid_cell_size: float = GRID_CELL_SIZE):
        self.grid_cell_size = grid_cell_size

    def _grid_id(self, lat: float, lon: float) -> Tuple[int, int]:
        """Convert lat/lon to grid cell ID."""
        return (int(lat / self.grid_cell_size), int(lon / self.grid_cell_size))

    def polyline_to_corridor(self, decoded_points: List[Tuple[float, float]]) -> Set[Tuple[int, int]]:
        """
        Convert decoded polyline points into a set of grid cells (corridor).
        Each point maps to one grid cell; the corridor is the union of all cells.
        """
        corridor = set()
        for lat, lon in decoded_points:
            corridor.add(self._grid_id(lat, lon))
        return corridor

    def jaccard_similarity(self, corridor_a: Set[Tuple[int, int]], corridor_b: Set[Tuple[int, int]]) -> float:
        """
        Compute Jaccard similarity between two corridors.
        Range: [0, 1]. 1.0 = identical corridors, 0.0 = no overlap.
        """
        if not corridor_a or not corridor_b:
            return 0.0
        intersection = len(corridor_a & corridor_b)
        union = len(corridor_a | corridor_b)
        return intersection / union if union > 0 else 0.0

    def overlap_percentage(self, corridor_a: Set[Tuple[int, int]], corridor_b: Set[Tuple[int, int]]) -> float:
        """
        Compute percentage of corridor_a that overlaps with corridor_b.
        Range: [0, 1]. 1.0 = all of A overlaps with B.
        """
        if not corridor_a:
            return 0.0
        intersection = len(corridor_a & corridor_b)
        return intersection / len(corridor_a)

    def unique_cells(self, corridor: Set[Tuple[int, int]], other_corridors: List[Set[Tuple[int, int]]]) -> Set[Tuple[int, int]]:
        """
        Extract cells unique to this corridor (not in any other corridor).
        """
        unique = corridor.copy()
        for other in other_corridors:
            unique -= other
        return unique

    def shared_cells(self, corridor: Set[Tuple[int, int]], other_corridors: List[Set[Tuple[int, int]]]) -> Set[Tuple[int, int]]:
        """
        Extract cells shared with at least one other corridor.
        """
        shared = set()
        for other in other_corridors:
            shared |= (corridor & other)
        return shared

    def min_overlap_with_set(self, corridor: Set[Tuple[int, int]], corridor_set: List[Set[Tuple[int, int]]]) -> float:
        """
        Compute minimum Jaccard similarity with any corridor in the set.
        Used to find the least-overlapping route.
        """
        if not corridor_set:
            return 1.0
        overlaps = [self.jaccard_similarity(corridor, other) for other in corridor_set]
        return min(overlaps) if overlaps else 1.0


# ============================================================
# ROUTE UNIQUENESS EVALUATOR
# ============================================================

class RouteUniquenessEvaluator:
    """
    Evaluates geographic uniqueness of routes.
    Rejects routes that are too similar to existing routes.
    """

    def __init__(self, corridor_engine: SpatialCorridorEngine, overlap_threshold: float = CORRIDOR_OVERLAP_REJECTION_THRESHOLD):
        self.corridor_engine = corridor_engine
        self.overlap_threshold = overlap_threshold

    def is_sufficiently_unique(self, candidate_corridor: Set[Tuple[int, int]], existing_corridors: List[Set[Tuple[int, int]]]) -> bool:
        """
        Check if candidate route is sufficiently unique from existing routes.
        Returns True if minimum overlap with any existing route is below threshold.
        """
        if not existing_corridors:
            return True
        min_overlap = self.corridor_engine.min_overlap_with_set(candidate_corridor, existing_corridors)
        return min_overlap < self.overlap_threshold

    def evaluate_batch(self, candidate_corridors: List[Set[Tuple[int, int]]]) -> List[int]:
        """
        Filter candidate corridors to keep only sufficiently unique ones.
        Returns indices of unique routes.
        """
        unique_indices = []
        accepted_corridors = []
        for idx, corridor in enumerate(candidate_corridors):
            if self.is_sufficiently_unique(corridor, accepted_corridors):
                unique_indices.append(idx)
                accepted_corridors.append(corridor)
        return unique_indices


# ============================================================
# MIDPOINT DIVERSIFICATION GENERATOR
# ============================================================

class MidpointDiversificationGenerator:
    """
    Generates geographically diverse waypoint anchors to force Google Routes API
    to produce distinct corridors instead of minor lane variations.
    """

    def __init__(self, perturbation_distance: float = MIDPOINT_PERTURBATION_DISTANCE):
        self.perturbation_distance = perturbation_distance

    def _perturb_coordinate(self, lat: float, lon: float, direction: str) -> Tuple[float, float]:
        """
        Perturb a coordinate in a cardinal direction.
        direction: 'N', 'S', 'E', 'W', 'NE', 'NW', 'SE', 'SW'
        """
        direction_map = {
            'N': (self.perturbation_distance, 0),
            'S': (-self.perturbation_distance, 0),
            'E': (0, self.perturbation_distance),
            'W': (0, -self.perturbation_distance),
            'NE': (self.perturbation_distance * 0.707, self.perturbation_distance * 0.707),
            'NW': (self.perturbation_distance * 0.707, -self.perturbation_distance * 0.707),
            'SE': (-self.perturbation_distance * 0.707, self.perturbation_distance * 0.707),
            'SW': (-self.perturbation_distance * 0.707, -self.perturbation_distance * 0.707),
        }
        dlat, dlon = direction_map.get(direction, (0, 0))
        return (lat + dlat, lon + dlon)

    def generate_waypoint_variants(self, origin: Tuple[float, float], destination: Tuple[float, float]) -> List[Tuple[float, float]]:
        """
        Generate perturbed midpoint waypoints to force route diversity.
        Returns list of waypoint coordinates (not including origin/destination).
        """
        midpoint_lat = (origin[0] + destination[0]) / 2.0
        midpoint_lon = (origin[1] + destination[1]) / 2.0
        
        # Generate waypoints at multiple distances and directions
        waypoints = []
        
        # Primary directions at base distance
        directions = ['N', 'S', 'E', 'W', 'NE', 'NW', 'SE', 'SW']
        for direction in directions:
            perturbed = self._perturb_coordinate(midpoint_lat, midpoint_lon, direction)
            waypoints.append(perturbed)
        
        # Secondary directions at 1.5x distance for more diversity
        original_perturbation = self.perturbation_distance
        self.perturbation_distance *= 1.5
        for direction in ['N', 'S', 'E', 'W']:
            perturbed = self._perturb_coordinate(midpoint_lat, midpoint_lon, direction)
            waypoints.append(perturbed)
        self.perturbation_distance = original_perturbation
        
        return waypoints


# ============================================================
# GRID CACHE FOR PLACES QUERIES
# ============================================================

class SpatialGridCache:
    """Fine-grained Places API cache to prevent contamination between nearby routes."""

    def __init__(self, cell_size: float = CACHE_GRID_SIZE):
        self.cell_size = cell_size
        self.cache = {}

    def grid_id(self, lat: float, lon: float) -> Tuple[int, int]:
        """Convert lat/lon to cache grid cell ID."""
        return (int(lat / self.cell_size), int(lon / self.cell_size))

    def get(self, lat: float, lon: float) -> Optional[List[Dict]]:
        """Retrieve cached places for grid cell."""
        gid = self.grid_id(lat, lon)
        return self.cache.get(gid)

    def set(self, lat: float, lon: float, places: List[Dict]) -> None:
        """Store places in grid cache."""
        gid = self.grid_id(lat, lon)
        self.cache[gid] = places

    def clear(self) -> None:
        """Clear cache."""
        self.cache.clear()


# ============================================================
# ROUTE FEATURE ENGINE
# ============================================================

class RouteFeatureEngine:
    """
    Corridor-aware route feature extraction engine.
    Processes routes as a batch to enable cross-route awareness.
    """

    def __init__(self, api_key: str):
        self.api_key = api_key
        self.grid_cache = SpatialGridCache()
        self.corridor_engine = SpatialCorridorEngine()
        self.uniqueness_evaluator = RouteUniquenessEvaluator(self.corridor_engine)
        self.midpoint_generator = MidpointDiversificationGenerator()
        self.routes_url = "https://routes.googleapis.com/directions/v2:computeRoutes"
        self.places_url = "https://maps.googleapis.com/maps/api/place/nearbysearch/json"
        self._places_consecutive_failures = 0
        self._places_max_failures = 3

    def _haversine_distance_m(
        self,
        origin: Tuple[float, float],
        destination: Tuple[float, float],
    ) -> float:
        """Approximate distance in meters between two coordinates."""
        lat1, lon1 = origin
        lat2, lon2 = destination
        radius_m = 6371000.0
        lat1_rad = math.radians(lat1)
        lat2_rad = math.radians(lat2)
        delta_lat = math.radians(lat2 - lat1)
        delta_lon = math.radians(lon2 - lon1)
        a = math.sin(delta_lat / 2) ** 2 + math.cos(lat1_rad) * math.cos(lat2_rad) * math.sin(delta_lon / 2) ** 2
        return 2 * radius_m * math.asin(math.sqrt(a))

    def _build_fallback_routes(
        self,
        origin: Tuple[float, float],
        destination: Tuple[float, float],
        num_alternatives: int = 3,
        travel_mode: str = "driving",
    ) -> List[Dict]:
        """Generate synthetic alternatives when Google Routes API is unavailable."""
        print("[RouteFeatureEngine] Using fallback route generator")
        lat1, lon1 = origin
        lat2, lon2 = destination
        base_distance = self._haversine_distance_m(origin, destination)
        mode_multiplier = {
            "driving": 1.12,
            "walking": 1.03,
            "transit": 1.18,
            "bicycling": 1.07,
        }.get(travel_mode.lower(), 1.12)

        routes = []
        for idx in range(num_alternatives):
            detour_factor = 1.0 + (0.15 * idx)
            distance_m = int(base_distance * mode_multiplier * detour_factor)
            duration_sec = max(60, int(distance_m / 11.0))

            midpoint_lat = (lat1 + lat2) / 2.0
            midpoint_lon = (lon1 + lon2) / 2.0
            offset = 0.05 * (idx + 1) if idx > 0 else 0.0

            control_lat = midpoint_lat + offset * (1 if idx % 2 == 0 else -1)
            control_lon = midpoint_lon - offset * (1 if idx % 2 == 0 else -1)

            route_points = []
            for step in range(11):
                t = step / 10.0
                if t <= 0.5:
                    local_t = t / 0.5
                    lat = lat1 + (control_lat - lat1) * local_t
                    lon = lon1 + (control_lon - lon1) * local_t
                else:
                    local_t = (t - 0.5) / 0.5
                    lat = control_lat + (lat2 - control_lat) * local_t
                    lon = control_lon + (lon2 - control_lon) * local_t
                route_points.append((lat, lon))

            encoded = polyline.encode(route_points)
            routes.append({
                "id": f"fallback_{idx + 1}",
                "distanceMeters": distance_m,
                "duration": f"{duration_sec}s",
                "polyline": {"encodedPolyline": encoded},
            })

        return routes

    def _route_midpoint_key(self, encoded: str) -> Tuple[float, float]:
        """Return midpoint of polyline for deduplication."""
        pts = self.decode_polyline(encoded)
        if not pts:
            return (0.0, 0.0)
        mid = pts[len(pts) // 2]
        return (round(mid[0], 2), round(mid[1], 2))

    def _call_routes_api(self, body: Dict, headers: Dict) -> List[Dict]:
        """Single Routes API call."""
        try:
            resp = requests.post(self.routes_url, headers=headers, json=body, timeout=8)
            if resp.status_code != 200:
                print(f"[RouteFeatureEngine] API {resp.status_code}: {resp.text[:120]}")
                return []
            routes = resp.json().get("routes", [])
            for r in routes:
                if "polyline" in r and "encodedPolyline" in r["polyline"]:
                    r["polyline_encoded"] = r["polyline"]["encodedPolyline"]
            return routes
        except requests.exceptions.RequestException as e:
            print(f"[RouteFeatureEngine] Request error: {e}")
            return []

    def fetch_routes(
        self,
        origin: Tuple[float, float],
        destination: Tuple[float, float],
        num_alternatives: int = 3,
        travel_mode: str = "driving",
    ) -> List[Dict]:
        """
        Fetch geographically diverse routes via diversity-constrained search.
        Iteratively requests routes and rejects those with high corridor overlap.
        """
        if not self.api_key:
            print("[RouteFeatureEngine] GOOGLE_API_KEY missing; using fallback routes")
            return self._build_fallback_routes(origin, destination, num_alternatives, travel_mode)

        mode_map = {"driving": "DRIVE", "walking": "WALK", "transit": "TRANSIT", "bicycling": "BICYCLE"}
        travel_mode_enum = mode_map.get(travel_mode.lower(), "DRIVE")

        headers = {
            "Content-Type": "application/json",
            "X-Goog-Api-Key": self.api_key,
            "X-Goog-FieldMask": "routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline",
        }

        origin_body = {"location": {"latLng": {"latitude": origin[0], "longitude": origin[1]}}}
        dest_body = {"location": {"latLng": {"latitude": destination[0], "longitude": destination[1]}}}

        unique_routes = []
        unique_corridors = []
        iteration = 0

        while len(unique_routes) < num_alternatives and iteration < MAX_DIVERSITY_ITERATIONS:
            iteration += 1
            print(f"[RouteFeatureEngine] Diversity iteration {iteration}/{MAX_DIVERSITY_ITERATIONS}")

            # Build variant requests
            variants = self._build_route_variants(
                origin_body, dest_body, travel_mode_enum, iteration
            )

            # Fetch and filter by uniqueness
            for body in variants:
                batch = self._call_routes_api(body, headers)
                for route in batch:
                    encoded = route.get("polyline", {}).get("encodedPolyline", "")
                    decoded = self.decode_polyline(encoded)
                    corridor = self.corridor_engine.polyline_to_corridor(decoded)

                    # Check uniqueness
                    if self.uniqueness_evaluator.is_sufficiently_unique(corridor, unique_corridors):
                        route["id"] = str(len(unique_routes))
                        unique_routes.append(route)
                        unique_corridors.append(corridor)
                        print(
                            f"[RouteFeatureEngine] Accepted route {route['id']}: "
                            f"min_overlap={self.corridor_engine.min_overlap_with_set(corridor, unique_corridors[:-1]):.3f}"
                        )
                        if len(unique_routes) >= num_alternatives:
                            break
                    else:
                        min_overlap = self.corridor_engine.min_overlap_with_set(corridor, unique_corridors)
                        print(
                            f"[RouteFeatureEngine] Rejected route: "
                            f"min_overlap={min_overlap:.3f} (threshold={CORRIDOR_OVERLAP_REJECTION_THRESHOLD})"
                        )

                if len(unique_routes) >= num_alternatives:
                    break

        if unique_routes:
            print(f"[RouteFeatureEngine] Final diverse route count: {len(unique_routes)}")
            return unique_routes[:num_alternatives]

        print("[RouteFeatureEngine] All diversity attempts failed; using fallback routes")
        return self._build_fallback_routes(origin, destination, num_alternatives, travel_mode)

    def _build_route_variants(
        self,
        origin_body: Dict,
        dest_body: Dict,
        travel_mode_enum: str,
        iteration: int,
    ) -> List[Dict]:
        """
        Build route request variants for diversity-constrained search.
        Combines route modifiers and waypoint perturbations.
        """
        variants = []

        if travel_mode_enum == "DRIVE":
            # Base variants with different routing preferences
            base_variants = [
                {
                    "travelMode": "DRIVE",
                    "computeAlternativeRoutes": True,
                    "routingPreference": "TRAFFIC_AWARE_OPTIMAL",
                    "routeModifiers": {"avoidFerries": True},
                },
                {
                    "travelMode": "DRIVE",
                    "computeAlternativeRoutes": True,
                    "routingPreference": "TRAFFIC_AWARE",
                    "routeModifiers": {"avoidHighways": True, "avoidFerries": True},
                },
                {
                    "travelMode": "DRIVE",
                    "computeAlternativeRoutes": True,
                    "routingPreference": "TRAFFIC_UNAWARE",
                    "routeModifiers": {"avoidTolls": True, "avoidFerries": True},
                },
            ]

            for base in base_variants:
                variant = {
                    "origin": origin_body,
                    "destination": dest_body,
                    **base,
                }
                variants.append(variant)

            # On later iterations, add waypoint-constrained variants
            if iteration > 1:
                origin_coord = (
                    origin_body["location"]["latLng"]["latitude"],
                    origin_body["location"]["latLng"]["longitude"],
                )
                dest_coord = (
                    dest_body["location"]["latLng"]["latitude"],
                    dest_body["location"]["latLng"]["longitude"],
                )
                waypoints = self.midpoint_generator.generate_waypoint_variants(origin_coord, dest_coord)

                # Use waypoints from this iteration
                waypoint_idx = (iteration - 2) % len(waypoints)
                waypoint = waypoints[waypoint_idx]
                waypoint_body = {"location": {"latLng": {"latitude": waypoint[0], "longitude": waypoint[1]}}}

                variant = {
                    "origin": origin_body,
                    "destination": dest_body,
                    "intermediates": [waypoint_body],
                    "travelMode": "DRIVE",
                    "computeAlternativeRoutes": True,
                    "routingPreference": "TRAFFIC_UNAWARE",
                }
                variants.append(variant)
        else:
            variants.append({
                "origin": origin_body,
                "destination": dest_body,
                "travelMode": travel_mode_enum,
                "computeAlternativeRoutes": True,
            })

        return variants

    def decode_polyline(self, encoded: str) -> List[Tuple[float, float]]:
        """Decode Google polyline to lat/lon points."""
        if not encoded:
            return []
        try:
            return polyline.decode(encoded)
        except Exception as e:
            print(f"[RouteFeatureEngine] Polyline decode error: {e}")
            return []

    def stratified_sample_route(self, decoded_points: List[Tuple[float, float]]) -> List[Tuple[float, float]]:
        """
        Sample route at percentage intervals: 0%, 25%, 50%, 75%, 100%.
        Avoids origin-only bias and ensures full route representation.
        """
        if not decoded_points:
            return []
        if len(decoded_points) <= 5:
            return decoded_points

        percentages = [0.0, 0.25, 0.5, 0.75, 1.0]
        sampled = []
        for pct in percentages:
            idx = int(pct * (len(decoded_points) - 1))
            sampled.append(decoded_points[idx])
        return sampled

    def sample_route_points(
        self, decoded_points: List[Tuple[float, float]], sample_distance: int = ROUTE_SAMPLE_DISTANCE
    ) -> List[Tuple[float, float]]:
        """
        Legacy fallback: sample every Nth point.
        Prefer stratified_sample_route for new code.
        """
        if not decoded_points:
            return []
        sampled = [decoded_points[i] for i in range(0, len(decoded_points), sample_distance)]
        if decoded_points[-1] not in sampled:
            sampled.append(decoded_points[-1])
        return sampled

    def nearby_places(self, lat: float, lon: float, is_unique_cell: bool = False) -> List[Dict]:
        """
        Query Google Places API with grid caching.
        is_unique_cell=True prioritizes scanning (can use smaller radius or higher priority).
        """
        if not self.api_key:
            return []

        if self._places_consecutive_failures >= self._places_max_failures:
            return []

        cached = self.grid_cache.get(lat, lon)
        if cached is not None:
            return cached

        # Adaptive radius: unique cells get full scan, shared cells get reduced scan
        radius = PLACES_RADIUS if is_unique_cell else max(100, PLACES_RADIUS // 2)

        params = {
            "location": f"{lat},{lon}",
            "radius": radius,
            "key": self.api_key,
        }

        try:
            response = requests.get(self.places_url, params=params, timeout=3)
            response.raise_for_status()
            data = response.json()

            results = data.get("results", [])
            extracted = [
                {
                    "name": r.get("name"),
                    "types": r.get("types", []),
                    "lat": r.get("geometry", {}).get("location", {}).get("lat"),
                    "lon": r.get("geometry", {}).get("location", {}).get("lng"),
                }
                for r in results
            ]

            self.grid_cache.set(lat, lon, extracted)
            self._places_consecutive_failures = 0
            time.sleep(REQUEST_DELAY)
            return extracted

        except requests.exceptions.RequestException as e:
            self._places_consecutive_failures += 1
            print(f"[RouteFeatureEngine] Places API error ({self._places_consecutive_failures}/{self._places_max_failures}): {e}")
            return []

    def aggregate_poi_features(
        self, all_places: List[Dict], weights: Optional[Dict[str, float]] = None
    ) -> Dict[str, int]:
        """
        Aggregate POI counts from places data.
        weights: optional dict mapping place names to weights (for unique corridor weighting).
        """
        features = defaultdict(float)
        unique_places = set()

        for place in all_places:
            name = place.get("name")
            if name in unique_places:
                continue
            unique_places.add(name)

            weight = weights.get(name, 1.0) if weights else 1.0
            types = place.get("types", [])
            for t in types:
                if t in TARGET_TYPES:
                    features[TARGET_TYPES[t]] += weight

        # Convert to int, rounding weighted counts
        return {k: int(round(v)) for k, v in features.items()}

    def compute_activity_scores(self, poi_counts: Dict[str, int]) -> Dict[str, float]:
        """Compute engineered activity scores from POI counts."""
        commercial = (
            poi_counts.get("restaurant_count", 0)
            + poi_counts.get("cafe_count", 0)
            + poi_counts.get("shopping_mall_count", 0)
            + poi_counts.get("supermarket_count", 0)
        )

        emergency = poi_counts.get("hospital_count", 0) + poi_counts.get("police_count", 0)
        transport = poi_counts.get("bus_station_count", 0) + poi_counts.get("train_station_count", 0)
        isolation = max(0, 100 - (2 * commercial + 1.5 * transport + 2 * emergency))

        return {
            "commercial_activity_score": commercial,
            "emergency_presence_score": emergency,
            "transport_activity_score": transport,
            "isolation_score": isolation,
        }

    def extract_route_features(
        self,
        route: Dict,
        origin: Tuple[float, float],
        destination: Tuple[float, float],
        route_corridor: Optional[Set[Tuple[int, int]]] = None,
        other_corridors: Optional[List[Set[Tuple[int, int]]]] = None,
    ) -> Tuple[Dict, Dict]:
        """
        Extract complete feature set for a route.
        
        Returns:
            (features_dict, diagnostics_dict)
            - features_dict: 22-feature schema for XGBoost (unchanged)
            - diagnostics_dict: corridor metrics (metadata only)
        """
        distance_m = route.get("distanceMeters", 0)
        duration = route.get("duration", "0s")
        eta_sec = int(duration.rstrip("s")) if duration.endswith("s") else 0

        encoded_polyline = route.get("polyline", {}).get("encodedPolyline", "")
        decoded_points = self.decode_polyline(encoded_polyline) if encoded_polyline else []

        # Use stratified sampling for better route representation
        sampled_points = self.stratified_sample_route(decoded_points)

        # Compute corridor if not provided (for backward compatibility)
        if route_corridor is None:
            route_corridor = self.corridor_engine.polyline_to_corridor(decoded_points)
        if other_corridors is None:
            other_corridors = []

        # Extract unique and shared cells
        unique_cells = self.corridor_engine.unique_cells(route_corridor, other_corridors)
        shared_cells = self.corridor_engine.shared_cells(route_corridor, other_corridors)

        # Scan unique cells preferentially, shared cells with lower priority
        all_places = []
        scanned_cells = set()
        scan_diversity_count = 0

        for lat, lon in sampled_points:
            cell_id = self.corridor_engine._grid_id(lat, lon)
            if cell_id in scanned_cells:
                continue
            scanned_cells.add(cell_id)

            is_unique = cell_id in unique_cells
            places = self.nearby_places(lat, lon, is_unique_cell=is_unique)
            all_places.extend(places)
            if places:
                scan_diversity_count += 1

        # Aggregate POIs with uniqueness weighting
        place_weights = {}
        for place in all_places:
            name = place.get("name")
            if name:
                # Unique cells get weight 1.0, shared cells get 0.6
                cell_id = self.corridor_engine._grid_id(place.get("lat", 0), place.get("lon", 0))
                place_weights[name] = 1.0 if cell_id in unique_cells else 0.6

        poi_counts = self.aggregate_poi_features(all_places, weights=place_weights)
        activity_scores = self.compute_activity_scores(poi_counts)

        # Build 22-feature schema (unchanged for XGBoost compatibility)
        features = {
            "route_distance_m": distance_m,
            "route_eta_sec": eta_sec,
            **poi_counts,
            **activity_scores,
        }

        for key in TARGET_TYPES.values():
            features.setdefault(key, 0)

        # Compute corridor diagnostics (metadata only, not in ML vector)
        corridor_overlap_score = 0.0
        unique_corridor_ratio = 0.0
        if route_corridor:
            if other_corridors:
                # Average Jaccard similarity with other routes
                overlaps = [self.corridor_engine.jaccard_similarity(route_corridor, other) for other in other_corridors]
                corridor_overlap_score = float(np.mean(overlaps)) if overlaps else 0.0
            unique_corridor_ratio = len(unique_cells) / len(route_corridor) if route_corridor else 0.0

        scan_diversity_score = scan_diversity_count / len(sampled_points) if sampled_points else 0.0
        route_geographic_uniqueness_score = (unique_corridor_ratio * 0.5) + (1.0 - corridor_overlap_score) * 0.5

        diagnostics = {
            "corridor_overlap_score": round(corridor_overlap_score, 4),
            "unique_corridor_ratio": round(unique_corridor_ratio, 4),
            "scan_diversity_score": round(scan_diversity_score, 4),
            "route_geographic_uniqueness_score": round(route_geographic_uniqueness_score, 4),
        }

        return features, diagnostics

    def extract_batch_routes(
        self,
        routes: List[Dict],
        origin: Tuple[float, float],
        destination: Tuple[float, float],
    ) -> List[Tuple[Dict, Dict]]:
        """
        Extract features for all routes with cross-route corridor awareness.
        
        Returns:
            List of (features_dict, diagnostics_dict) tuples
        """
        # Build corridors for all routes
        corridors = []
        for route in routes:
            encoded = route.get("polyline", {}).get("encodedPolyline", "")
            decoded = self.decode_polyline(encoded)
            corridor = self.corridor_engine.polyline_to_corridor(decoded)
            corridors.append(corridor)

        # Extract features with cross-route awareness
        results = []
        for i, route in enumerate(routes):
            other_corridors = corridors[:i] + corridors[i+1:]
            features, diagnostics = self.extract_route_features(
                route=route,
                origin=origin,
                destination=destination,
                route_corridor=corridors[i],
                other_corridors=other_corridors,
            )
            results.append((features, diagnostics))

        return results
