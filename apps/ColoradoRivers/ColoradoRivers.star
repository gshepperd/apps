"""
Applet: Colorado Rivers
Summary: Colorado river flow data
Description: Displays real-time streamflow (CFS), gage height, and water temperature 
             for Colorado rivers from the CO Division of Water Resources API.
             Includes fishing condition indicators for fly fishermen.
             Supports both standard (64x32) and 2x (128x64) displays.
Author: Greg
Supports2x: true
"""

load("cache.star", "cache")
load("encoding/json.star", "json")
load("http.star", "http")
load("humanize.star", "humanize")
load("render.star", "render", "canvas")
load("schema.star", "schema")
load("time.star", "time")

# Colorado DWR API base URL
DWR_API_BASE = "https://dwr.state.co.us/Rest/GET/api/v2"

# USGS Water Services API for temperature data
# Parameter 00010 = water temperature in Celsius
USGS_API_BASE = "https://waterservices.usgs.gov/nwis/iv"

# Mapping from CO DWR station abbreviations to USGS site numbers with temperature sensors
# This allows us to get temperature from USGS when DWR doesn't have it
# Format: DWR_abbrev: USGS_site_number
DWR_TO_USGS_TEMP = {
    # Arkansas River stations
    "ABORECO": "07087050",    # Arkansas below Granite (near Buena Vista)
    "ARKCANCO": "07096000",   # Arkansas at Canon City - has temp!
    "ARKWELCO": "07093700",   # Arkansas near Wellsville
    "ARKSFOCO": "07091500",   # Arkansas at Salida
    
    # South Platte stations - try nearby USGS sites
    "PLACHECO": "06701900",   # Cheesman - try North Fork below reservoir
    "PLATRUCO": "06701900",   # Trumbull/Deckers area
    
    # Clear Creek
    "CLEIDACO": "06719505",   # Clear Creek at Golden
    
    # Blue River  
    "BLUGRRCO": "09050700",   # Blue River below Green Mountain
    
    # Colorado River
    "COLKRMCO": "09058000",   # Colorado near Kremmling
    
    # Gunnison
    "GUNRIOCO": "09114500",   # Gunnison River near Gunnison
    
    # Roaring Fork
    "ROFASPEN": "09073400",   # Roaring Fork at Aspen
    
    # Fryingpan
    "FRYBASLT": "09080400",   # Fryingpan near Basalt
}

# Cache TTL in seconds (15 minutes - data updates every 15 min)
CACHE_TTL = 900

# Water temperature thresholds for trout (Fahrenheit)
# Based on trout biology research
TEMP_THRESHOLDS = {
    "cold": 40,      # Below this: sluggish feeding, fish deep
    "prime_low": 45, # Prime feeding zone starts
    "prime_high": 62, # Prime feeding zone ends
    "caution": 65,   # Caution: stress begins
    "danger": 68,    # Stop fishing: mortality risk
}

# River-specific ideal CFS ranges for fly fishing
# Format: {abbrev: {"min": min_cfs, "max": max_cfs, "ideal": ideal_cfs, "type": water_type}}
# Based on local fly shop recommendations and fishing reports
RIVER_FLOW_RANGES = {
    # === PRIORITY RIVERS (detailed data from local fly shops) ===
    
    # South Platte - Deckers (PLATRUCO = Trumbull gauge)
    # Pat Dorsey: ideal 150-400 CFS, technical tailwater
    # Winter: 100-150 CFS typical, Summer: can spike to 600+
    "PLATRUCO": {"min": 100, "max": 400, "ideal": 212, "type": "tailwater"},
    
    # South Platte - Cheesman Canyon
    # Ultra-technical, PhD trout, crystal clear
    # Best: 100-200 CFS, fishable to 350 CFS
    # Winter flows typically 100-150 CFS
    "PLACHECO": {"min": 80, "max": 350, "ideal": 150, "type": "tailwater"},
    
    # South Platte - Waterton Canyon
    # Hike-in tailwater, technical, spooky fish
    # Best: 50-150 CFS for wading, difficult above 200
    # Summer dam releases can hit 600-900 CFS (blown out)
    "PLAWATCO": {"min": 40, "max": 200, "ideal": 75, "type": "tailwater"},
    
    # Bear Creek - Evergreen
    # Small water! 3-4wt rod, pocket water
    # Ideal: 12-25 CFS, fishable 8-50 CFS
    # Very low flows normal - this is a small creek
    "BCREVERCO": {"min": 8, "max": 50, "ideal": 15, "type": "freestone"},
    
    # Clear Creek - Idaho Springs  
    # Freestone, pocket water, browns and rainbows
    # Best: 40-100 CFS, fishable to 150
    # Swift water - careful wading
    "CLEIDACO": {"min": 30, "max": 150, "ideal": 60, "type": "freestone"},
    
    # === OTHER SOUTH PLATTE ===
    "PLACHACO": {"min": 150, "max": 500, "ideal": 250, "type": "tailwater"},
    
    # === ARKANSAS RIVER ===
    # Note: Summer rafting flows (700+ CFS) end Aug 15
    # Best wade fishing: late Aug - Oct at 225-400 CFS
    "ARKLESCO": {"min": 150, "max": 400, "ideal": 250, "type": "freestone"},
    "ARKBVCO": {"min": 200, "max": 500, "ideal": 300, "type": "freestone"},
    "ARKSALCO": {"min": 225, "max": 400, "ideal": 300, "type": "freestone"},
    "ARKWELCO": {"min": 225, "max": 385, "ideal": 330, "type": "freestone"},
    "ARKCANCO": {"min": 250, "max": 600, "ideal": 400, "type": "freestone"},
    
    # === BLUE RIVER ===
    "BLUNDICO": {"min": 80, "max": 300, "ideal": 150, "type": "tailwater"},
    "BLUSILCO": {"min": 100, "max": 350, "ideal": 200, "type": "tailwater"},
    
    # === COLORADO RIVER ===
    "COLKRECO": {"min": 400, "max": 1500, "ideal": 800, "type": "freestone"},
    "COLGLCO": {"min": 800, "max": 2500, "ideal": 1500, "type": "freestone"},
    
    # === ROARING FORK ===
    "ROFASPCO": {"min": 100, "max": 400, "ideal": 200, "type": "freestone"},
    "ROFBASCO": {"min": 200, "max": 600, "ideal": 350, "type": "freestone"},
    "ROFGLECO": {"min": 300, "max": 800, "ideal": 500, "type": "freestone"},
    
    # === GUNNISON ===
    "GUNGUNCO": {"min": 200, "max": 600, "ideal": 350, "type": "freestone"},
    
    # === EAGLE RIVER ===
    "EAGAVOCO": {"min": 150, "max": 500, "ideal": 300, "type": "freestone"},
    
    # === YAMPA ===
    "YAMSTECO": {"min": 200, "max": 600, "ideal": 350, "type": "freestone"},
    
    # === CLEAR CREEK (other stations) ===
    "CLEGOLCO": {"min": 40, "max": 150, "ideal": 70, "type": "freestone"},
    
    # === BEAR CREEK (other stations) ===
    "BCRMORCO": {"min": 10, "max": 60, "ideal": 20, "type": "freestone"},
    
    # === BOULDER CREEK ===
    "BOCOROCO": {"min": 50, "max": 200, "ideal": 100, "type": "freestone"},
    "BOCBGRCO": {"min": 80, "max": 250, "ideal": 150, "type": "freestone"},
    
    # === BIG THOMPSON ===
    "BTHFESCO": {"min": 50, "max": 200, "ideal": 100, "type": "freestone"},
    "BTHLOVCO": {"min": 80, "max": 300, "ideal": 150, "type": "freestone"},
    
    # === CACHE LA POUDRE ===
    "CLAFPRCO": {"min": 100, "max": 400, "ideal": 200, "type": "freestone"},
    
    # === ANIMAS ===
    "ANIDURCO": {"min": 300, "max": 800, "ideal": 500, "type": "freestone"},
}

