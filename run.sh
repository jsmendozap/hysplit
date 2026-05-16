#!/bin/bash
# =============================================================================
# run.sh — Execution of HYSPLIT with ERA5 data
# Usage:
#   ./run.sh              → Only convert and run HYSPLIT (assumes PRES.GRIB and SFC.GRIB already exist in ./data)
#   ./run.sh --download   → Download ERA5, convert and run HYSPLIT
# =============================================================================

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$PROJECT_DIR/data"
OUTPUT_DIR="$PROJECT_DIR/output"
RUN_DIR="$PROJECT_DIR/run"
HYSPLIT_EXEC="$PROJECT_DIR/build/hysplit/exec"
CFG="$RUN_DIR/config.json"

DOWNLOAD=false
CONVERT=true

# --- Parse flags -------------------------------------------------------------
for arg in "$@"; do
  case $arg in
    --download) DOWNLOAD=true ;;
    --skip-conversion) CONVERT=false ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# --- Load environment variables ----------------------------------------------
if [ -f "$PROJECT_DIR/.env" ]; then
  export $(grep -v '^#' "$PROJECT_DIR/.env" | xargs)
else
  echo "[ERROR] .env file not found in $PROJECT_DIR"
  exit 1
fi

if [ -z "$KEY" ]; then
  echo "[ERROR] The KEY variable is not defined in the .env file"
  exit 1
fi

# --- Time of interest ----------------------------------------------------------
START_DATE=$(jq -r '.date_start' "$CFG")
END_DATE=$(jq -r '.date_end' "$CFG")
  
PERIODS=$(python3 <<EOF
from datetime import datetime, timedelta
import calendar
import json

d1 = datetime.strptime("$START_DATE", '%Y-%m-%d %H:%M:%S')
d2 = datetime.strptime("$END_DATE", '%Y-%m-%d %H:%M:%S')
start, end = min(d1, d2), max(d1, d2)

curr = start
while curr <= end:
  y, m = curr.year, curr.month
  
  if y == start.year and m == start.month:
    s_day = start.day
  else:
    s_day = 1
      
  if y == end.year and m == end.month:
    e_day = end.day
  else:
    e_day = calendar.monthrange(y, m)[1]
  
  days = [f"{d:02d}" for d in range(s_day, e_day + 1)]    
  print(f"{y}|{m:02d}|{json.dumps(days)}")
  
  if m == 12:
    curr = datetime(y + 1, 1, 1)
  else:
    curr = datetime(y, m + 1, 1)
EOF
)

