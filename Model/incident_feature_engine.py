"""
INCIDENT FEATURE ENGINE
=======================
Transforms raw incident data into route-level safety features.
Analyzes crime patterns along route corridors to identify high-risk zones and compute
incident-based risk metrics that feed into the primary safety model.

Features computed:
- incident_density: Normalized incident count per km of route
- redzone_overlap_score: Proportion of route passing through high-crime cells
- temporal_risk_score: Time-decay weighted severity of incidents
- avg_incident_severity: Mean severity of matched incidents
- incident_count: Total incidents detected within route corridor
"""

import math
from typing import Dict, List, Optional, Sequence, Set, Tuple
from datetime import datetime

import numpy as np

from incident_intelligence import IncidentIntelligenceClient, IncidentRecord


Coordinate = Tuple[float, float]


class IncidentRouteFeatures:
    """Computed incident-based features for a single route."""
    
    def __init__(
        self,
        incident_density: float,
        redzone_overlap_score: float,
        temporal_risk_score: float,
        avg_incident_severity: float,
        incident_count: int,
        max_csi: float,
        avg_csi: float,
        query_points: int,
    ):
        self.incident_density = incident_density
        self.redzone_overlap_score = redzone_overlap_score
        self.temporal_risk_score = temporal_risk_score
        self.avg_incident_severity = avg_incident_severity
        self.incident_count = incident_count
        self.max_csi = max_csi
        self.avg_csi = avg_csi
        self.query_points = query_points

    def as_model_features(self) -> Dict[str, float]:
        """Export as features for ML model consumption."""
        return {
            "incident_density": self.incident_density,
            "redzone_overlap_score": self.redzone_overlap_score,
            "temporal_risk_score": self.temporal_risk_score,
            "avg_incident_severity": self.avg_incident_severity,
        }
    
    def to_dict(self) -> Dict[str, float]:
        """Export all features as dictionary for API response."""
        return {
            "incident_density": self.incident_density,
            "redzone_overlap_score": self.redzone_overlap_score,
            "temporal_risk_score": self.temporal_risk_score,
            "avg_incident_severity": self.avg_incident_severity,
            "incident_count": self.incident_count,
            "max_csi": self.max_csi,
            "avg_csi": self.avg_csi,
        }


