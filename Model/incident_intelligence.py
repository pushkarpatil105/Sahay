"""
INCIDENT INTELLIGENCE MODULE
============================
Integrates Crimeometer incident data and statistics into route safety scoring.
Provides real-time crime incident analysis, severity assessment, and high-risk zone detection.

This module complements the primary XGBoost safety model by enriching route features
with live crime data, enabling context-aware risk scoring.

Usage:
    From backend.py or route feature engines:
    - from incident_intelligence import IncidentIntelligence
    - intelligence = IncidentIntelligence()
    - features = intelligence.score_route(route_points, route_distance_m, trip_time)
"""

import os
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional, Tuple

import requests


@dataclass(frozen=True)
class IncidentConfig:
    """Configuration for Crimeometer API integration."""
    api_key: str
    base_url: str = "https://api.crimeometer.com/v2"
    distance: str = "0.25mi"
    lookback_days: int = 365
    timeout_seconds: int = 8
    max_pages: int = 3

    @classmethod
    def from_environment(cls) -> "IncidentConfig":
        return cls(
            api_key=os.getenv("CRIMEOMETER_API_KEY", ""),
            base_url=os.getenv("CRIMEOMETER_API_BASE_URL", cls.base_url).rstrip("/"),
            distance=os.getenv("CRIMEOMETER_DISTANCE", cls.distance),
            lookback_days=int(os.getenv("CRIMEOMETER_LOOKBACK_DAYS", str(cls.lookback_days))),
            timeout_seconds=int(os.getenv("CRIMEOMETER_TIMEOUT_SECONDS", str(cls.timeout_seconds))),
            max_pages=int(os.getenv("CRIMEOMETER_MAX_PAGES", str(cls.max_pages))),
        )


@dataclass(frozen=True)
class IncidentRecord:
    """Represents a single crime incident with parsed metadata."""
    incident_id: str
    latitude: float
    longitude: float
    timestamp: float
    offense: str
    crime_against: str
    severity: float
    raw: Dict[str, Any]


