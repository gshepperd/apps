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
    """Try to fetch water temperature for a station."""
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
    
    url = "{}/telemetrystations/telemetrytimeseriesraw?format=json&abbrev={}&parameter=WATTEMP&pageSize=1".format(
        DWR_API_BASE, abbrev
    )
    
    resp = http.get(url, ttl_seconds = CACHE_TTL)
    if resp.status_code != 200:
        cache.set(cache_key, json.encode({"no_data": True}), ttl_seconds = CACHE_TTL)
        return None
    
    data = resp.json()
    results = data.get("ResultList", [])
    
    if not results or len(results) == 0:
        cache.set(cache_key, json.encode({"no_data": True}), ttl_seconds = CACHE_TTL)
        return None
    
    temp_data = {
        "value": results[0].get("measValue"),
        "units": results[0].get("units", "F"),
        "time": results[0].get("measDateTime", ""),
    }
    
    cache.set(cache_key, json.encode(temp_data), ttl_seconds = CACHE_TTL)
    return temp_data

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
    """
    if cfs_value == None:
        return "unknown", "?", "#888888"
    
    cfs = float(cfs_value)
    
    # Check temperature first (overrides flow conditions if dangerous)
    if temp_value != None:
        temp = float(temp_value)
        if temp >= TEMP_THRESHOLDS["danger"]:
            return "hot", "HOT!", "#FF0000"
        elif temp >= TEMP_THRESHOLDS["caution"]:
            return "warm", "WARM", "#FF6600"
        elif temp < TEMP_THRESHOLDS["cold"]:
            return "cold", "COLD", "#6699FF"
    
    # Check flow conditions
    flow_range = RIVER_FLOW_RANGES.get(abbrev)
    if not flow_range:
        # No specific data - give generic assessment
        return "unknown", "", "#888888"
    
    min_cfs = flow_range["min"]
    max_cfs = flow_range["max"]
    ideal_cfs = flow_range["ideal"]
    
    # Calculate how close to ideal
    if cfs < min_cfs * 0.7:
        return "low", "LOW", "#FFCC00"
    elif cfs < min_cfs:
        return "fair", "OK", "#CCCC00"
    elif cfs <= ideal_cfs * 1.1 and cfs >= ideal_cfs * 0.8:
        return "prime", "GO!", "#00FF00"
    elif cfs <= max_cfs:
        return "good", "GOOD", "#88FF00"
    elif cfs <= max_cfs * 1.3:
        return "high", "HIGH", "#FF9900"
    else:
        return "high", "BLOWN", "#FF0000"

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
            return "{:.1f}".format(val)
        else:
            return "{:.2f}".format(val)
    elif units in ["ft", "FT"]:
        return "{:.2f}".format(val)
    elif units in ["F", "°F"]:
        return str(int(val))
    else:
        return str(int(val)) if val == int(val) else "{:.1f}".format(val)

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
    
    # Calculate dimensions based on scale
    display_width = canvas.width()
    marquee_width = (display_width - 4) if is_wide else 62
    
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
    
    if show_trend and value != None:
        param = station.get("parameter", "DISCHRG")
        timeseries = get_station_timeseries(abbrev, param)
        trend, change_pct = calculate_trend(timeseries)
        trend_indicator = get_trend_indicator(trend)
        trend_color = get_trend_color(trend)
    
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
        # Wide layout (128x64) - show more fishing-relevant info
        # Layout:
        # Row 1: River name (left) | Condition (right)
        # Row 2: CFS value + trend (large, center)
        # Row 3: Water temp (left) | Ideal range (right)
        # Row 4: Time (left) | % of ideal (right)
        
        # Format water temp display
        temp_display = ""
        temp_color = "#888888"
        if temp_value != None:
            temp_f = int(float(temp_value))
            temp_display = "{}°F".format(temp_f)
            # Color code temperature
            if temp_f >= TEMP_THRESHOLDS["danger"]:
                temp_color = "#FF0000"  # Red - danger
            elif temp_f >= TEMP_THRESHOLDS["caution"]:
                temp_color = "#FF6600"  # Orange - caution
            elif temp_f >= TEMP_THRESHOLDS["prime_low"] and temp_f <= TEMP_THRESHOLDS["prime_high"]:
                temp_color = "#00FF00"  # Green - prime
            elif temp_f < TEMP_THRESHOLDS["cold"]:
                temp_color = "#6699FF"  # Blue - cold
            else:
                temp_color = "#CCCCCC"  # Light gray - ok
        
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
        
        return render.Box(
            padding = 2,
            child = render.Column(
                expanded = True,
                main_align = "space_between",
                children = [
                    # Row 1: River name (left) | Condition badge (right)
                    render.Row(
                        main_align = "space_between",
                        expanded = True,
                        cross_align = "center",
                        children = [
                            render.Marquee(
                                width = 90,
                                child = render.Text(
                                    content = display_name,
                                    font = "6x13",
                                    color = "#FFFFFF",
                                ),
                            ),
                            render.Box(
                                color = condition_color if condition_text else "#333333",
                                child = render.Padding(
                                    pad = (2, 1, 2, 1),
                                    child = render.Text(
                                        content = condition_text if condition_text else "---",
                                        font = "tom-thumb",
                                        color = "#000000" if condition_text else "#666666",
                                    ),
                                ),
                            ),
                        ],
                    ),
                    # Row 2: Main CFS value with trend (large, centered)
                    render.Row(
                        main_align = "center",
                        cross_align = "center",
                        expanded = True,
                        children = [
                            render.Text(
                                content = value_with_units,
                                font = "Dina_r400-6",
                                color = data_color,
                            ),
                            render.Box(width = 6, height = 1),
                            render.Text(
                                content = trend_indicator if show_trend else "",
                                font = "Dina_r400-6",
                                color = trend_color,
                            ),
                        ],
                    ),
                    # Row 3: Water temp (left) | Ideal range (right)
                    render.Row(
                        main_align = "space_between",
                        expanded = True,
                        children = [
                            render.Row(
                                children = [
                                    render.Text(
                                        content = "H2O:",
                                        font = "tom-thumb",
                                        color = "#666666",
                                    ),
                                    render.Text(
                                        content = temp_display if temp_display else "--",
                                        font = "tom-thumb",
                                        color = temp_color,
                                    ),
                                ],
                            ),
                            render.Row(
                                children = [
                                    render.Text(
                                        content = "Ideal:",
                                        font = "tom-thumb",
                                        color = "#666666",
                                    ),
                                    render.Text(
                                        content = range_display if range_display else "--",
                                        font = "tom-thumb",
                                        color = "#888888",
                                    ),
                                ],
                            ),
                        ],
                    ),
                    # Row 4: Time (left) | % of ideal (right)
                    render.Row(
                        main_align = "space_between",
                        expanded = True,
                        children = [
                            render.Text(
                                content = meas_time if meas_time else "--:--",
                                font = "tom-thumb",
                                color = "#666666",
                            ),
                            render.Row(
                                children = [
                                    render.Text(
                                        content = pct_display if pct_display else "",
                                        font = "tom-thumb",
                                        color = pct_color,
                                    ),
                                    render.Text(
                                        content = " ideal" if pct_display else "",
                                        font = "tom-thumb",
                                        color = "#666666",
                                    ),
                                ],
                            ),
                        ],
                    ),
                ],
            ),
        )
    else:
        # Standard layout (64x32)
        return render.Box(
            padding = 1,
            child = render.Column(
                expanded = True,
                main_align = "space_between",
                cross_align = "center",
                children = [
                    # River name at top
                    render.Marquee(
                        width = marquee_width,
                        child = render.Text(
                            content = display_name,
                            font = title_font,
                            color = "#FFFFFF",
                        ),
                        offset_start = 0,
                        offset_end = 0,
                    ),
                    # Main value display with units and trend
                    render.Row(
                        main_align = "center",
                        cross_align = "center",
                        children = [
                            render.Text(
                                content = value_with_units,
                                font = value_font,
                                color = data_color,
                            ),
                            render.Box(width = 2, height = 1),
                            render.Text(
                                content = trend_indicator if show_trend else "",
                                font = value_font,
                                color = trend_color,
                            ),
                        ],
                    ),
                    # Bottom row: condition, time
                    render.Row(
                        main_align = "space_between",
                        expanded = True,
                        children = [
                            render.Text(
                                content = condition_text if show_condition else "",
                                font = small_font,
                                color = condition_color,
                            ),
                            render.Text(
                                content = meas_time,
                                font = small_font,
                                color = "#666666",
                            ),
                        ],
                    ),
                ],
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
    
    # Use a fixed delay for multi-station animation
    # Keep frame count reasonable - 40 frames per station at 100ms = 4 seconds
    multi_delay = 100
    frames_per_station = display_duration * 10  # 10 fps at 100ms delay
    
    # Cap to avoid hitting frame limits
    if frames_per_station > 50:
        frames_per_station = 50
    
    for station in stations_data:
        if not station:
            continue
        
        frame = render_station_frame(station, config, scale, is_wide)
        
        # Add frame multiple times for configured display duration
        for i in range(frames_per_station):
            frames.append(frame)
    
    if len(frames) == 0:
        return render.Root(
            delay = multi_delay,
            child = render.Box(
                child = render.WrappedText(
                    content = "No stations configured",
                    color = "#FF0000",
                ),
            ),
        )
    
    return render.Root(
        delay = multi_delay,
        child = render.Animation(
            children = frames,
        ),
    )

def main(config):
    """Main entry point for the app."""
    
    # Detect display dimensions and scale
    is_2x = canvas.is2x()
    scale = 2 if is_2x else 1
    width = canvas.width()
    
    # Detect wide display (128x32 S3 Wide or 128x64 2x)
    is_wide = width > 64
    
    # Adjust animation delay for consistent perceived speed
    # Marquee moves 1px per frame, so faster delay on 2x keeps same speed
    delay = 25 if is_2x else 50
    
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
        stations_data = []
        for s in stations:
            stations_data.append(get_station_data(s))
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