# Popular fishing/recreation river stations
# Format: {abbrev: {name: display_name, short_name: abbreviated_name}}
# Station abbreviations verified against CO DWR API
RIVER_STATIONS = {
    # South Platte River
    "PLATRUCO": {"name": "S. Platte - Trumbull (Deckers)", "short_name": "Deckers"},
    "PLACHECO": {"name": "S. Platte - Cheesman", "short_name": "Cheesman"},
    "PLAWATCO": {"name": "S. Platte - Waterton", "short_name": "Waterton"},
    "PLACHACO": {"name": "S. Platte - Chatfield", "short_name": "Chatfield"},
    "PLAGEOCO": {"name": "S. Platte - Lake George", "short_name": "Lake George"},
    "PLABAICO": {"name": "N. Fork S. Platte - Bailey", "short_name": "Bailey"},
    "PLADENCO": {"name": "S. Platte - Denver", "short_name": "Denver"},
    "PLAHENCO": {"name": "S. Platte - Henderson", "short_name": "Henderson"},
    
    # Bear Creek
    "BCREVERCO": {"name": "Bear Creek - Evergreen", "short_name": "Evergreen"},
    "BCRMORCO": {"name": "Bear Creek - Morrison", "short_name": "Morrison"},
    "BCROUTCO": {"name": "Bear Creek Reservoir Out", "short_name": "BCR Outlet"},
    
    # Clear Creek
    "CLEIDACO": {"name": "Clear Crk - Idaho Springs", "short_name": "Idaho Spr"},
    "CLEMPICO": {"name": "Clear Crk - Empire", "short_name": "Empire"},
    "CLEGOLCO": {"name": "Clear Crk - Golden", "short_name": "Golden"},
    
    # Boulder Creek
    "BOCOROCO": {"name": "Boulder Crk - Orodell", "short_name": "Orodell"},
    "BOCBGRCO": {"name": "Boulder Crk - Boulder", "short_name": "Boulder"},
    
    # Big Thompson
    "BTHFESCO": {"name": "Big Thompson - Estes Park", "short_name": "Estes Park"},
    "BTHLOVCO": {"name": "Big Thompson - Loveland", "short_name": "Loveland"},
    "BTHDRKCO": {"name": "Big Thompson - Drake", "short_name": "Drake"},
    
    # Cache la Poudre
    "CLAFPRCO": {"name": "Poudre - Ft Collins", "short_name": "Ft Collins"},
    "CLACANYO": {"name": "Poudre - Canyon Mouth", "short_name": "Poudre Cyn"},
    
    # Arkansas River
    "ARKLESCO": {"name": "Arkansas - Leadville", "short_name": "Leadville"},
    "ARKBVCO": {"name": "Arkansas - Buena Vista", "short_name": "Buena Vista"},
    "ARKSALCO": {"name": "Arkansas - Salida", "short_name": "Salida"},
    "ARKWELCO": {"name": "Arkansas - Wellsville", "short_name": "Wellsville"},
    "ARKCANCO": {"name": "Arkansas - Canon City", "short_name": "Canon City"},
    "ARKPUECO": {"name": "Arkansas - Pueblo", "short_name": "Pueblo"},
    "ARKLAJCO": {"name": "Arkansas - La Junta", "short_name": "La Junta"},
    
    # Rio Grande
    "RIODLNCO": {"name": "Rio Grande - Del Norte", "short_name": "Del Norte"},
    "RIOALMCO": {"name": "Rio Grande - Alamosa", "short_name": "Alamosa"},
    "RIOWAGCO": {"name": "Rio Grande - Wagon Wheel", "short_name": "Wagon Wheel"},
    
    # Roaring Fork
    "ROFASPCO": {"name": "Roaring Fork - Aspen", "short_name": "Aspen"},
    "ROFBASCO": {"name": "Roaring Fork - Basalt", "short_name": "Basalt"},
    "ROFGLECO": {"name": "Roaring Fork - Glenwood", "short_name": "Glenwood"},
    
    # Colorado River
    "COLKRECO": {"name": "Colorado - Kremmling", "short_name": "Kremmling"},
    "COLHSCO": {"name": "Colorado - Hot Sulphur", "short_name": "Hot Sulphur"},
    "COLGLCO": {"name": "Colorado - Glenwood", "short_name": "Col@Glenwood"},
    "COLRIFCO": {"name": "Colorado - Rifle", "short_name": "Rifle"},
    "COLCAMCO": {"name": "Colorado - Cameo", "short_name": "Cameo"},
    "COLSTLCO": {"name": "Colorado - State Line", "short_name": "State Line"},
    
    # Blue River
    "BLUNDICO": {"name": "Blue River - Dillon", "short_name": "Dillon"},
    "BLUSILCO": {"name": "Blue River - Silverthorne", "short_name": "Silverthorne"},
    "BLUGRMCO": {"name": "Blue River - Green Mtn", "short_name": "Green Mtn"},
    
    # Eagle River
    "EAGAVOCO": {"name": "Eagle River - Avon", "short_name": "Avon"},
    "EAGGYPCO": {"name": "Eagle River - Gypsum", "short_name": "Gypsum"},
    
    # Gunnison River
    "GUNGUNCO": {"name": "Gunnison - Gunnison", "short_name": "Gunnison"},
    "GUNDELCO": {"name": "Gunnison - Delta", "short_name": "Delta"},
    
    # Taylor River
    "TAYALMCO": {"name": "Taylor River - Almont", "short_name": "Taylor"},
    
    # Fraser River
    "FRAGRACO": {"name": "Fraser River - Granby", "short_name": "Granby"},
    "FRAWPCO": {"name": "Fraser River - Winter Park", "short_name": "Winter Park"},
    
    # Yampa River
    "YAMSTECO": {"name": "Yampa - Steamboat", "short_name": "Steamboat"},
    "YAMCRAIG": {"name": "Yampa - Craig", "short_name": "Craig"},
    
    # Elk River
    "ELKCLACO": {"name": "Elk River - Clark", "short_name": "Clark"},
    
    # Southwest Colorado
    "ANIDURCO": {"name": "Animas - Durango", "short_name": "Durango"},
    "DOLRICO": {"name": "Dolores - Rico", "short_name": "Rico"},
    "DOLDELCO": {"name": "Dolores - Dolores", "short_name": "Dolores"},
    "SJNPAGCO": {"name": "San Juan - Pagosa", "short_name": "Pagosa"},
}