# --- 1. Download ERA5 data --------------------------------------------
if [ "$DOWNLOAD" = true ]; then
  printf "\n--- Downloading ERA5 data ---\n"

  BASE_URL="https://cds.climate.copernicus.eu/api/retrieve/v1"
  DATASETS=$(jq -r '.datasets | keys[]' "$CFG")
  AREA=$(jq -c '.area' "$CFG")
  
  HOURS=$(seq -f "%02g:00" 0 23 | jq -R . | jq -s -c .)

  echo "$PERIODS" | while IFS='|' read -r YEAR MONTH DAYS; do
    printf "\n--- Processing period: $YEAR-$MONTH ---\n"
    
    for key in $DATASETS; do
      PRODUCT=$(jq -r ".datasets.$key.name" "$CFG")
      OUTFILE=$(jq -r \
                  --arg k "$key" \
                  --arg suffix "_${YEAR}_${MONTH}.GRIB" \
                  '.datasets[$k].output + $suffix' "$CFG")

      if [ -f "$DATA_DIR/$OUTFILE" ]; then
        printf "\n[INFO] File already exists, skipping download: $OUTFILE"
        continue
      fi

      REQUEST=$(jq -c \
        --argjson area "$AREA" \
        --argjson days "$DAYS" \
        --argjson hours "$HOURS" \
        --argjson yr "$YEAR" \
        --argjson mo "$MONTH" \
        --argjson key "$key" \
        '.datasets[$key] | {
          product_type: "reanalysis",
          variable: .variables,
          year: $yr,
          month: $mo,
          day: $days,
          time: $hours,
          data_format: "grib",
          download_format: "unarchived",
          area: $area
        } + (if .pressure_levels then { "pressure_level": .pressure_levels } else {} end)' "$CFG")

      BODY=$(jq -n --argjson req "$REQUEST" '{"inputs": $req}')
      JOB_ID=$(curl -s -X POST \
          -H "PRIVATE-TOKEN: $KEY" \
          -H "Content-Type: application/json" \
          -d "$BODY" \
          "$BASE_URL/processes/$PRODUCT/execution" | jq -r '.jobID')

      printf "\n[INFO] Job submitted for $key: $YEAR-$MONTH\n"

      while true; do
        STATUS=$(curl -s -X 'GET' \
        "$BASE_URL/jobs/$JOB_ID?qos=false&request=false&log=false&allow_unauthenticated=false" \
        -H "accept: application/json" \
        -H "PRIVATE-TOKEN: $KEY" | jq -r '.status')

        printf "[$PRODUCT] Status: $STATUS\n"

        [ "$STATUS" = "successful" ] && break
        [ "$STATUS" = "failed" ]     && echo "[ERROR] Job $PRODUCT failed: $JOB_ID" && exit 1

        sleep 300 
      done

      DOWNLOAD_URL=$(curl -X 'GET' \
        "$BASE_URL/jobs/$JOB_ID/results?allow_unauthenticated=false" \
        -H "accept: application/json" \
        -H "PRIVATE-TOKEN: $KEY" \
        | jq -r '.asset.value.href')

      curl -L --progress-bar \
        -H "PRIVATE-TOKEN: $KEY" \
        -o "$DATA_DIR/$OUTFILE" \
        "$DOWNLOAD_URL"

      echo "[OK] $OUTFILE downloaded successfully"
    done
  done
fi

# --- 2. Write era52arl.cfg ------------------------------------------------
printf "\n--- Generating era52arl.cfg file ---\n"

if [ ! -f "$CFG" ]; then
  echo "[ERROR] Config file not found: $CFG"
  exit 1
fi

python3 <<EOF
import sys
import json
sys.path.append("$PROJECT_DIR/build")
import era5utils

with open("$CFG") as f: 
    config = json.load(f)

sname = era5utils.getvars()
var3d = {v[4]: k for k,v in sname.items() if len(v) >= 4 and v[4] and k != 'SHGT'}
var2d = {v[4]: k for k,v in sname.items() if len(v) >= 4 and v[4] and k != 'HGST'}

pl_vars = config.get("datasets").get("pressure").get("variables")
param3d = [var3d[x] for x in pl_vars if x in var3d]

sfc_vars = config.get("datasets").get("surface").get("variables")
param2d = [var2d[x] for x in sfc_vars if x in var2d]

levtype = "pl"
levs = [int(x) for x in config.get("datasets").get("pressure").get("pressure_levels")]

print(f"[INFO] 3D params: {param3d}")
print(f"[INFO] 2D params: {param2d}")
print(f"[INFO] Levels: {levs}")

era5utils.write_cfg(param3d, param2d, levs, tm=1, levtype=levtype, cfgname="era52arl.cfg")
EOF

if [ -f "$PROJECT_DIR/era52arl.cfg" ]; then
  mv "$PROJECT_DIR/era52arl.cfg" "$RUN_DIR/era52arl.cfg"
  echo "[OK] era52arl.cfg saved in $RUN_DIR"
else
  echo "[ERROR] Failed to write era52arl.cfg"
  exit 1
fi

