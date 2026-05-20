#!/bin/bash
# =============================================================================
# run.sh — Execution of HYSPLIT with ERA5 data
# Usage:
#   ./run.sh              → Only convert and run HYSPLIT (assumes PRES_*_*.GRIB and SFC_*_*.GRIB already exist in ./data)
#   ./run.sh --download   → Download ERA5, convert and run HYSPLIT
# =============================================================================

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$PROJECT_DIR/data"
OUTPUT_DIR="$PROJECT_DIR/output"
RUN_DIR="$PROJECT_DIR/run"
HYSPLIT_EXEC="$PROJECT_DIR/build/hysplit/exec"
CFG="$PROJECT_DIR/config.json"

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

# --- 1. Download ERA5 data --------------------------------------------
START_DATE=$(jq -r '.date_start' "$CFG")
END_DATE=$(jq -r '.date_end' "$CFG")

if [ "$DOWNLOAD" = true ]; then

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

  printf "\n--- Downloading ERA5 data ---\n"

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

  BASE_URL="https://cds.climate.copernicus.eu/api/retrieve/v1"
  DATASETS=$(jq -r '.datasets | keys[]' "$CFG")
  AREA=$(jq -c '.area' "$CFG")
  
  HOURS=$(seq -f "%02g:00" 0 23 | jq -R . | jq -s -c .)

  echo "$PERIODS" | while IFS='|' read -r YEAR MONTH DAYS; do
    printf "[INFO] Processing period: $YEAR-$MONTH \n"
    
    for key in $DATASETS; do
      PRODUCT=$(jq -r ".datasets.$key.name" "$CFG")
      SUFFIX=$([[ "$key" == "pressure" ]] && echo "PRES" || echo "SFC")
      OUTFILE="${SUFFIX}_${YEAR}_${MONTH}.GRIB"
      
      if [ -f "$DATA_DIR/$OUTFILE" ]; then
        printf "\n[INFO] File already exists, skipping download: $OUTFILE"
        continue
      fi

      REQUEST=$(jq -c \
        --argjson area "$AREA" \
        --argjson days "$DAYS" \
        --argjson hours "$HOURS" \
        --arg yr "$YEAR" \
        --arg mo "$MONTH" \
        --arg key "$key" \
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
        
      curl -X 'DELETE' -s \
        -o /dev/null \
        "$BASE_URL/jobs/$JOB_ID?allow_unauthenticated=false" \
        -H 'accept: application/json' \
        -H "PRIVATE-TOKEN: $KEY"

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

# --- 3. Convert GRIB Files to ARL ----------------------------------------------------
if [ "$CONVERT" = true ]; then
  FILES=($(ls $DATA_DIR | grep \.GRIB | awk -F '[_.]' '{print $2"_"$3}' | sort -u))

  if [ ${#FILES[@]} -eq 0 ]; then
    echo "[ERROR] No GRIB files found in $DATA_DIR"
    exit 1
  fi

  printf "\n--- Converting GRIB files to ARL---\n"

  for file in "${FILES[@]}"; do
    IFS='_' read -r year month <<< "$file"
    printf "processing file: $file (year: $year, month: $month)\n"

    PRES_FILE="PRES_${year}_${month}.GRIB"
    SURF_FILE="SFC_${year}_${month}.GRIB"
    OUT_FILE="MET_${file}.ARL"

    if [ -f "$DATA_DIR/$OUT_FILE" ]; then
      printf "[INFO] $OUT_FILE already exists, skipping conversion\n"
      continue
    fi

    if [[ ! -f "$DATA_DIR/$PRES_FILE" || ! -f "$DATA_DIR/$SURF_FILE" ]]; then
        printf "[ERROR] Missing files for %s. Check %s or %s\n" "$file" "$PRES_FILE" "$SURF_FILE"
        continue
    fi

    LD_LIBRARY_PATH="$PROJECT_DIR/deps/eccodes/lib:$LD_LIBRARY_PATH" \
    cd $RUN_DIR
    ./era52arl -v \
      -i"$DATA_DIR/$PRES_FILE" \
      -a"$DATA_DIR/$SURF_FILE" \
      -o"$DATA_DIR/$OUT_FILE"

    [[ $? -eq 0 ]] && printf "[OK] $OUT_FILE successfully saved in $DATA_DIR\n"
  done

  cd "$PROJECT_DIR"
fi

# --- 4. SETUP.CFG ----------------------------------------------------------------
TCL_SRC="$PROJECT_DIR/build/hysplit/guicode/traj_cfg.tcl"
OUTPUT_CFG="$RUN_DIR/SETUP.CFG"
ACTIVE_VARS=" $(jq -r 'try(.output | join(" ")) catch empty' "$CFG") "

declare -A SETUP_VARS
while read -r k v; do
  if [[ -n "$k" ]]; then
    SETUP_VARS["$k"]="$v"
  fi
done < <(jq -r 'try(.setup | to_entries[] | "\(.key) \(.value)") catch empty' "$CFG")

if [[ -n $ACTIVE_VARS || ${#SETUP_VARS[@]} -gt 0 ]]; then
  {
    echo "&SETUP"

    sed -n '/proc reset_config/,/}/p' "$TCL_SRC" | grep "^set" | while read -r _ key val; do
      
      if [[ $key =~ ^(tset|delt)$ ]]; then
        continue
      fi

      if [[ $ACTIVE_VARS == *" $key "* ]]; then
        val=1
      fi 

      if [[ -n ${SETUP_VARS[$key]} ]]; then
        val=${SETUP_VARS[$key]}
      fi
      
      echo $key = $val,
    done

    echo "/"
  } > "$OUTPUT_CFG"
  cp "$OUTPUT_CFG" "$HYSPLIT_EXEC/"
fi

# --- 5. CONTROL file and model execution ------------------------------------------------

CONTROL_SRC="$RUN_DIR/CONTROL"
CONTROL_DST="$HYSPLIT_EXEC/CONTROL"

POINTS=$(jq -r '.control.points[] | "\(.lat) \(.lon) \(.height)"' "$CFG")
NUM_POINTS=$(echo "$POINTS" | wc -l)
VERT_METHOD=$(jq -r '.control.vertical_method' "$CFG")
TOP_MODEL=$(jq -r '.control.top_model' "$CFG")
DURATION=$(jq -r '.duration' "$CFG")
TR_INTERVAL=$(jq -r '.interval_traj // 24' "$CFG")

T_START=$(date -u -d "$START_DATE" +%s)
T_END=$(date -u -d "$END_DATE" +%s)

if [[ $T_START -gt $T_END ]]; then
  DIRECTION=-1
  LOWER=$T_END
  UPPER=$T_START
else
  DIRECTION=1
  LOWER=$T_START
  UPPER=$T_END
fi

if [[ $DIRECTION -eq -1 ]]; then
  MIN_VALID_LAUNCH=$(( LOWER + (DURATION * 3600) ))
  if [[ $LOWER -lt $MIN_VALID_LAUNCH ]]; then
    LOWER=$MIN_VALID_LAUNCH
    printf "[INFO] Duration exceeds valid range. New end date: %s\n" "$(date -u -d "@$LOWER" +'%Y-%m-%d %H:%M:%S')"
  fi
else
  MAX_VALID_LAUNCH=$(( UPPER - (DURATION * 3600) ))
  if [[ $UPPER -gt $MAX_VALID_LAUNCH ]]; then
    UPPER=$MAX_VALID_LAUNCH
    printf "[INFO] Duration exceeds valid range. New start date: %s\n" "$(date -u -d "@$UPPER" +'%Y-%m-%d %H:%M:%S')"
  fi
fi

for (( current=LOWER; current<=UPPER; current+=$((TR_INTERVAL * 3600)) )); do  
  TIME="$(date -u -d "@$current" +'%Y_%m_%d_%H')"
  END_SEC=$(( current + (DIRECTION * DURATION * 3600) ))

  if [[ $current -lt $END_SEC ]]; then
    SIM_START=$current
    SIM_END=$END_SEC
  else
    SIM_START=$END_SEC
    SIM_END=$current
  fi

  Y_CURR=$(date -u -d "@$SIM_START" +%Y)
  M_CURR=$(( 10#$(date -u -d "@$SIM_START" +%m) ))
  Y_END=$(date -u -d "@$SIM_END" +%Y)
  M_END=$(( 10#$(date -u -d "@$SIM_END" +%m) ))

  MET_STRING=""

  while [[ $Y_CURR -lt $Y_END || ( $Y_CURR -eq $Y_END && $M_CURR -le $M_END ) ]]; do
    printf -v MM "%02d" $M_CURR
    MET_STRING+="MET_${Y_CURR}_${MM}.ARL "
    
    ((M_CURR++))
    if (( M_CURR > 12 )); then
      M_CURR=1
      ((Y_CURR++))
    fi
  done

  NUM_MET=$(echo "$MET_STRING" | wc -w)

  MET_FILES=()
  for f in $MET_STRING; do
    if [[ ! -f "$DATA_DIR/$f" ]]; then
      printf "[ERROR] File not found: %s/%s\n" "$DATA_DIR" "$f"
      exit 1
    fi
    MET_FILES+=("$f")
  done

  {
    echo "$(date -u -d "@$current" +'%y %m %d %H')"
    echo "$NUM_POINTS"
    echo "$POINTS"
    echo "$(( $DIRECTION * $DURATION ))"
    echo "$VERT_METHOD"
    echo "$TOP_MODEL"
    echo "$NUM_MET"
    
    for f in "${MET_FILES[@]}"; do
      echo "$DATA_DIR/"
      echo "$f"
    done

    echo "$OUTPUT_DIR/"
    echo "traj_${TIME}.txt"
  } > "$CONTROL_SRC"

  printf "[INFO] Executing HYSPLIT for $(date -u -d "@$current" +'%Y-%m-%d %H:%M:%S')\n"

  cp "$CONTROL_SRC" "$CONTROL_DST"
  cd "$HYSPLIT_EXEC" && ./hyts_std > "output.log" 2>&1
  mv "output.log" "$RUN_DIR/output.log"
  cd "$PROJECT_DIR"

done

printf "[OK] All simulations completed successfully\n"