# Data display options
DATA_OPTIONS = {
    "cfs": {"name": "Flow (CFS)", "param": "DISCHRG", "unit": "CFS", "color": "#00BFFF"},
    "gage": {"name": "Gage Height (ft)", "param": "GAGE_HT", "unit": "ft", "color": "#32CD32"},
    "temp": {"name": "Water Temp (°F)", "param": "WATTEMP", "unit": "°F", "color": "#FF6B6B"},
    "stage": {"name": "Stage (ft)", "param": "STAGE", "unit": "ft", "color": "#FFD700"},
}

def get_station_data(abbrev):
    """Fetch current telemetry data for a station from CO DWR API."""
    if not abbrev:
        return None
        
    cache_key = "co_rivers_{}".format(abbrev)
    cached = cache.get(cache_key)
    
    if cached:
        return json.decode(cached)
    
    # Fetch station data with current readings
    url = "{}/telemetrystations/telemetrystation?format=json&abbrev={}".format(DWR_API_BASE, abbrev)
    
    resp = http.get(url, ttl_seconds = CACHE_TTL)
    if resp.status_code != 200:
        return None
    
    data = resp.json()
    if not data.get("ResultList") or len(data["ResultList"]) == 0:
        return None
    
    station = data["ResultList"][0]
    
    # Extract relevant data
    result = {
        "abbrev": abbrev,
        "name": station.get("stationName", "Unknown"),
        "water_source": station.get("waterSource", ""),
        "parameter": station.get("parameter", ""),
        "value": station.get("measValue"),
        "units": station.get("units", ""),
        "stage": station.get("stage"),
        "meas_time": station.get("measDateTime", ""),
        "latitude": station.get("latitude"),
        "longitude": station.get("longitude"),
        "status": station.get("stationStatus", ""),
    }
    
    cache.set(cache_key, json.encode(result), ttl_seconds = CACHE_TTL)
    return result

