# Technical Implementation Guide - Diversity-Constrained Route Generation

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    RouteFeatureEngine                        │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ fetch_routes() - Diversity-Constrained Search        │   │
│  │                                                       │   │
│  │  1. Initialize empty unique_routes, unique_corridors │   │
│  │  2. FOR iteration = 1 to MAX_DIVERSITY_ITERATIONS:   │   │
│  │     a. Build route variants (modifiers + waypoints)  │   │
│  │     b. FOR each variant:                             │   │
│  │        - Call Google Routes API                      │   │
│  │        - Decode polyline to corridor                 │   │
│  │        - Check uniqueness vs existing routes         │   │
│  │        - IF unique: accept and add to list           │   │
│  │        - ELSE: reject                                │   │
│  │     c. IF enough unique routes: break                │   │
│  │  3. Return top N unique routes                       │   │
│  │                                                       │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ SpatialCorridorEngine                                │   │
│  │ - polyline_to_corridor(): Convert to grid cells      │   │
│  │ - jaccard_similarity(): Measure overlap              │   │
│  │ - min_overlap_with_set(): Find least-overlapping     │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ RouteUniquenessEvaluator                             │   │
│  │ - is_sufficiently_unique(): Check if route qualifies │   │
│  │ - evaluate_batch(): Filter multiple routes           │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ MidpointDiversificationGenerator                     │   │
│  │ - generate_waypoint_variants(): Create perturbed pts │   │
│  │ - _perturb_coordinate(): Cardinal direction shift    │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. SpatialCorridorEngine

**Purpose**: Represent routes as spatial corridors and compute overlap metrics.

**Key Methods**:

```python
def polyline_to_corridor(decoded_points: List[Tuple[float, float]]) -> Set[Tuple[int, int]]:
    """
    Convert polyline points to grid cells.
    
    Algorithm:
    1. For each (lat, lon) in decoded_points:
       - Convert to grid cell ID: (int(lat/GRID_CELL_SIZE), int(lon/GRID_CELL_SIZE))
       - Add to corridor set
    2. Return set of unique grid cells
    
    Complexity: O(n) where n = number of polyline points
    """
```

```python
def jaccard_similarity(corridor_a, corridor_b) -> float:
    """
    Compute Jaccard similarity between two corridors.
    
    Formula: |A ∩ B| / |A ∪ B|
    
    Range: [0, 1]
    - 0.0 = no overlap
    - 1.0 = identical corridors
    
    Complexity: O(min(|A|, |B|))
    """
```

```python
def min_overlap_with_set(corridor, corridor_set) -> float:
    """
    Find minimum Jaccard similarity with any corridor in set.
    
    Used to find the least-overlapping route.
    
    Complexity: O(k * min(|corridor|, |other|)) where k = len(corridor_set)
    """
```

### 2. RouteUniquenessEvaluator

**Purpose**: Filter routes by geographic uniqueness.

**Key Methods**:

```python
def is_sufficiently_unique(candidate_corridor, existing_corridors) -> bool:
    """
    Check if candidate is sufficiently unique.
    
    Algorithm:
    1. Compute min_overlap = minimum Jaccard similarity with any existing route
    2. Return min_overlap < CORRIDOR_OVERLAP_REJECTION_THRESHOLD
    
    Threshold: 0.50 (allow up to 50% overlap)
    """
```

### 3. MidpointDiversificationGenerator

**Purpose**: Generate diverse waypoint anchors to force route diversity.

**Key Methods**:

```python
def generate_waypoint_variants(origin, destination) -> List[Tuple[float, float]]:
    """
    Generate 8 perturbed midpoint waypoints.
    
    Algorithm:
    1. Compute midpoint: ((lat1+lat2)/2, (lon1+lon2)/2)
    2. For each direction in [N, S, E, W, NE, NW, SE, SW]:
       - Perturb midpoint by MIDPOINT_PERTURBATION_DISTANCE
       - Add to waypoints list
    3. Return list of 8 waypoint coordinates
    
    Perturbation distances:
    - Cardinal (N/S/E/W): 0.03 degrees (~3km)
    - Diagonal (NE/NW/SE/SW): 0.03 * 0.707 (~2.1km)
    """
```

## Diversity-Constrained Fetch Algorithm

### Pseudocode

```
function fetch_routes(origin, destination, num_alternatives):
    unique_routes = []
    unique_corridors = []
    
    for iteration = 1 to MAX_DIVERSITY_ITERATIONS:
        variants = build_route_variants(origin, destination, iteration)
        
        for variant in variants:
            routes = call_google_api(variant)
            
            for route in routes:
                corridor = decode_and_convert_to_corridor(route)
                
                if is_sufficiently_unique(corridor, unique_corridors):
                    unique_routes.append(route)
                    unique_corridors.append(corridor)
                    
                    if len(unique_routes) >= num_alternatives:
                        return unique_routes
                else:
                    reject_route(route)
    
    if len(unique_routes) > 0:
        return unique_routes
    else:
        return fallback_synthetic_routes()
```

### Iteration Strategy

**Iteration 1**: Base routing preferences
- TRAFFIC_AWARE_OPTIMAL + avoidFerries
- TRAFFIC_AWARE + avoidHighways + avoidFerries
- TRAFFIC_UNAWARE + avoidTolls + avoidFerries

**Iteration 2+**: Add waypoint constraints
- Use perturbed midpoint from MidpointDiversificationGenerator
- Cycle through 8 cardinal directions
- Force Google to route through specific waypoints

### Route Variant Building