if [ "$CONVERT" = true ]; then
  # --- 3. Convert GRIB Files to ARL ----------------------------------------------------
  FILES=($(ls $DATA_DIR | grep .GRIB | awk -F '[_.]' '{print $2"_"$3}' | sort -u))

  if [ ${#FILES[@]} -eq 0 ]; then
    echo "[ERROR] No GRIB files found in $DATA_DIR"
    exit 1
  fi

  printf "\n--- Converting GRIB files to ARL---\n"

  for file in "${FILES[@]}"; do
    IFS='_' read -r year month <<< "$file"
    printf "processing file: $file (year: $year, month: $month)\n"

    PRES_FILE="$(jq -r '.datasets.pressure.output' "$CFG")_${year}_${month}.GRIB"
    SURF_FILE="$(jq -r '.datasets.surface.output' "$CFG")_${year}_${month}.GRIB"
    OUT_FILE="MET_${file}.ARL"

    if [ -f "$OUTPUT_DIR/$OUT_FILE" ]; then
      printf "[INFO] $OUT_FILE already exists, skipping conversion\n"
      continue
    fi

    if [[ ! -f "$DATA_DIR/$PRES_FILE" || ! -f "$DATA_DIR/$SURF_FILE" ]]; then
        printf "[ERROR] Missing files for %s. Check %s or %s\n" "$file" "$PRES_FILE" "$SURF_FILE"
        continue
    fi

    LD_LIBRARY_PATH="$PROJECT_DIR/deps/eccodes/lib:$LD_LIBRARY_PATH" \
    .$RUN_DIR/era52arl -v \
      -i"$DATA_DIR/$PRES_FILE" \
      -a"$DATA_DIR/$SURF_FILE" \
      -o"$OUTPUT_DIR/$OUT_FILE"

    [[ $? -eq 0 ]] && printf "[OK] $OUT_FILE successfully saved in $OUTPUT_DIR\n"
  done

  cd "$PROJECT_DIR"
fi

# --- 4. SETUP.CFG ----------------------------------------------------------------
TCL_SRC="$PROJECT_DIR/build/hysplit/guicode/traj_cfg.tcl"
OUTPUT_CFG="$RUN_DIR/SETUP.CFG"

ACTIVE_LABELS=$(jq -r '.output | to_entries | .[] | select(.value > 0) | .key' "$CFG")

if [[ -n "$ACTIVE_LABELS" ]]; then
  declare -A MAP
  while read -r line; do
    LABEL=$(echo "$line" |  awk -F '"' '{print $2}' | xargs)
    VAR=$(echo "$line" | awk -F '-variable' '{print $2}' | xargs)
    
    if [[ -n "$LABEL" && -n "$VAR" ]]; then
      MAP["$LABEL"]="$VAR"
    fi
  done < <(grep "checkbutton" "$TCL_SRC")

  ACTIVE_VARS=""
  for label in "${!MAP[@]}"; do
    VAL=$(jq -r ".output[\"$label\"]" "$CFG")
    if [[ "$VAL" -eq 1 ]]; then
      ACTIVE_VARS="${ACTIVE_VARS} ${MAP[$label]}"
    fi
  done

  {
    echo "&SETUP"

    RESTART=$(jq -r ".setup.restart_interval" "$CFG")
    TSPAN=$(jq -r ".setup.trajectory_duration" "$CFG")

    sed -n '/proc reset_config/,/}/p' "$TCL_SRC" | grep "^set" | while read -r _ key val; do
      
      if [[ $key =~ ^(tset|delt)$ ]]; then
        continue
      fi

      if [[ $ACTIVE_VARS == *$key* ]]; then
        val=1
      fi 

      if [[ $key == "nstr" && $RESTART -gt 0 ]]; then
        val=$RESTART
      fi

      if [[ $key == "khmax" && $TSPAN -gt 0 ]]; then
        val=$TSPAN
      fi

      echo $key = $val,
    done

    echo "/"
  } > "$OUTPUT_CFG"
fi

# --- 5. CONTROL file and model execution ------------------------------------------------

CONTROL_SRC="$RUN_DIR/CONTROL"
CONTROL_DST="$HYSPLIT_EXEC/CONTROL"

NUM_POINTS=$(jq '.setup.points | length' "$CFG")
VERT_METHOD=$(jq -r '.setup.vertical_method' "$CFG")
TOP_MODEL=$(jq -r '.setup.top_model' "$CFG")

if [ $(date -d "$START_DATE" +%s) -gt $(date -d "$END_DATE" +%s) ]; then
  DIRECTION=-1  
else
  DIRECTION=1 
fi

while IFS='|' read -r YEAR MONTH DAYS; do
  
  printf "\n--- Processing: $YEAR-$MONTH ---\n"

  MET=$(python3 <<EOF
import json
from datetime import datetime, timedelta
import os

year = int("$YEAR")
month = int("$MONTH")
days = json.loads('$DAYS')  
raw_tspan = int("$TSPAN") 
direction = int("$DIRECTION")
tspan = 0 if raw_tspan == 9999 else raw_tspan

t_min = datetime(year, month, int(days[0]), 0, 0)
t_max = datetime(year, month, int(days[-1]), 0, 0) + timedelta(days=1)
hspan = int((t_max - t_min).total_seconds() / 3600)

if direction == -1:
  start = t_max
  end = t_max - timedelta(hours=hspan + tspan)
  start_time = t_max.strftime("%y %m %d %H")
else:
  start = t_min
  end = t_min + timedelta(hours=hspan + tspan)
  start_time = t_min.strftime("%y %m %d %H")

duration = direction * (hspan + tspan)
start, end = min(start, end), max(start, end)

files = []
current = datetime(start.year, start.month, 1)
target  = datetime(end.year, end.month, 1)

while current <= target:
  files.append(f"MET_{current.year}_{current.month:02d}.ARL")
  if current.month == 12:
    current = datetime(current.year + 1, 1, 1)
  else:
    current = datetime(current.year, current.month + 1, 1)

output = {
  "start_time": start_time,
  "duration": duration,
  "files": files
}
print(json.dumps(output))
EOF
)
  START=$(echo "$MET" | jq -r '.start_time')
  DURATION=$(echo "$MET" | jq -r '.duration')
  NUM_MET=$(echo "$MET" | jq '.files | length')

  MET_FILES=()
  while read -r f; do
    if [[ -n "$f" ]]; then
      if [[ ! -f "$OUTPUT_DIR/$f" ]]; then
        printf "[ERROR] Missing meteorological file: %s/%s\n" "$OUTPUT_DIR" "$f"
        exit 1
      fi
      MET_FILES+=("$f")
    fi
  done < <(echo "$MET" | jq -r '.files[]')

  {
    echo "$START"
    echo "$NUM_POINTS"
    
    for (( i=0; i<$NUM_POINTS; i++ )); do
      jq -r ".setup.points[$i] | \"\(.lat) \(.lon) \(.height)\"" "$CFG"
    done
    
    echo "$DURATION"
    echo "$VERT_METHOD"
    echo "$TOP_MODEL"
    echo "$NUM_MET"
    
    for f in "${MET_FILES[@]}"; do
      echo "$OUTPUT_DIR/"
      echo "$f"
    done

    echo "$OUTPUT_DIR/"
    echo "traj_out_${YEAR}_${MONTH}.txt"
  } > "$CONTROL_SRC"

  printf "[INFO] CONTROL file generated successfully \n"
  printf "[INFO] Executing HYSPLIT \n"

  cp "$RUN_DIR/SETUP.CFG" "$HYSPLIT_EXEC/"
  cp "$CONTROL_SRC" "$CONTROL_DST"
  
  cd "$HYSPLIT_EXEC" && ./hyts_std
  cd "$PROJECT_DIR"

  printf "\n=== Simulation $YEAR-$MONTH completed. Results saved in $OUTPUT_DIR ===\n"

done < <(echo "$PERIODS")

printf "[INFO] All simulations completed successfully\n"