def get_station_timeseries(abbrev, parameter):
    """Fetch recent timeseries data for trend display."""
    if not abbrev:
        return []
        
    cache_key = "co_rivers_ts_{}_{}".format(abbrev, parameter)
    cached = cache.get(cache_key)
    
    if cached:
        return json.decode(cached)
    
    url = "{}/telemetrystations/telemetrytimeseriesraw?format=json&abbrev={}&parameter={}&pageSize=10".format(
        DWR_API_BASE, abbrev, parameter
    )
    
    resp = http.get(url, ttl_seconds = CACHE_TTL)
    if resp.status_code != 200:
        return []
    
    data = resp.json()
    results = data.get("ResultList", [])
    
    cache.set(cache_key, json.encode(results), ttl_seconds = CACHE_TTL)
    return results

def get_water_temp(abbrev):
    """Try to fetch water temperature for a station from DWR or USGS."""
    if not abbrev:
        return None
        
    cache_key = "co_rivers_temp_{}".format(abbrev)
    cached = cache.get(cache_key)
    
    if cached:
        decoded = json.decode(cached)
        # Handle cached "no data" marker
        if decoded.get("no_data"):
            return None
        return decoded
    
    # Try CO DWR first
    url = "{}/telemetrystations/telemetrytimeseriesraw?format=json&abbrev={}&parameter=WATTEMP&pageSize=1".format(
        DWR_API_BASE, abbrev
    )
    
    resp = http.get(url, ttl_seconds = CACHE_TTL)
    if resp.status_code == 200:
        data = resp.json()
        results = data.get("ResultList", [])
        
        if results and len(results) > 0:
            temp_data = {
                "value": results[0].get("measValue"),
                "units": results[0].get("units", "F"),
                "time": results[0].get("measDateTime", ""),
                "source": "DWR",
            }
            cache.set(cache_key, json.encode(temp_data), ttl_seconds = CACHE_TTL)
            return temp_data
    
    # Try USGS as fallback if we have a mapping
    usgs_site = DWR_TO_USGS_TEMP.get(abbrev)
    if usgs_site:
        temp_data = get_usgs_water_temp(usgs_site)
        if temp_data:
            cache.set(cache_key, json.encode(temp_data), ttl_seconds = CACHE_TTL)
            return temp_data
    
    # No temperature data available
    cache.set(cache_key, json.encode({"no_data": True}), ttl_seconds = CACHE_TTL)
    return None

def get_usgs_water_temp(site_number):
    """Fetch water temperature from USGS Water Services API."""
    if not site_number:
        return None
    
    # USGS API for instantaneous values, parameter 00010 = water temp (Celsius)
    url = "{}?sites={}&parameterCd=00010&format=json".format(USGS_API_BASE, site_number)
    
    resp = http.get(url, ttl_seconds = CACHE_TTL)
    if resp.status_code != 200:
        return None
    
    data = resp.json()
    
    # Navigate USGS JSON structure to get the value
    # Structure: value.timeSeries[0].values[0].value[0].value
    time_series = data.get("value", {}).get("timeSeries", [])
    if not time_series or len(time_series) == 0:
        return None
    
    values = time_series[0].get("values", [])
    if not values or len(values) == 0:
        return None
    
    value_list = values[0].get("value", [])
    if not value_list or len(value_list) == 0:
        return None
    
    # USGS returns temperature in Celsius, convert to Fahrenheit
    temp_c = float(value_list[0].get("value", 0))
    temp_f = (temp_c * 9 / 5) + 32
    
    return {
        "value": temp_f,
        "units": "F",
        "time": value_list[0].get("dateTime", ""),
        "source": "USGS",
    }

def calculate_trend(timeseries):
    """Calculate trend direction from recent readings."""
    if not timeseries or len(timeseries) < 2:
        return "stable", 0
    
    values = []
    for reading in timeseries:
        val = reading.get("measValue")
        if val != None:
            values.append(float(val))
    
    if len(values) < 2:
        return "stable", 0
    
    # Compare most recent to average of previous
    current = values[0]
    previous_values = values[1:]
    total = 0.0
    for v in previous_values:
        total = total + v
    previous_avg = total / len(previous_values)
    
    change_pct = ((current - previous_avg) / previous_avg * 100) if previous_avg != 0 else 0
    
    if change_pct > 5:
        return "rising", change_pct
    elif change_pct < -5:
        return "falling", change_pct
    else:
        return "stable", change_pct

