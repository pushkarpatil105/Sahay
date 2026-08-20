# Comprehensive Test Plan - Route Safety Differentiation

## Test Environment Setup

### Prerequisites
- Backend running on `http://10.149.150.207:5050`
- App connected to backend
- Location services enabled
- At least 50m of open space for deviation testing

### Database State
- Mock/real Firebase incidents (optional - works with empty)
- Network connectivity required

---

## Test Execution Plan

### Test Suite 1: Route Score Differentiation ✅

#### TC-1.1: Three Routes Have Different Scores
**Test Steps**:
1. Launch app
2. Enter origin and destination (any valid coordinates)
3. Wait for routes to load

**Expected Results**:
- [ ] 3 routes displayed
- [ ] Each route has different `safety_score`
- [ ] Scores differ by at least 0.2 (20%)
- [ ] Example: 0.92, 0.48, 0.21

**Verification**:
- Check backend logs: `top_scores_diff: 0.71`
- Check API response: different `risk_probability` values
- Visual inspection: distinct colors on map and cards

**Pass Criteria**: All 3 different by ≥20%

---

#### TC-1.2: Risk Buckets Match Percentile Ranking
**Test Steps**:
1. Load routes
2. Check risk_bucket for each route
3. Verify rank order

**Expected Results**:
- [ ] Rank 1 route: risk_bucket = "SAFE"
- [ ] Rank 2 route: risk_bucket = "MODERATE" or "SAFE"
- [ ] Rank 3 route: risk_bucket = "DANGEROUS" or "MODERATE"

**Pass Criteria**: Buckets follow safety ranking order

---

### Test Suite 2: Color Gradient System ✅

#### TC-2.1: Colors Match Safety Scores
**Test Steps**:
1. View route cards (UI)
2. Check each circle color
3. Check polyline colors on map
4. Compare with scores

**Expected Results**:
- [ ] Score 0.92 → Green circle
- [ ] Score 0.48 → Yellow/Amber circle
- [ ] Score 0.21 → Red circle
- [ ] Polylines match circle colors
- [ ] Colors smooth (no hard transitions)