class IncidentIntelligenceClient:
    """Client for fetching and caching incident data from Crimeometer API."""
    
    def __init__(self, config: Optional[IncidentConfig] = None):
        self.config = config or IncidentConfig.from_environment()
        self._incident_cache: Dict[Tuple[float, float, str, str, str], List[IncidentRecord]] = {}
        self._stats_cache: Dict[Tuple[float, float, str, str, str], Dict[str, Any]] = {}

    @property
    def is_configured(self) -> bool:
        return bool(self.config.api_key)

    def _headers(self) -> Dict[str, str]:
        return {
            "Accept": "application/json",
            "Content-Type": "application/json",
            "x-api-key": self.config.api_key,
        }

    def _date_window(self, as_of: datetime) -> Tuple[str, str]:
        start = as_of - timedelta(days=self.config.lookback_days)
        return (
            start.strftime("%Y-%m-%d %H:%M:%S"),
            as_of.strftime("%Y-%m-%d %H:%M:%S"),
        )

    def _cache_key(
        self,
        latitude: float,
        longitude: float,
        datetime_ini: str,
        datetime_end: str,
    ) -> Tuple[float, float, str, str, str]:
        return (
            round(latitude, 4),
            round(longitude, 4),
            datetime_ini[:10],
            datetime_end[:10],
            self.config.distance,
        )

    def fetch_incidents(
        self,
        latitude: float,
        longitude: float,
        as_of: Optional[datetime] = None,
    ) -> List[IncidentRecord]:
        if not self.is_configured:
            return []

        try:
            datetime_ini, datetime_end = self._date_window(as_of or datetime.utcnow())
            cache_key = self._cache_key(latitude, longitude, datetime_ini, datetime_end)
            if cache_key in self._incident_cache:
                return self._incident_cache[cache_key]

            incidents: List[IncidentRecord] = []
            pages_count = 1

            for page in range(1, self.config.max_pages + 1):
                if page > pages_count:
                    break

                response = requests.get(
                    f"{self.config.base_url}/crime-incidents",
                    headers=self._headers(),
                    params={
                        "lat": latitude,
                        "lon": longitude,
                        "datetime_ini": datetime_ini,
                        "datetime_end": datetime_end,
                        "distance": self.config.distance,
                        "page": page,
                    },
                    timeout=self.config.timeout_seconds,
                )
                response.raise_for_status()

                payload = response.json()
                pages_count = int(payload.get("pages_count") or 1)
                for item in payload.get("incidents", []) or []:
                    parsed = self._parse_incident(item)
                    if parsed is not None:
                        incidents.append(parsed)

            self._incident_cache[cache_key] = incidents
            return incidents
        except Exception as e:
            # Graceful failure: return empty list instead of crashing
            import logging
            logging.warning(f"[IncidentIntelligenceClient] fetch_incidents failed for ({latitude},{longitude}): {e}")
            return []

    def fetch_stats(
        self,
        latitude: float,
        longitude: float,
        as_of: Optional[datetime] = None,
    ) -> Dict[str, Any]:
        if not self.is_configured:
            return {}

        try:
            datetime_ini, datetime_end = self._date_window(as_of or datetime.utcnow())
            cache_key = self._cache_key(latitude, longitude, datetime_ini, datetime_end)
            if cache_key in self._stats_cache:
                return self._stats_cache[cache_key]

            response = requests.get(
                f"{self.config.base_url}/incidents/stats",
                headers=self._headers(),
                params={
                    "lat": latitude,
                    "lon": longitude,
                    "datetime_ini": datetime_ini,
                    "datetime_end": datetime_end,
                    "distance": self.config.distance,
                },
                timeout=self.config.timeout_seconds,
            )
            response.raise_for_status()

            payload = response.json()
            self._stats_cache[cache_key] = payload
            return payload
        except Exception as e:
            # Graceful failure: return empty dict instead of crashing
            import logging
            logging.warning(f"[IncidentIntelligenceClient] fetch_stats failed for ({latitude},{longitude}): {e}")
            return {}

    def _parse_incident(self, payload: Dict[str, Any]) -> Optional[IncidentRecord]:
        latitude = payload.get("incident_latitude")
        longitude = payload.get("incident_longitude")
        if latitude is None or longitude is None:
            return None

        offense = str(
            payload.get("incident_offense")
            or payload.get("incident_offense_description")
            or payload.get("incident_source_original_type")
            or ""
        )
        crime_against = str(payload.get("incident_offense_crime_against") or "")

        return IncidentRecord(
            incident_id=str(payload.get("incident_code") or ""),
            latitude=float(latitude),
            longitude=float(longitude),
            timestamp=self._parse_timestamp(payload.get("incident_date")),
            offense=offense,
            crime_against=crime_against,
            severity=self._severity(offense, crime_against),
            raw=payload,
        )

    def _parse_timestamp(self, value: Any) -> float:
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str) and value:
            normalized = value.replace("Z", "+00:00")
            try:
                return datetime.fromisoformat(normalized).timestamp()
            except ValueError:
                try:
                    return datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S").timestamp()
                except ValueError:
                    return datetime.utcnow().timestamp()
        return datetime.utcnow().timestamp()

    def _severity(self, offense: str, crime_against: str) -> float:
        text = f"{offense} {crime_against}".lower()

        if any(term in text for term in ["homicide", "murder", "manslaughter"]):
            return 5.0
        if any(term in text for term in ["rape", "sexual", "kidnapping", "trafficking"]):
            return 5.0
        if any(term in text for term in ["robbery", "aggravated assault", "shooting", "weapon"]):
            return 4.5
        if any(term in text for term in ["assault", "arson", "burglary"]):
            return 4.0
        if any(term in text for term in ["vehicle theft", "motor vehicle theft"]):
            return 3.2
        if any(term in text for term in ["theft", "vandalism", "fraud", "damage"]):
            return 2.3
        if "person" in text:
            return 4.0
        if "society" in text:
            return 3.0
        if "property" in text:
            return 2.5
        return 2.0