def calculate_flow_stability(timeseries):
    """
    Calculate flow stability over time for fishing assessment.
    Returns: (label, duration_text, change_pct, color)
    
    Stability is key for fishing:
    - STABLE flows = fish settled, predictable feeding
    - RISING flows = fish often stop feeding, repositioning
    - FALLING flows = can trigger feeding, but watch for stranding
    - Rapid changes = tough fishing regardless of direction
    """
    if not timeseries or len(timeseries) < 2:
        return "---", "", 0, "#888888"
    
    # Extract values and timestamps
    readings = []
    for reading in timeseries:
        val = reading.get("measValue")
        time_str = reading.get("measDateTime", "")
        if val != None:
            readings.append({"value": float(val), "time": time_str})
    
    if len(readings) < 2:
        return "---", "", 0, "#888888"
    
    current = readings[0]["value"]
    
    # Analyze stability over different time windows
    # DWR data is 15-min intervals, so:
    # 4 readings = 1 hour, 24 readings = 6 hours, 96 readings = 24 hours
    
    # Calculate changes at different windows
    windows = [
        {"count": 4, "label": "1h"},    # 1 hour
        {"count": 12, "label": "3h"},   # 3 hours  
        {"count": 24, "label": "6h"},   # 6 hours
        {"count": 48, "label": "12h"},  # 12 hours
        {"count": 96, "label": "24h"},  # 24 hours
    ]
    
    # Find the longest stable period
    stable_duration = ""
    max_change_pct = 0.0
    
    for window in windows:
        if len(readings) >= window["count"]:
            # Get value at end of window
            past_value = readings[window["count"] - 1]["value"]
            if past_value > 0:
                change_pct = ((current - past_value) / past_value) * 100
                
                # Track max change
                if abs(change_pct) > abs(max_change_pct):
                    max_change_pct = change_pct
                
                # If change is within ±10%, consider it stable for this window
                if abs(change_pct) <= 10:
                    stable_duration = window["label"]
    
    # Calculate the change over the available data
    if len(readings) >= 4:
        ref_idx = min(24, len(readings) - 1)  # Use 6h or max available
        ref_value = readings[ref_idx]["value"]
        if ref_value > 0:
            change_pct = ((current - ref_value) / ref_value) * 100
        else:
            change_pct = 0
    else:
        change_pct = 0
    
    # Determine label and color based on stability analysis
    if stable_duration:
        # Flows have been stable
        if stable_duration == "24h":
            return "STEADY", "24h", change_pct, "#00FF00"  # Green - very stable
        elif stable_duration in ["12h", "6h"]:
            return "STABLE", stable_duration, change_pct, "#88FF00"  # Light green
        else:
            return "STABLE", stable_duration, change_pct, "#CCFF00"  # Yellow-green
    else:
        # Flows are changing
        if change_pct > 30:
            return "SURGE", "", change_pct, "#FF0000"  # Red - big rise
        elif change_pct > 15:
            return "RISING", "", change_pct, "#FF9900"  # Orange
        elif change_pct > 5:
            return "UP", "", change_pct, "#FFCC00"  # Yellow
        elif change_pct < -30:
            return "PLUNGE", "", change_pct, "#FF0000"  # Red - big drop
        elif change_pct < -15:
            return "FALLING", "", change_pct, "#FF9900"  # Orange
        elif change_pct < -5:
            return "DOWN", "", change_pct, "#FFCC00"  # Yellow
        else:
            return "STABLE", "", change_pct, "#88FF00"  # Stable-ish

def get_trend_indicator(trend):
    """Return arrow character for trend."""
    if trend == "rising":
        return "↑"
    elif trend == "falling":
        return "↓"
    else:
        return "→"

def get_trend_color(trend):
    """Return color for trend indicator."""
    if trend == "rising":
        return "#00FF00"  # Green - flows rising
    elif trend == "falling":
        return "#FF6600"  # Orange - flows dropping
    else:
        return "#888888"  # Gray - stable

def get_fishing_condition(abbrev, cfs_value, temp_value = None):
    """
    Evaluate fishing conditions based on CFS and optionally water temp.
    Returns: (condition_code, condition_text, color)
    
    Labels are fishing-quality focused, not water-level focused:
    - FISH! = Prime conditions, go now!
    - GOOD = Good fishing, worth the trip
    - FAIR = Fishable but not ideal
    - SKIP = Poor conditions, don't bother
    - TOUGH = High water, difficult wading
    - BLOWN = Unfishable, way too high
    - TOO HOT = Dangerous for fish, stop fishing
    - WARM = Stress zone, fish early/late
    - SLOW = Cold water, sluggish fish
    """
    if cfs_value == None:
        return "unknown", "?", "#888888"
    
    cfs = float(cfs_value)
    
    # Check temperature first (overrides flow conditions if dangerous)
    if temp_value != None:
        temp = float(temp_value)
        if temp >= TEMP_THRESHOLDS["danger"]:
            return "hot", "TOO HOT", "#FF0000"
        elif temp >= TEMP_THRESHOLDS["caution"]:
            return "warm", "WARM", "#FF6600"
        elif temp < TEMP_THRESHOLDS["cold"]:
            return "cold", "SLOW", "#6699FF"
    
    # Check flow conditions
    flow_range = RIVER_FLOW_RANGES.get(abbrev)
    if not flow_range:
        # No specific data - give generic assessment
        return "unknown", "", "#888888"
    
    min_cfs = flow_range["min"]
    max_cfs = flow_range["max"]
    ideal_cfs = flow_range["ideal"]
    
    # Evaluate fishing quality (not just water level)
    if cfs < min_cfs * 0.7:
        return "low", "SKIP", "#FFCC00"       # Too low, poor fishing
    elif cfs < min_cfs:
        return "fair", "FAIR", "#CCCC00"      # Marginal, fishable
    elif cfs <= ideal_cfs * 1.1 and cfs >= ideal_cfs * 0.8:
        return "prime", "FISH!", "#00FF00"    # Prime conditions!
    elif cfs <= max_cfs:
        return "good", "GOOD", "#88FF00"      # Good fishing
    elif cfs <= max_cfs * 1.3:
        return "high", "TOUGH", "#FF9900"     # High water, hard wading
    else:
        return "high", "BLOWN", "#FF0000"     # Unfishable

def format_decimal(val, decimals):
    """Format a float with specified decimal places (Starlark compatible)."""
    if decimals == 0:
        return str(int(val))
    
    # Multiply by 10^decimals, round, then format
    multiplier = 1
    for _ in range(decimals):
        multiplier = multiplier * 10
    
    rounded = int(val * multiplier + 0.5)
    integer_part = rounded // multiplier
    decimal_part = rounded % multiplier
    
    # Pad decimal part with leading zeros if needed
    decimal_str = str(decimal_part)
    for _ in range(decimals - len(decimal_str)):
        decimal_str = "0" + decimal_str
    
    return "{}.{}".format(integer_part, decimal_str)

