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

DURATION=$(jq -r '.duration' "$CFG")
T_START=$(date -u -d "$START_DATE" +%s)
T_END=$(date -u -d "$END_DATE" +%s)

if [[ $T_START -gt $T_END ]]; then
  DIRECTION=-1
  SIM_LOWER=$T_END
  SIM_UPPER=$T_START
else
  DIRECTION=1
  SIM_LOWER=$T_START
  SIM_UPPER=$T_END
fi

if [[ $DIRECTION -eq -1 ]]; then
  MET_LOWER=$(( SIM_LOWER - (DURATION * 3600) ))
  MET_UPPER=$SIM_UPPER
else
  MET_LOWER=$SIM_LOWER
  MET_UPPER=$(( SIM_UPPER + (DURATION * 3600) ))
fi

MET_START_DATE=$(date -u -d "@$MET_LOWER" +'%Y-%m-%d %H:%M:%S')
MET_END_DATE=$(date -u -d "@$MET_UPPER" +'%Y-%m-%d %H:%M:%S')

printf "[INFO] Simulation window: %s to %s\n" "$(date -u -d "@$SIM_LOWER" +'%Y-%m-%d %H:%M:%S')" "$(date -u -d "@$SIM_UPPER" +'%Y-%m-%d %H:%M:%S')"
printf "[INFO] Data window required: %s to %s\n" "$MET_START_DATE" "$MET_END_DATE"

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

start = datetime.strptime("$MET_START_DATE", '%Y-%m-%d %H:%M:%S')
end = datetime.strptime("$MET_END_DATE", '%Y-%m-%d %H:%M:%S')

curr = start
chunk_size = 11

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
  days = [days[i:i + chunk_size] for i in range(0, len(days), chunk_size)]
  
  for chunk in range(0, len(days)): 
    n_chunks = len(days)
    dates = days[chunk]
    print(f"{y}|{m:02d}|{chunk + 1}|{n_chunks}|{json.dumps(dates)}")

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

  echo "$PERIODS" | while IFS='|' read -r YEAR MONTH CHUNK N_CHUNKS DAYS; do
    printf "[INFO] Processing period: $YEAR-$MONTH (part ${CHUNK}/${N_CHUNKS})\n"

    for key in $DATASETS; do
      PRODUCT=$(jq -r ".datasets.$key.name" "$CFG")
      SUFFIX=$([[ "$key" == "pressure" ]] && echo "PRES" || echo "SFC")
      OUTFILE="${SUFFIX}_${YEAR}_${MONTH}_${CHUNK}_${N_CHUNKS}.GRIB"
      
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

        printf "[%s] Status: %s\033[0K\n" "$PRODUCT" "$STATUS"

        [ "$STATUS" = "successful" ] && break
        [ "$STATUS" = "failed" ]     && echo "[ERROR] Job $PRODUCT failed: $JOB_ID" && exit 1

        secs=300
        while (( secs > 0 )); do
          printf "Retry download in %02d:%02d\033[0K\r" $((secs / 60)) $((secs % 60))
          sleep 1
          ((secs--))
        done
      done

      DOWNLOAD_URL=$(curl -X 'GET' \
        "$BASE_URL/jobs/$JOB_ID/results?allow_unauthenticated=false" \
        -H "accept: application/json" \
        -H "PRIVATE-TOKEN: $KEY" \
        | jq -r '.asset.value.href')

      printf "\n"

      curl -L --progress-bar \
        -H "PRIVATE-TOKEN: $KEY" \
        -o "$DATA_DIR/$OUTFILE" \
        "$DOWNLOAD_URL"
        
      curl -X 'DELETE' -s \
        -o /dev/null \
        "$BASE_URL/jobs/$JOB_ID?allow_unauthenticated=false" \
        -H 'accept: application/json' \
        -H "PRIVATE-TOKEN: $KEY"

      printf "[OK] $OUTFILE downloaded successfully \n"
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
var2d = {v[4]: k for k,v in sname.items() if len(v) >= 4 and v[4] and k != 'HGTS'}

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
  printf "[OK] era52arl.cfg saved in $RUN_DIR \n"
else
  echo "[ERROR] Failed to write era52arl.cfg"
  exit 1
fi

# --- 3. Convert GRIB Files to ARL ----------------------------------------------------
if [ "$CONVERT" = true ]; then
  FILES=( $(ls $DATA_DIR | grep -i \.grib$ | cut -d'_' -f2- | sort -u | sed 's/\.grib$//I') )

  if [ ${#FILES[@]} -eq 0 ]; then
    echo "[ERROR] No GRIB files found in $DATA_DIR"
    exit 1
  fi

  printf "\n--- Starting conversion of GRIB files to ARL---\n"

  for file in "${FILES[@]}"; do
    IFS='_' read -r year month chunk n_chunks <<< "$file"
    printf "[INFO] Processing year: $year, month: $month, chunk: $chunk/$n_chunks\n"

    PRES_FILE="PRES_${year}_${month}_${chunk}_${n_chunks}.GRIB"
    SURF_FILE="SFC_${year}_${month}_${chunk}_${n_chunks}.GRIB"
    OUT_FILE="MET_${year}_${month}_${chunk}_${n_chunks}.ARL"

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
TR_INTERVAL=$(jq -r '.interval_traj // 24' "$CFG")

for (( current=SIM_LOWER; current<=SIM_UPPER; current+=$((TR_INTERVAL * 3600)) )); do  
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
    
    AVAILABLE_CHUNKS=$(find "$DATA_DIR" -maxdepth 1 -name "MET_${Y_CURR}_${MM}_*.ARL" -printf "%f\n" 2>/dev/null | sort -V)
    
    if [[ -z "$AVAILABLE_CHUNKS" ]]; then
      printf "[ERROR] No ARL files found for %s-%s\n" "$Y_CURR" "$MM"
      exit 1
    fi

    for chunk in $AVAILABLE_CHUNKS; do
      MET_STRING+="$chunk "
    done
    
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
  mv "output.log" "$RUN_DIR/log/output_${TIME}.log"
  cd "$PROJECT_DIR"

done

printf "[OK] All simulations completed successfully\n"