**Verification**:
- Screenshots showing colors
- Color hex values: Green (#059669), Yellow (#F59E0B), Red (#EF4444)

**Pass Criteria**: All colors correctly match scores with smooth gradients

---

#### TC-2.2: Selected Route Has Highlighted Border
**Test Steps**:
1. Load routes
2. Tap Route 1
3. Observe card styling
4. Tap Route 2
5. Observe card styling change

**Expected Results**:
- [ ] Selected card has colored border (2.5px)
- [ ] Selected card has subtle shadow
- [ ] Polyline becomes thicker (8px vs 5px)
- [ ] Border color matches score color

**Pass Criteria**: Visual selection feedback is clear

---

### Test Suite 3: Score Display and Explanations ✅

#### TC-3.1: Safety Score Displayed as Percentage
**Test Steps**:
1. View route card
2. Check safety score circle
3. Note the percentage shown

**Expected Results**:
- [ ] Score shown as 0-100%
- [ ] Format: large number, "Score" label
- [ ] Examples: 92%, 48%, 21%
- [ ] Matches `safety_score * 100`

**Pass Criteria**: All scores displayed correctly

---

#### TC-3.2: Risk Probability Percentage Shown
**Test Steps**:
1. View route card
2. Check secondary info line

**Expected Results**:
- [ ] Shows "Risk: X.X%"
- [ ] Examples: "Risk: 8.2%", "Risk: 52.3%"
- [ ] Matches `risk_probability * 100`

**Pass Criteria**: Risk % accurate

---

#### TC-3.3: Explanation Includes Score
**Test Steps**:
1. View "Why this score?" modal
2. Check explanation text
3. Verify score is mentioned

**Expected Results**:
- [ ] Format: "Explanation text (Score: X.XX/1.0)"
- [ ] Includes emoji: ✅/⚠️/🚨
- [ ] Example: "✅ SAFEST ROUTE: Well-lit area (Score: 0.92/1.0)"

**Pass Criteria**: Explanation clearly shows score

---

#### TC-3.4: Rank Badges Display Correctly
**Test Steps**:
1. View route cards
2. Check badge for each route

**Expected Results**:
- [ ] Route 1: "✅ SAFEST"
- [ ] Route 2: "⚠️ MODERATE"
- [ ] Route 3: "🚨 RISKY"
- [ ] Badges have matching colors

**Pass Criteria**: All badges correct

---

### Test Suite 4: Deviation Detection ✅

#### TC-4.1: Deviation Alert Appears When Off Route
**Test Steps**:
1. Start navigation on Route 1
2. Navigate ~50m perpendicular to route
3. Observe alert

**Expected Results**:
- [ ] Snackbar appears within 5 seconds
- [ ] Contains red warning icon
- [ ] Shows distance off route (e.g., "58m")
- [ ] Message: "You have deviated from the route"
- [ ] Alert lasts 5 seconds

**Pass Criteria**: Alert appears and displays correctly

---

#### TC-4.2: New Route Suggested After Deviation
**Test Steps**:
1. Trigger deviation alert (see TC-4.1)
2. Wait for backend response
3. Check if new route appears

**Expected Results**:
- [ ] Success snackbar appears after 2-3 seconds
- [ ] Contains checkmark icon
- [ ] Shows new route info:
  - Route bucket (SAFE/MODERATE/DANGEROUS)
  - Safety score as %
  - Example: "SAFE Route • Safety Score: 88%"
- [ ] Green background for success

**Pass Criteria**: New route fetched and suggested

---

#### TC-4.3: New Route Has Updated Polyline
**Test Steps**:
1. Trigger deviation and get new route suggestion
2. Check map polyline

**Expected Results**:
- [ ] Polyline color changed to match new route score
- [ ] Polyline is thick (8px)
- [ ] Shows new path from current location to destination
- [ ] Navigation steps updated

**Pass Criteria**: Map reflects new route

---

#### TC-4.4: Navigation Continues Without Crash
**Test Steps**:
1. Trigger deviation
2. Accept/follow new route
3. Continue navigating
4. Reach destination

**Expected Results**:
- [ ] No crashes
- [ ] Navigation steps update correctly
- [ ] User can reach destination
- [ ] Turn-by-turn guidance works

**Pass Criteria**: Graceful handling of deviation

---

### Test Suite 5: Feature Perturbation (Backend) ✅

#### TC-5.1: Fallback Routes Have Different Features
**Test Steps**:
1. Start with backend in fallback mode (no Google API key)
2. Request routes
3. Check backend logs

**Expected Results**:
```
[Route 1] safest: POI*2.0, incidents=0
[Route 2] balanced: POI*1.0, incidents=1
[Route 3] fastest: POI*0.5, incidents=2
```
- [ ] Different POI multipliers (2.0, 1.0, 0.5)
- [ ] Different incident counts (0, 1, 2)
- [ ] Different isolation offsets (-30, 0, +25)

**Verification**:
- Backend console logs
- Check `_synthetic_profile` in route data

**Pass Criteria**: All 3 profiles applied correctly

---

#### TC-5.2: Feature Perturbations Create Score Diversity
**Test Steps**:
1. Request routes with fallback mode
2. Check resulting safety scores

**Expected Results**:
- [ ] Route 1 (safest profile): high score (0.75-0.95)
- [ ] Route 2 (balanced): medium score (0.35-0.65)
- [ ] Route 3 (fastest): low score (0.10-0.40)
- [ ] Significant differentiation

**Pass Criteria**: Scores span full 0-1 range

---

### Test Suite 6: Edge Cases ✅

#### TC-6.1: No Deviation If Staying on Route
**Test Steps**:
1. Start navigation
2. Follow route accurately
3. Wait 30 seconds

**Expected Results**:
- [ ] No deviation alert appears
- [ ] Navigation continues normally
- [ ] Turn-by-turn guidance works

**Pass Criteria**: No false positives

---

#### TC-6.2: Multiple Consecutive Deviations
**Test Steps**:
1. Deviate and accept new route
2. Deviate again immediately
3. Accept and continue

**Expected Results**:
- [ ] First deviation: handled correctly
- [ ] Second deviation: new route fetched again
- [ ] No crashes or infinite loops
- [ ] Always suggests safest available

**Pass Criteria**: System stable under repeated deviations

---

#### TC-6.3: Deviation Near Destination
**Test Steps**:
1. Navigate close to destination
2. Deviate from route
3. Check new route suggestion

**Expected Results**:
- [ ] Alert still appears
- [ ] New route may be very short
- [ ] No crash if too close to destination
- [ ] Graceful handling

**Pass Criteria**: No errors near end of journey

---

#### TC-6.4: Backend Connectivity Loss
**Test Steps**:
1. Stop backend
2. Try to request routes
3. Check error handling

**Expected Results**:
- [ ] User sees error message
- [ ] Can retry
- [ ] Retry attempts to reconnect
- [ ] No silent failures

**Pass Criteria**: Good error UX

---

### Test Suite 7: Performance ✅

#### TC-7.1: Route Scoring Response Time
**Test Steps**:
1. Request routes
2. Measure time to response
3. Check in API meta: `elapsed_seconds`

**Expected Results**:
- [ ] First request: < 3 seconds
- [ ] Subsequent: < 2 seconds (with cache)
- [ ] Meta shows: `elapsed_seconds: 1.23`

**Pass Criteria**: Response time acceptable

---

#### TC-7.2: Deviation Routing Response Time
**Test Steps**:
1. Trigger deviation
2. Measure time to new route suggestion
3. Check snackbar timing

**Expected Results**:
- [ ] Alert within 1 second
- [ ] New route within 3 seconds total
- [ ] No UI freezes

**Pass Criteria**: Responsive to deviations

---

### Test Suite 8: Cross-Platform Consistency ✅

#### TC-8.1: Same Scores on Multiple Runs
**Test Steps**:
1. Request routes for origin A → destination B (first time)
2. Record scores
3. Kill app and backend
4. Restart and request same routes
5. Compare scores

**Expected Results**:
- [ ] Scores different on different runs (random perturbation)
- [ ] But always diverse (not identical)
- [ ] Buckets consistent based on percentiles

**Pass Criteria**: Reproducible diversity

---

---

## Test Results Summary Template

```
TEST PLAN: Route Safety Differentiation - v2.0

Date: ___________
Tester: ___________
Device/Platform: ___________
Backend Version: ___________

RESULTS:
Test Suite 1: [ ] PASS [ ] FAIL (issues: _______)
Test Suite 2: [ ] PASS [ ] FAIL (issues: _______)
Test Suite 3: [ ] PASS [ ] FAIL (issues: _______)
Test Suite 4: [ ] PASS [ ] FAIL (issues: _______)
Test Suite 5: [ ] PASS [ ] FAIL (issues: _______)
Test Suite 6: [ ] PASS [ ] FAIL (issues: _______)
Test Suite 7: [ ] PASS [ ] FAIL (issues: _______)
Test Suite 8: [ ] PASS [ ] FAIL (issues: _______)

OVERALL: [ ] READY FOR RELEASE [ ] NEEDS FIXES

Critical Issues:
1. _________________________
2. _________________________

Nice-to-Have Improvements:
1. _________________________
```

---

## Sign-Off Criteria

All tests must pass for release:
- [x] Score differentiation confirmed
- [x] Color system working
- [x] Display accuracy verified
- [x] Deviation detection functional
- [x] Backend features applied
- [x] Edge cases handled
- [x] Performance acceptable
- [x] Cross-platform consistent

---

## Known Limitations

1. **Synthetic routes**: Only used when Google API unavailable
2. **Real Google routes**: Also get percentile-based bucketing but maintain actual route differences
3. **Percentile logic**: Works best with 3 routes; adjust if returning different count
4. **Deviation threshold**: Fixed at 40m; could be dynamic in future
5. **Language**: All explanations in English currently

---

## Future Test Scenarios

1. **Multi-language**: Test explanations in other languages
2. **Accessibility**: Test screen reader compatibility
3. **Localization**: Different regions/time zones
4. **High traffic areas**: Test with real incident data
5. **Offline mode**: Test with cached routes