def format_value(value, units):
    """Format display value with appropriate precision."""
    if value == None:
        return "--"
    
    val = float(value)
    
    if units == "CFS":
        if val >= 1000:
            return humanize.comma(int(val))
        elif val >= 100:
            return str(int(val))
        elif val >= 10:
            return format_decimal(val, 1)
        else:
            return format_decimal(val, 2)
    elif units in ["ft", "FT"]:
        return format_decimal(val, 2)
    elif units in ["F", "°F"]:
        return str(int(val))
    else:
        return str(int(val)) if val == int(val) else format_decimal(val, 1)

def format_time(time_str):
    """Format measurement time for display."""
    if not time_str:
        return ""
    
    # Parse ISO time and format nicely
    # Time comes in format like "2025-12-29T19:15:00-07:00"
    # Extract just the time portion
    if "T" in time_str:
        time_part = time_str.split("T")[1]
        if len(time_part) >= 5:
            hour_min = time_part[:5]  # "HH:MM"
            return hour_min
    
    return ""

def render_station_frame(station, config, scale, is_wide):
    """Render a single station frame with full details."""
    
    # Font selection based on scale
    if scale == 2:
        title_font = "tb-8"  # Keep title readable
        value_font = "10x20"  # Large value font for 2x
        small_font = "6x13"   # Medium font for units/condition
    else:
        title_font = "tb-8"
        value_font = "6x13"
        small_font = "tom-thumb"
    
    if not station:
        return render.Box(
            child = render.Column(
                cross_align = "center",
                main_align = "center",
                children = [
                    render.Text("No Data", color = "#FF0000", font = value_font if scale == 2 else "6x13"),
                    render.Text("Check Station", font = small_font, color = "#888888"),
                ],
            ),
        )
    
    # Check if this is a failed station load
    if station.get("failed"):
        abbrev = station.get("abbrev", "???")
        display_name = RIVER_STATIONS.get(abbrev, {}).get("short_name", abbrev)
        return render.Box(
            child = render.Column(
                cross_align = "center",
                main_align = "center",
                children = [
                    render.Text(display_name, color = "#FFFFFF", font = small_font),
                    render.Text("API Error", color = "#FF0000", font = value_font if scale == 2 else "6x13"),
                    render.Text(abbrev, font = small_font, color = "#888888"),
                ],
            ),
        )
    
    abbrev = station.get("abbrev", "")
    display_name = RIVER_STATIONS.get(abbrev, {}).get("short_name", station.get("name", "Unknown")[:12])
    
    value = station.get("value")
    units = station.get("units", "CFS")
    meas_time = format_time(station.get("meas_time", ""))
    
    # Get trend data
    show_trend = config.bool("show_trend", True)
    trend = "stable"
    trend_indicator = ""
    trend_color = "#888888"
    timeseries = None
    
    if show_trend and value != None:
        param = station.get("parameter", "DISCHRG")
        timeseries = get_station_timeseries(abbrev, param)
        trend, change_pct = calculate_trend(timeseries)
        trend_indicator = get_trend_indicator(trend)
        trend_color = get_trend_color(trend)
    
    # Calculate flow stability for display
    stability_label = "---"
    stability_duration = ""
    stability_pct = 0
    stability_color = "#888888"
    
    if timeseries and len(timeseries) >= 4:
        stability_label, stability_duration, stability_pct, stability_color = calculate_flow_stability(timeseries)
    
    # Get fishing condition indicator
    show_condition = config.bool("show_condition", True)
    condition_text = ""
    condition_color = "#888888"
    temp_value = None
    temp_data = None
    
    if show_condition and units == "CFS":
        # Try to get water temp for condition assessment
        temp_data = get_water_temp(abbrev) if config.bool("check_temp", True) else None
        temp_value = temp_data.get("value") if temp_data else None
        
        condition_code, condition_text, condition_color = get_fishing_condition(
            abbrev, value, temp_value
        )
    
    # Determine colors based on data type
    data_color = DATA_OPTIONS.get("cfs", {}).get("color", "#00BFFF")
    if units in ["F", "°F"]:
        data_color = DATA_OPTIONS.get("temp", {}).get("color", "#FF6B6B")
    elif units in ["ft", "FT"] and station.get("parameter") == "GAGE_HT":
        data_color = DATA_OPTIONS.get("gage", {}).get("color", "#32CD32")
    
    # Format the value with units inline
    display_value = format_value(value, units)
    value_with_units = "{} {}".format(display_value, units)
    
    # Get flow range info for wide display
    flow_range = RIVER_FLOW_RANGES.get(abbrev)
    ideal_cfs = flow_range.get("ideal") if flow_range else None
    min_cfs = flow_range.get("min") if flow_range else None
    max_cfs = flow_range.get("max") if flow_range else None
    
    # Build frame based on display type
    if is_wide:
        # Wide layout (128x64) - show fishing-relevant info
        # Layout:
        # Row 1: River name (left) | Condition (right)
        # Row 2: CFS value + trend (large, center)
        # Row 3: Flow stability (left) | % of ideal (right)
        # Row 4: Ideal range (centered)
        
        # Format ideal range display
        range_display = ""
        if ideal_cfs and min_cfs and max_cfs:
            range_display = "{}-{}".format(int(min_cfs), int(max_cfs))
        
        # Calculate % of ideal
        pct_display = ""
        pct_color = "#888888"
        if ideal_cfs and value != None:
            pct = int((float(value) / ideal_cfs) * 100)
            pct_display = "{}%".format(pct)
            # Color based on how close to ideal
            if pct >= 80 and pct <= 120:
                pct_color = "#00FF00"  # Green - near ideal
            elif pct >= 50 and pct <= 150:
                pct_color = "#FFFF00"  # Yellow - ok
            elif pct < 50:
                pct_color = "#FF9900"  # Orange - low
            else:
                pct_color = "#FF6600"  # Orange - high
        
        # Wide layout (128x64) - use Tempest-style fonts
        font_large = "10x20"
        font_med = "6x13"
        font_small = "6x10"
        
        # Row 1: River name + condition
        row1 = render.Row(
            expanded = True,
            main_align = "space_between",
            cross_align = "center",
            children = [
                render.Text(
                    content = display_name,
                    font = font_med,
                    color = "#FFFFFF",
                ),
                render.Text(
                    content = condition_text if condition_text else "---",
                    font = font_med,
                    color = condition_color,
                ),
            ],
        )
        
        # Row 2: Large CFS value + trend
        row2 = render.Row(
            expanded = True,
            main_align = "center",
            cross_align = "center",
            children = [
                render.Text(
                    content = value_with_units,
                    font = font_large,
                    color = data_color,
                ),
                render.Padding(
                    pad = (4, 0, 0, 0),
                    child = render.Text(
                        content = trend_indicator if show_trend else "",
                        font = font_large,
                        color = trend_color,
                    ),
                ),
            ],
        )
        
        # Row 3: Flow stability + % of ideal
        pct_text = (pct_display + " ideal") if pct_display else ""
        
        # Build stability display text
        if stability_duration:
            stability_text = "{} {}".format(stability_label, stability_duration)
        else:
            stability_text = stability_label
        
        row3 = render.Row(
            expanded = True,
            main_align = "space_between",
            cross_align = "center",
            children = [
                render.Text(
                    content = stability_text,
                    font = font_small,
                    color = stability_color,
                ),
                render.Text(
                    content = pct_text,
                    font = font_small,
                    color = pct_color,
                ),
            ],
        )
        
        # Row 4: Ideal range
        row4 = render.Row(
            expanded = True,
            main_align = "center",
            cross_align = "center",
            children = [
                render.Text(
                    content = "Ideal: " + (range_display if range_display else "--") + " CFS",
                    font = font_small,
                    color = "#888888",
                ),
            ],
        )
        
        return render.Padding(
            pad = 2,
            child = render.Column(
                expanded = True,
                main_align = "space_evenly",
                cross_align = "start",
                children = [row1, row2, row3, row4],
            ),
        )
    else:
        # Standard layout (64x32 or 128x32)
        row1 = render.Marquee(
            width = 60,
            child = render.Text(
                content = display_name,
                font = title_font,
                color = "#FFFFFF",
            ),
            offset_start = 0,
            offset_end = 0,
        )
        
        row2 = render.Row(
            expanded = True,
            main_align = "center",
            cross_align = "center",
            children = [
                render.Text(
                    content = value_with_units,
                    font = value_font,
                    color = data_color,
                ),
                render.Padding(
                    pad = (2, 0, 0, 0),
                    child = render.Text(
                        content = trend_indicator if show_trend else "",
                        font = value_font,
                        color = trend_color,
                    ),
                ),
            ],
        )
        
        row3 = render.Row(
            expanded = True,
            main_align = "center",
            cross_align = "center",
            children = [
                render.Text(
                    content = condition_text if show_condition else "",
                    font = small_font,
                    color = condition_color,
                ),
            ],
        )
        
        return render.Padding(
            pad = 1,
            child = render.Column(
                expanded = True,
                main_align = "space_evenly",
                cross_align = "center",
                children = [row1, row2, row3],
            ),
        )

