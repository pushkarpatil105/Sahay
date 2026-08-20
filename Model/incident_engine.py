"""
Incident Engine - Incident Intelligence & Red Zone Management
Computes incident-based risk features for route safety assessment.
"""

import math
import logging
from collections import defaultdict
from typing import Dict, List, Tuple, Optional, Set
from datetime import datetime

import numpy as np

logger = logging.getLogger(__name__)

# ============================================================
# CONFIGURATION
# ============================================================

TEMPORAL_DECAY_LAMBDA = 0.08
EARTH_RADIUS_M = 6371000
GRID_CELL_SIZE = 0.005  # roughly 500m at the equator
ROUTE_QUERY_BUFFER_M = 250.0
MAX_ARRAY_CONTAINS_ANY = 10
REDZONE_DENSITY_THRESHOLD = 2.0


# ============================================================
# DATA STRUCTURES
# ============================================================

class RedZone:
    """Represents a high-risk geographic zone."""

    def __init__(self, lat: float, lon: float, radius_m: float, risk: float):
        self.lat = lat
        self.lon = lon
        self.radius_m = radius_m
        self.risk = risk

    def contains_point(self, lat: float, lon: float) -> bool:
        """Check if point is within red zone."""
        distance = haversine(self.lat, self.lon, lat, lon)
        return distance <= self.radius_m


class Incident:
    """Represents a safety incident."""

    def __init__(self, lat: float, lon: float, severity: float, timestamp: float):
        self.lat = lat
        self.lon = lon
        self.severity = severity
        self.timestamp = timestamp


# ============================================================
# DISTANCE CALCULATION
# ============================================================