```python
def _build_route_variants(origin_body, dest_body, travel_mode_enum, iteration):
    variants = []
    
    if travel_mode_enum == "DRIVE":
        # Base variants (all iterations)
        variants.append({
            "origin": origin_body,
            "destination": dest_body,
            "travelMode": "DRIVE",
            "computeAlternativeRoutes": True,
            "routingPreference": "TRAFFIC_AWARE_OPTIMAL",
            "routeModifiers": {"avoidFerries": True}
        })
        # ... more base variants ...
        
        # Waypoint variants (iteration > 1)
        if iteration > 1:
            waypoints = midpoint_generator.generate_waypoint_variants(origin, dest)
            waypoint_idx = (iteration - 2) % len(waypoints)
            waypoint = waypoints[waypoint_idx]
            
            variants.append({
                "origin": origin_body,
                "destination": dest_body,
                "intermediates": [waypoint_body],
                "travelMode": "DRIVE",
                "computeAlternativeRoutes": True,
                "routingPreference": "TRAFFIC_UNAWARE"
            })
    
    return variants
```

## Data Flow

### Input
```python
origin: Tuple[float, float]           # (lat, lng)
destination: Tuple[float, float]      # (lat, lng)
num_alternatives: int = 3
travel_mode: str = "driving"
```

### Processing

1. **Fetch Routes**
   - Input: origin, destination, travel_mode
   - Output: List[Dict] with polylines

2. **Decode Polylines**
   - Input: encoded polyline string
   - Output: List[Tuple[float, float]] (lat/lon points)

3. **Convert to Corridors**
   - Input: decoded points
   - Output: Set[Tuple[int, int]] (grid cells)

4. **Measure Overlap**
   - Input: candidate corridor, existing corridors
   - Output: float (Jaccard similarity)

5. **Evaluate Uniqueness**
   - Input: overlap score, threshold
   - Output: bool (accept/reject)

6. **Extract Features**
   - Input: route, corridors
   - Output: Dict (22-feature schema)

### Output
```python
{
    "id": "0",
    "distanceMeters": 8000,
    "duration": "1100s",
    "polyline": {
        "encodedPolyline": "..."
    },
    "corridor_metadata": {
        "overlap_score": 0.266,
        "unique_cells": 94,
        "shared_cells": 34
    }
}
```

## Configuration Parameters

### Diversity Constraints

```python
# Corridor overlap threshold (0-1)
# Routes with overlap >= threshold are rejected
CORRIDOR_OVERLAP_REJECTION_THRESHOLD = 0.50

# Perturbation distance in degrees (~km)
# Used to generate diverse waypoint anchors
MIDPOINT_PERTURBATION_DISTANCE = 0.03

# Maximum iterations to find diverse routes
MAX_DIVERSITY_ITERATIONS = 5

# Minimum unique routes required
MIN_UNIQUE_ROUTES_REQUIRED = 2
```

### Spatial Grid

```python
# Grid cell size for corridor representation (~meters)
GRID_CELL_SIZE = 0.005  # ~500m at equator

# Grid cell size for Places API caching (~meters)
CACHE_GRID_SIZE = 0.01  # ~1km at equator
```

### Places API

```python
# Search radius for nearby places
PLACES_RADIUS = 200  # meters

# Request delay to avoid rate limiting
REQUEST_DELAY = 0.1  # seconds

# Max consecutive Places API failures before giving up
_places_max_failures = 3
```

## Performance Optimization

### Caching Strategy

1. **Corridor Cache**: Store computed corridors to avoid recomputation
2. **Places Cache**: Grid-based cache prevents duplicate API calls
3. **Polyline Cache**: Cache decoded polylines

### Complexity Analysis

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| polyline_to_corridor | O(n) | n = polyline points |
| jaccard_similarity | O(min(a,b)) | a,b = corridor sizes |
| min_overlap_with_set | O(k*min(a,b)) | k = number of corridors |
| is_sufficiently_unique | O(k*min(a,b)) | k = existing routes |
| fetch_routes | O(i*v*r*k*min(a,b)) | i=iterations, v=variants, r=routes, k=existing |

### Memory Usage

- Corridor set: ~1KB per route (100-200 grid cells)
- Feature vector: ~1KB per route
- Total for 3 routes: ~10KB

## Error Handling

### API Failures

```python
# Google Routes API failure
if resp.status_code != 200:
    print(f"API {resp.status_code}: {resp.text[:120]}")
    return []

# Polyline decode failure
try:
    return polyline.decode(encoded)
except Exception as e:
    print(f"Polyline decode error: {e}")
    return []

# Places API consecutive failures
if self._places_consecutive_failures >= self._places_max_failures:
    return []
```

### Fallback Strategy

```python
# If diversity search fails
if len(unique_routes) == 0:
    print("All diversity attempts failed; using fallback routes")
    return self._build_fallback_routes(origin, destination, num_alternatives, travel_mode)
```

## Testing Strategy

### Unit Tests

1. **Corridor Conversion**: Verify polyline → grid cells
2. **Overlap Computation**: Verify Jaccard similarity
3. **Uniqueness Evaluation**: Verify threshold logic
4. **Waypoint Generation**: Verify perturbation logic

### Integration Tests

1. **End-to-End Fetch**: Verify complete diversity search
2. **Feature Extraction**: Verify 22-feature schema
3. **Model Prediction**: Verify XGBoost compatibility

### Diagnostic Tests

```bash
python route_differentiation_diagnostic.py
```

Expected output:
- Route overlap < 0.35 (after diversity filtering)
- Feature distance > 1000
- POI divergence visible
- Risk scores separated