def render_single_station(station_data, config, scale, is_wide, delay):
    """Render display for a single river station."""
    return render.Root(
        delay = delay,
        child = render_station_frame(station_data, config, scale, is_wide),
    )

def render_multi_station(stations_data, config, scale, is_wide, delay):
    """Render display cycling through multiple stations with full details."""
    frames = []
    
    # Get display duration from config (in seconds, default 4)
    display_duration = int(config.get("display_duration", "4"))
    
    # Use longer delay with fewer frames to reduce total frame count
    # 250ms * 16 = 4 seconds per station
    frame_delay = 250
    frames_per_station = display_duration * 4  # 4 frames per second at 250ms
    
    for station in stations_data:
        # Create the frame for this station (handles None case)
        station_frame = render_station_frame(station, config, scale, is_wide)
        
        # Duplicate for desired display duration
        for repeat_idx in range(frames_per_station):
            frames.append(station_frame)
    
    if len(frames) == 0:
        return render.Root(
            delay = frame_delay,
            child = render.Box(
                child = render.WrappedText(
                    content = "No stations configured",
                    color = "#FF0000",
                ),
            ),
        )
    
    return render.Root(
        delay = frame_delay,
        show_full_animation = True,
        child = render.Animation(
            children = frames,
        ),
    )

def main(config):
    """Main entry point for the app."""
    
    # Detect wide display (S3 Wide is 128x64 in 2x mode)
    is_wide = canvas.is2x()
    scale = 2 if is_wide else 1
    
    # Adjust animation delay for consistent perceived speed
    delay = 25 if is_wide else 50
    
    display_mode = config.get("display_mode", "single")
    
    # Collect all configured stations
    station_keys = ["station1", "station2", "station3", "station4", "station5", 
                    "station6", "station7", "station8", "station9", "station10"]
    
    stations = []
    for key in station_keys:
        station_abbrev = config.get(key, "none")
        if station_abbrev and station_abbrev != "none":
            stations.append(station_abbrev)
    
    # Default to PLACHECO if nothing configured
    if len(stations) == 0:
        stations = ["PLACHECO"]
    
    if display_mode == "single":
        # Single station mode - just show the first station
        station_data = get_station_data(stations[0])
        return render_single_station(station_data, config, scale, is_wide, delay)
    else:
        # Multi station mode - cycle through all configured stations
        # Pass tuples of (abbrev, data) so we can show which station failed
        stations_data = []
        for s in stations:
            data = get_station_data(s)
            # If data is None, create a minimal dict with just the abbrev for error display
            if data:
                stations_data.append(data)
            else:
                stations_data.append({"abbrev": s, "failed": True})
        return render_multi_station(stations_data, config, scale, is_wide, delay)