def haversine(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Calculate haversine distance in meters."""
    lat1_rad = math.radians(lat1)
    lat2_rad = math.radians(lat2)
    delta_lat = math.radians(lat2 - lat1)
    delta_lon = math.radians(lon2 - lon1)

    a = math.sin(delta_lat / 2) ** 2 + math.cos(lat1_rad) * math.cos(lat2_rad) * math.sin(delta_lon / 2) ** 2
    c = 2 * math.asin(math.sqrt(a))
    return EARTH_RADIUS_M * c


# ============================================================
# INCIDENT ENGINE
# ============================================================

class IncidentEngine:
    """Manages incident database and computes incident-based risk features.

    If a Firestore client is provided, the engine will attempt to load
    recent incidents and sos events from the `unsafe_reports` and
    `sos_events` collections.
    """

    _FIRESTORE_TTL_SECONDS = 300

    def __init__(self, firestore_client: Optional[object] = None):
        self.red_zones: List[RedZone] = []
        self.incidents: List[Incident] = []
        self.firestore_client = firestore_client
        self._firestore_loaded = False
        self._firestore_loaded_at: float = 0.0

    def _grid_id(self, lat: float, lon: float) -> Tuple[int, int]:
        return (int(lat / GRID_CELL_SIZE), int(lon / GRID_CELL_SIZE))

    def _route_bounds(
        self, sampled_points: List[Tuple[float, float]], buffer_m: float = ROUTE_QUERY_BUFFER_M
    ) -> Optional[Tuple[float, float, float, float]]:
        if not sampled_points:
            return None

        lats = [lat for lat, _ in sampled_points]
        lons = [lon for _, lon in sampled_points]
        mean_lat = sum(lats) / len(lats)
        lat_buffer = buffer_m / 111_320.0
        lon_buffer = buffer_m / max(1.0, 111_320.0 * math.cos(math.radians(mean_lat)))

        return (
            min(lats) - lat_buffer,
            max(lats) + lat_buffer,
            min(lons) - lon_buffer,
            max(lons) + lon_buffer,
        )

    def _route_cells(self, sampled_points: List[Tuple[float, float]]) -> Set[str]:
        return {f"{self._grid_id(lat, lon)[0]}:{self._grid_id(lat, lon)[1]}" for lat, lon in sampled_points}

    def _chunked(self, values: List[str], size: int) -> List[List[str]]:
        return [values[index:index + size] for index in range(0, len(values), size)]

    def _extract_location(self, data: Dict) -> Optional[Tuple[float, float]]:
        if "lat" in data and "lng" in data:
            try:
                return float(data["lat"]), float(data["lng"])
            except Exception:
                return None

        location = data.get("location")
        if location is None:
            return None

        if hasattr(location, "latitude") and hasattr(location, "longitude"):
            try:
                return float(location.latitude), float(location.longitude)
            except Exception:
                return None

        if isinstance(location, dict):
            lat = location.get("lat") or location.get("latitude")
            lon = location.get("lng") or location.get("longitude")
            if lat is None or lon is None:
                return None
            try:
                return float(lat), float(lon)
            except Exception:
                return None

        return None

    def _query_documents_by_cells(
        self,
        client,
        collection_name: str,
        sampled_points: List[Tuple[float, float]],
        cell_field: str,
        status_field: Optional[str] = None,
        status_value: Optional[object] = None,
    ) -> List[Dict]:
        route_cells = list(self._route_cells(sampled_points))
        if not route_cells:
            return []

        results: List[Dict] = []
        seen_ids: Set[str] = set()
        collection = client.collection(collection_name)

        for cell_chunk in self._chunked(route_cells, MAX_ARRAY_CONTAINS_ANY):
            try:
                query = collection.where(cell_field, "array_contains_any", cell_chunk)
                if status_field is not None and status_value is not None:
                    query = query.where(status_field, "==", status_value)

                for doc in query.stream():
                    if doc.id in seen_ids:
                        continue
                    seen_ids.add(doc.id)
                    data = doc.to_dict() or {}
                    data["_doc_id"] = doc.id
                    results.append(data)
            except Exception:
                continue

        return results

    def _query_documents_by_bounds(
        self,
        client,
        collection_name: str,
        sampled_points: List[Tuple[float, float]],
        lat_field: str,
        lon_field: str,
        status_field: Optional[str] = None,
        status_value: Optional[object] = None,
    ) -> List[Dict]:
        bounds = self._route_bounds(sampled_points)
        if bounds is None:
            return []

        min_lat, max_lat, min_lon, max_lon = bounds
        results: List[Dict] = []
        seen_ids: Set[str] = set()

        try:
            query = client.collection(collection_name)
            if status_field is not None and status_value is not None:
                query = query.where(status_field, "==", status_value)
            query = query.where(lat_field, ">=", min_lat).where(lat_field, "<=", max_lat)

            for doc in query.stream():
                if doc.id in seen_ids:
                    continue
                data = doc.to_dict() or {}
                location = self._extract_location(data)
                if not location:
                    continue

                lat, lon = location
                if min_lon <= lon <= max_lon:
                    seen_ids.add(doc.id)
                    data["_doc_id"] = doc.id
                    results.append(data)
        except Exception:
            return []

        return results

    def _load_route_local_incidents(self, sampled_points: List[Tuple[float, float]]) -> List[Incident]:
        if self.firestore_client is None:
            return []

        candidates: List[Dict] = []

        try:
            candidates.extend(
                self._query_documents_by_cells(
                    self.firestore_client,
                    "unsafe_reports",
                    sampled_points,
                    cell_field="cell_ids",
                    status_field="active",
                    status_value=True,
                )
            )
        except Exception:
            pass

        if not candidates:
            try:
                candidates.extend(
                    self._query_documents_by_bounds(
                        self.firestore_client,
                        "unsafe_reports",
                        sampled_points,
                        lat_field="lat",
                        lon_field="lng",
                        status_field="active",
                        status_value=True,
                    )
                )
            except Exception:
                pass

        try:
            candidates.extend(
                self._query_documents_by_bounds(
                    self.firestore_client,
                    "sos_events",
                    sampled_points,
                    lat_field="lat",
                    lon_field="lng",
                    status_field="status",
                    status_value="active",
                )
            )
        except Exception:
            pass

        incidents: List[Incident] = []
        seen_keys: Set[Tuple[float, float, float, float]] = set()

        for data in candidates:
            location = self._extract_location(data)
            if not location:
                continue

            lat, lon = location
            severity = data.get("severity")
            if severity is None:
                upvotes = float(data.get("upvotes", 0))
                severity = min(5.0, 1.0 + upvotes / 5.0)

            ts = data.get("timestamp")
            if hasattr(ts, "timestamp"):
                timestamp = float(ts.timestamp())
            elif isinstance(ts, (int, float)):
                timestamp = float(ts)
            else:
                timestamp = float(datetime.utcnow().timestamp())

            key = (round(lat, 6), round(lon, 6), round(float(severity), 3), round(timestamp, 0))
            if key in seen_keys:
                continue
            seen_keys.add(key)
            incidents.append(Incident(lat, lon, float(severity), timestamp))

        return incidents

    def _load_route_local_red_zones(self, sampled_points: List[Tuple[float, float]]) -> List[RedZone]:
        if self.firestore_client is None:
            return []

        red_zones: List[RedZone] = []

        try:
            docs = self._query_documents_by_cells(
                self.firestore_client,
                "redzones",
                sampled_points,
                cell_field="cell_ids",
                status_field="active",
                status_value=True,
            )
            if not docs:
                docs = self._query_documents_by_bounds(
                    self.firestore_client,
                    "redzones",
                    sampled_points,
                    lat_field="lat",
                    lon_field="lng",
                    status_field="active",
                    status_value=True,
                )

            for data in docs:
                location = self._extract_location(data)
                if not location:
                    continue
                lat, lon = location
                radius_m = float(data.get("radius_m", data.get("radius", 200.0)))
                risk = float(data.get("risk", data.get("risk_score", 1.0)))
                red_zones.append(RedZone(lat, lon, radius_m, risk))
        except Exception:
            return []

        return red_zones

    def add_red_zone(self, lat: float, lon: float, radius_m: float, risk: float) -> None:
        """Add a red zone to the database."""
        self.red_zones.append(RedZone(lat, lon, radius_m, risk))

    def add_incident(self, lat: float, lon: float, severity: float, timestamp: float) -> None:
        """Add an incident to the database."""
        self.incidents.append(Incident(lat, lon, severity, timestamp))

    def clear_incidents(self) -> None:
        """Clear all incidents."""
        self.incidents.clear()

    def clear_red_zones(self) -> None:
        """Clear all red zones."""
        self.red_zones.clear()

    def compute_redzone_overlap(
        self,
        sampled_points: List[Tuple[float, float]],
        red_zones: Optional[List[RedZone]] = None,
        hot_cells: Optional[Set[str]] = None,
    ) -> float:
        """Compute fraction of route points overlapping with red zones."""
        if not sampled_points:
            return 0.0

        if hot_cells is not None:
            overlap_count = sum(
                1 for lat, lon in sampled_points if f"{self._grid_id(lat, lon)[0]}:{self._grid_id(lat, lon)[1]}" in hot_cells
            )
            return overlap_count / len(sampled_points)

        red_zone_list = red_zones if red_zones is not None else self.red_zones

        overlap_count = sum(
            1 for lat, lon in sampled_points if any(rz.contains_point(lat, lon) for rz in red_zone_list)
        )

        return overlap_count / len(sampled_points)

    def _nearby_incidents(
        self,
        lat: float,
        lon: float,
        incidents: Optional[List[Incident]] = None,
        radius_m: float = 200,
    ) -> List["Incident"]:
        """Return incidents within radius_m of a point."""
        incident_list = incidents if incidents is not None else self.incidents
        return [
            inc for inc in incident_list
            if haversine(lat, lon, inc.lat, inc.lon) <= radius_m
        ]

    def compute_incident_density(
        self,
        sampled_points: List[Tuple[float, float]],
        route_distance_m: float,
        incidents: Optional[List[Incident]] = None,
    ) -> float:
        """Compute incident density (incidents per km) using 200m radius."""
        if route_distance_m == 0:
            return 0.0
        route_km = route_distance_m / 1000.0
        incident_list = incidents if incidents is not None else self.incidents
        matched_keys: Set[Tuple[float, float, float, float]] = set()

        for lat, lon in sampled_points:
            for inc in self._nearby_incidents(lat, lon, incident_list):
                key = (
                    round(inc.lat, 6),
                    round(inc.lon, 6),
                    round(inc.severity, 3),
                    round(inc.timestamp, 0),
                )
                matched_keys.add(key)

        incident_count = len(matched_keys)
        return incident_count / route_km

    def compute_avg_incident_severity(
        self,
        sampled_points: List[Tuple[float, float]],
        incidents: Optional[List[Incident]] = None,
    ) -> float:
        """Compute average severity of nearby incidents using 200m radius."""
        incident_list = incidents if incidents is not None else self.incidents
        nearby_severities = []
        seen_keys: Set[Tuple[float, float, float, float]] = set()

        for lat, lon in sampled_points:
            for inc in self._nearby_incidents(lat, lon, incident_list):
                key = (
                    round(inc.lat, 6),
                    round(inc.lon, 6),
                    round(inc.severity, 3),
                    round(inc.timestamp, 0),
                )
                if key in seen_keys:
                    continue
                seen_keys.add(key)
                nearby_severities.append(inc.severity)

        return float(np.mean(nearby_severities)) if nearby_severities else 0.0

    def compute_temporal_risk_score(
        self,
        sampled_points: List[Tuple[float, float]],
        current_time: float,
        incidents: Optional[List[Incident]] = None,
    ) -> float:
        """Compute temporal risk score with exponential decay using 200m radius."""
        temporal_risk = 0.0
        incident_list = incidents if incidents is not None else self.incidents
        seen_keys: Set[Tuple[float, float, float, float]] = set()

        for lat, lon in sampled_points:
            for inc in self._nearby_incidents(lat, lon, incident_list):
                key = (
                    round(inc.lat, 6),
                    round(inc.lon, 6),
                    round(inc.severity, 3),
                    round(inc.timestamp, 0),
                )
                if key in seen_keys:
                    continue
                seen_keys.add(key)
                hours_old = max(0.0, (current_time - inc.timestamp) / 3600.0)
                temporal_risk += inc.severity * np.exp(-TEMPORAL_DECAY_LAMBDA * hours_old)
        return temporal_risk

    def _load_from_firestore(self, client) -> None:
        """Load incidents and sos events from Firestore into the in-memory lists.

        This is intentionally tolerant of missing fields and different document
        shapes — it will skip documents that cannot be parsed.
        """
        try:
            # Load unsafe_reports where active == True
            reports_ref = client.collection("unsafe_reports").where("active", "==", True)
            for doc in reports_ref.stream():
                data = doc.to_dict()
                try:
                    lat = float(data.get("lat"))
                    lon = float(data.get("lng"))
                    # Derive severity from upvotes if available, otherwise default 1.0
                    upvotes = float(data.get("upvotes", 0))
                    severity = min(5.0, 1.0 + upvotes / 5.0)
                    ts = data.get("timestamp")
                    if hasattr(ts, "timestamp"):
                        timestamp = float(ts.timestamp())
                    elif isinstance(ts, (int, float)):
                        timestamp = float(ts)
                    else:
                        timestamp = float(datetime.utcnow().timestamp())

                    self.add_incident(lat, lon, severity, timestamp)
                except Exception:
                    continue

            # Load sos_events where status == 'active' and location exists
            sos_ref = client.collection("sos_events").where("status", "==", "active")
            for doc in sos_ref.stream():
                data = doc.to_dict()
                try:
                    loc = data.get("location")
                    if not loc:
                        continue
                    # Firestore GeoPoint has latitude/longitude attributes
                    lat = float(getattr(loc, "latitude", None) or loc.get("lat") or loc.get("latitude"))
                    lon = float(getattr(loc, "longitude", None) or loc.get("lng") or loc.get("longitude"))
                    severity = 2.0
                    ts = data.get("timestamp")
                    if hasattr(ts, "timestamp"):
                        timestamp = float(ts.timestamp())
                    elif isinstance(ts, (int, float)):
                        timestamp = float(ts)
                    else:
                        timestamp = float(datetime.utcnow().timestamp())

                    self.add_incident(lat, lon, severity, timestamp)
                except Exception:
                    continue

        except Exception as e:
            logger.error(f"Error querying Firestore for incidents: {e}")

    def compute_incident_features(
        self,
        sampled_points: List[Tuple[float, float]],
        route_distance_m: float,
        current_time: float,
    ) -> Dict[str, float]:
        """Compute all incident-based features."""
        route_local_incidents: List[Incident] = []
        route_local_red_zones: List[RedZone] = []

        if self.firestore_client is not None:
            try:
                route_local_incidents = self._load_route_local_incidents(sampled_points)
                route_local_red_zones = self._load_route_local_red_zones(sampled_points)
                logger.info(
                    "IncidentEngine: loaded %s incidents and %s red zones for current route",
                    len(route_local_incidents),
                    len(route_local_red_zones),
                )
            except Exception as e:
                logger.error(f"IncidentEngine: route-local Firestore lookup failed: {e}")

        if not route_local_incidents and self.incidents:
            route_local_incidents = self.incidents
        if not route_local_red_zones and self.red_zones:
            route_local_red_zones = self.red_zones

        hot_cells: Optional[Set[str]] = None
        if route_local_incidents:
            incident_cells = defaultdict(list)
            for inc in route_local_incidents:
                cell_id = f"{self._grid_id(inc.lat, inc.lon)[0]}:{self._grid_id(inc.lat, inc.lon)[1]}"
                incident_cells[cell_id].append(inc)

            hot_cells = set()
            for cell_id, incidents_for_cell in incident_cells.items():
                if not incidents_for_cell:
                    continue
                mean_severity = float(np.mean([inc.severity for inc in incidents_for_cell]))
                recency_boost = float(
                    np.mean([
                        inc.severity * np.exp(-TEMPORAL_DECAY_LAMBDA * max(0.0, (current_time - inc.timestamp) / 3600.0))
                        for inc in incidents_for_cell
                    ])
                )
                if mean_severity >= REDZONE_DENSITY_THRESHOLD or recency_boost >= REDZONE_DENSITY_THRESHOLD:
                    hot_cells.add(cell_id)

            if route_local_red_zones:
                for red_zone in route_local_red_zones:
                    hot_cells.add(f"{self._grid_id(red_zone.lat, red_zone.lon)[0]}:{self._grid_id(red_zone.lat, red_zone.lon)[1]}")

            if not hot_cells:
                hot_cells = None

        return {
            "redzone_overlap_score": self.compute_redzone_overlap(
                sampled_points,
                red_zones=route_local_red_zones,
                hot_cells=hot_cells,
            ),
            "incident_density": self.compute_incident_density(
                sampled_points,
                route_distance_m,
                incidents=route_local_incidents,
            ),
            "avg_incident_severity": self.compute_avg_incident_severity(
                sampled_points,
                incidents=route_local_incidents,
            ),
            "temporal_risk_score": self.compute_temporal_risk_score(
                sampled_points,
                current_time,
                incidents=route_local_incidents,
            ),
        }