class IncidentFeatureEngine:
    """Computes incident-based route safety features."""
    
    # Configuration
    grid_cell_size = 0.005  # ~500m at equator
    earth_radius_m = 6_371_000
    temporal_decay_lambda = 0.08
    incident_match_radius_m = 250.0
    high_risk_csi_threshold = 60.0
    high_risk_cell_severity_threshold = 3.5

    def __init__(self, client: Optional[IncidentIntelligenceClient] = None):
        self.client = client or IncidentIntelligenceClient()

    def score_route(
        self,
        route_points: Sequence[Coordinate],
        route_distance_m: float,
        trip_time: Optional[datetime] = None,
        max_query_points: int = 8,
    ) -> IncidentRouteFeatures:
        """Score a route based on incident data."""
        try:
            as_of = trip_time or datetime.utcnow()
            query_points = self._query_points(route_points, max_query_points)

            incidents = self._load_incidents(query_points, as_of)
            stats = self._load_stats(query_points, as_of)
            matched_incidents = self._matched_route_incidents(route_points, incidents)
            hot_cells = self._hot_cells(matched_incidents, stats, as_of)

            route_km = max(route_distance_m / 1000.0, 0.001)
            csi_values = [
                float(item.get("csi", 0.0) or 0.0)
                for item in stats
                if isinstance(item, dict)
            ]

            return IncidentRouteFeatures(
                incident_density=len(matched_incidents) / route_km,
                redzone_overlap_score=self._redzone_overlap(route_points, hot_cells),
                temporal_risk_score=self._temporal_risk(matched_incidents, as_of),
                avg_incident_severity=float(np.mean([item.severity for item in matched_incidents]))
                if matched_incidents
                else 0.0,
                incident_count=len(matched_incidents),
                max_csi=max(csi_values) if csi_values else 0.0,
                avg_csi=float(np.mean(csi_values)) if csi_values else 0.0,
                query_points=len(query_points),
            )
        except Exception as e:
            # Graceful failure: return zero-valued features if anything fails
            import logging
            logging.warning(f"[IncidentFeatureEngine] score_route failed: {e}")
            return IncidentRouteFeatures(
                incident_density=0.0,
                redzone_overlap_score=0.0,
                temporal_risk_score=0.0,
                avg_incident_severity=0.0,
                incident_count=0,
                max_csi=0.0,
                avg_csi=0.0,
                query_points=0,
            )

    def _load_incidents(
        self,
        query_points: Sequence[Coordinate],
        as_of: datetime,
    ) -> List[IncidentRecord]:
        incidents: List[IncidentRecord] = []
        seen: Set[Tuple[str, float, float, float]] = set()

        for latitude, longitude in query_points:
            for incident in self.client.fetch_incidents(latitude, longitude, as_of):
                key = (
                    incident.incident_id or incident.offense,
                    round(incident.latitude, 6),
                    round(incident.longitude, 6),
                    round(incident.timestamp, 0),
                )
                if key in seen:
                    continue
                seen.add(key)
                incidents.append(incident)

        return incidents

    def _load_stats(
        self,
        query_points: Sequence[Coordinate],
        as_of: datetime,
    ) -> List[Dict]:
        stats = []
        for latitude, longitude in query_points:
            payload = self.client.fetch_stats(latitude, longitude, as_of)
            if payload:
                stats.append(
                    {
                        **payload,
                        "_cell_id": self._cell_id(latitude, longitude),
                    }
                )
        return stats

    def _matched_route_incidents(
        self,
        route_points: Sequence[Coordinate],
        incidents: Sequence[IncidentRecord],
    ) -> List[IncidentRecord]:
        matched = []
        for incident in incidents:
            if any(
                self._distance_m(latitude, longitude, incident.latitude, incident.longitude)
                <= self.incident_match_radius_m
                for latitude, longitude in route_points
            ):
                matched.append(incident)
        return matched

    def _hot_cells(
        self,
        incidents: Sequence[IncidentRecord],
        stats: Sequence[Dict],
        as_of: datetime,
    ) -> Set[str]:
        hot_cells: Set[str] = set()
        incidents_by_cell: Dict[str, List[IncidentRecord]] = {}

        for incident in incidents:
            cell_id = self._cell_id(incident.latitude, incident.longitude)
            incidents_by_cell.setdefault(cell_id, []).append(incident)

        for cell_id, cell_incidents in incidents_by_cell.items():
            mean_severity = float(np.mean([incident.severity for incident in cell_incidents]))
            recency_score = float(
                np.mean(
                    [
                        incident.severity
                        * math.exp(
                            -self.temporal_decay_lambda
                            * max(0.0, (as_of.timestamp() - incident.timestamp) / 3600.0)
                        )
                        for incident in cell_incidents
                    ]
                )
            )
            if (
                mean_severity >= self.high_risk_cell_severity_threshold
                or recency_score >= self.high_risk_cell_severity_threshold
            ):
                hot_cells.add(cell_id)

        for item in stats:
            if float(item.get("csi", 0.0) or 0.0) >= self.high_risk_csi_threshold:
                hot_cells.add(str(item.get("_cell_id")))

        return hot_cells

    def _redzone_overlap(
        self,
        route_points: Sequence[Coordinate],
        hot_cells: Set[str],
    ) -> float:
        if not route_points:
            return 0.0
        overlap_points = sum(
            1 for latitude, longitude in route_points if self._cell_id(latitude, longitude) in hot_cells
        )
        return overlap_points / len(route_points)

    def _temporal_risk(
        self,
        incidents: Sequence[IncidentRecord],
        as_of: datetime,
    ) -> float:
        return float(
            sum(
                incident.severity
                * math.exp(
                    -self.temporal_decay_lambda
                    * max(0.0, (as_of.timestamp() - incident.timestamp) / 3600.0)
                )
                for incident in incidents
            )
        )

    def _query_points(
        self,
        route_points: Sequence[Coordinate],
        max_points: int,
    ) -> List[Coordinate]:
        unique_by_cell: Dict[str, Coordinate] = {}
        for latitude, longitude in route_points:
            unique_by_cell.setdefault(self._cell_id(latitude, longitude), (latitude, longitude))

        points = list(unique_by_cell.values())
        if len(points) <= max_points:
            return points

        step = (len(points) - 1) / max(1, max_points - 1)
        return [points[round(index * step)] for index in range(max_points)]

    def _cell_id(self, latitude: float, longitude: float) -> str:
        return f"{int(latitude / self.grid_cell_size)}:{int(longitude / self.grid_cell_size)}"

    def _distance_m(
        self,
        lat1: float,
        lon1: float,
        lat2: float,
        lon2: float,
    ) -> float:
        lat1_rad = math.radians(lat1)
        lat2_rad = math.radians(lat2)
        delta_lat = math.radians(lat2 - lat1)
        delta_lon = math.radians(lon2 - lon1)

        hav = (
            math.sin(delta_lat / 2) ** 2
            + math.cos(lat1_rad) * math.cos(lat2_rad) * math.sin(delta_lon / 2) ** 2
        )
        return self.earth_radius_m * 2 * math.asin(math.sqrt(hav))