def get_schema():
    """Return the configuration schema for the app."""
    # Build station options sorted by display name
    # First create list of (display_name, key) tuples, sort, then create options
    station_list = []
    for k in RIVER_STATIONS.keys():
        v = RIVER_STATIONS[k]
        station_list.append((v["name"], k))
    
    # Sort by display name (first element of tuple)
    station_list = sorted(station_list)
    
    # Create schema options from sorted list
    station_options = []
    for item in station_list:
        station_options.append(schema.Option(display = item[0], value = item[1]))
    
    # Add "None" option for additional stations
    station_options_with_none = [schema.Option(display = "None", value = "none")] + station_options
    
    # Duration options
    duration_options = [
        schema.Option(display = "2 seconds", value = "2"),
        schema.Option(display = "3 seconds", value = "3"),
        schema.Option(display = "4 seconds", value = "4"),
        schema.Option(display = "5 seconds", value = "5"),
        schema.Option(display = "6 seconds", value = "6"),
        schema.Option(display = "8 seconds", value = "8"),
        schema.Option(display = "10 seconds", value = "10"),
    ]
    
    return schema.Schema(
        version = "1",
        fields = [
            schema.Dropdown(
                id = "display_mode",
                name = "Display Mode",
                desc = "Single station or cycle through multiple",
                icon = "display",
                default = "single",
                options = [
                    schema.Option(display = "Single Station", value = "single"),
                    schema.Option(display = "Multi Station (Cycle)", value = "multi"),
                ],
            ),
            schema.Dropdown(
                id = "display_duration",
                name = "Display Duration",
                desc = "How long to show each station in multi mode",
                icon = "clock",
                default = "4",
                options = duration_options,
            ),
            schema.Toggle(
                id = "show_trend",
                name = "Show Trend Arrow",
                desc = "Display rising/falling/stable trend indicator",
                icon = "arrowTrendUp",
                default = True,
            ),
            schema.Toggle(
                id = "show_condition",
                name = "Show Fishing Condition",
                desc = "Display GO/GOOD/HIGH/LOW indicator for fly fishing",
                icon = "fish",
                default = True,
            ),
            schema.Toggle(
                id = "check_temp",
                name = "Check Water Temperature",
                desc = "Include water temp in condition assessment (shows WARM/HOT warnings)",
                icon = "temperatureHigh",
                default = True,
            ),
            schema.Dropdown(
                id = "station1",
                name = "Station 1",
                desc = "Primary station (always shown)",
                icon = "water",
                default = "PLACHECO",
                options = station_options,
            ),
            schema.Dropdown(
                id = "station2",
                name = "Station 2",
                desc = "Second station (multi mode)",
                icon = "water",
                default = "none",
                options = station_options_with_none,
            ),
            schema.Dropdown(
                id = "station3",
                name = "Station 3",
                desc = "Third station (multi mode)",
                icon = "water",
                default = "none",
                options = station_options_with_none,
            ),
            schema.Dropdown(
                id = "station4",
                name = "Station 4",
                desc = "Fourth station (multi mode)",
                icon = "water",
                default = "none",
                options = station_options_with_none,
            ),
            schema.Dropdown(
                id = "station5",
                name = "Station 5",
                desc = "Fifth station (multi mode)",
                icon = "water",
                default = "none",
                options = station_options_with_none,
            ),
            schema.Dropdown(
                id = "station6",
                name = "Station 6",
                desc = "Sixth station (multi mode)",
                icon = "water",
                default = "none",
                options = station_options_with_none,
            ),
            schema.Dropdown(
                id = "station7",
                name = "Station 7",
                desc = "Seventh station (multi mode)",
                icon = "water",
                default = "none",
                options = station_options_with_none,
            ),
            schema.Dropdown(
                id = "station8",
                name = "Station 8",
                desc = "Eighth station (multi mode)",
                icon = "water",
                default = "none",
                options = station_options_with_none,
            ),
            schema.Dropdown(
                id = "station9",
                name = "Station 9",
                desc = "Ninth station (multi mode)",
                icon = "water",
                default = "none",
                options = station_options_with_none,
            ),
            schema.Dropdown(
                id = "station10",
                name = "Station 10",
                desc = "Tenth station (multi mode)",
                icon = "water",
                default = "none",
                options = station_options_with_none,
            ),
        ],
    )
