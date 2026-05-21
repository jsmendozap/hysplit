#!/bin/bash
# =============================================================================
# setup.sh — Download and installation of HYSPLIT + era52arl
# Usage:
#   ./setup.sh --project my_run --config ./config.json             
#   ./setup.sh --skip-download  
# =============================================================================

set -e  # exit on error

# --- Parse flags ---------------------------------------------------------
PROJECT_NAME=""
SKIP_DOWNLOAD=false

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --skip-download) SKIP_DOWNLOAD=true; shift ;;
    --project) PROJECT_NAME="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# --- Configuration -----------------------------------------------------------
if [ -n "$PROJECT_NAME" ]; then
  PROJECT_DIR="$PWD/$PROJECT_NAME"
else
  PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

DEPS_DIR="$PROJECT_DIR/deps"
BUILD_DIR="$PROJECT_DIR/build"
OUTPUT_DIR="$PROJECT_DIR/output"
DATA_DIR="$PROJECT_DIR/data"
TARBALLS_DIR="$PROJECT_DIR/tarballs"
RUN_DIR="$PROJECT_DIR/run"

# --- Create project structure ------------------------------------------------
mkdir -p "$DEPS_DIR" "$BUILD_DIR" "$OUTPUT_DIR" "$DATA_DIR" "$TARBALLS_DIR" "$RUN_DIR" "$RUN_DIR/log"


# --- Functions ---------------------------------------------------------------

check_compilers() {
  printf "\n--- Verifying compilers and system dependencies ---\n"

  local required=(gfortran gcc cmake g++ unzip tar curl jq sed)
  local optional=(mpich tcl tk)
  local missing_required=()
  local missing_optional=()

  for cmd in "${required[@]}"; do
    if command -v "$cmd" &>/dev/null; then
      printf "\n[OK] $cmd"
    else
      printf "\n[ERROR] $cmd not found"
      missing_required+=("$cmd")
    fi
  done

  for cmd in "${optional[@]}"; do
    if command -v "$cmd" &>/dev/null; then
      printf "\n[OK] $cmd"
    else
      printf "\n[WARN] $cmd not found (optional)"
      missing_optional+=("$cmd")
    fi
  done

  if [ ${#missing_required[@]} -gt 0 ]; then
    echo "Required compilers missing: ${missing_required[*]}"
    echo "Please install them before continuing."
    exit 1
  fi

  if [ ${#missing_optional[@]} -gt 0 ]; then
    printf "\nOptional dependencies missing: ${missing_optional[*]}"
    echo "Some features may not work without them."
  fi
}


download_files() {

  HYSPLIT_URL="https://www.ready.noaa.gov/data/web/models/hysplit4/linux_trial/hysplit.v5.4.2_UbuntuOS20.04.6LTS_public.tar.gz"
  ERA52ARL_URL="https://www.ready.noaa.gov/data/web/models/hysplit4/decoders/hysplit_data2arl.zip"
  ECCODES_URL="https://github.com/ecmwf/eccodes/archive/refs/tags/2.47.0.tar.gz"
  HYSPLIT_METDATA_URL="https://www.ready.noaa.gov/data/web/models/hysplit4/decoders/hysplit_metdata.tar.gz"

  if [ "$SKIP_DOWNLOAD" = true ]; then
    printf "\n--- Skipping download, using tarballs in $TARBALLS_DIR ---\n"
    return
  fi

  printf "\n--- Downloading tarballs ---\n"

  local -A files=(
    ["hysplit.tar.gz"]="$HYSPLIT_URL"
    ["hysplit_data2arl.zip"]="$ERA52ARL_URL"
    ["eccodes.tar.gz"]="$ECCODES_URL"
    ["hysplit_metdata.tar.gz"]="$HYSPLIT_METDATA_URL"
  )

  for filename in "${!files[@]}"; do
    if [ -f "$TARBALLS_DIR/$filename" ]; then
      printf "\n[OK] $filename already exists, skipping"
    else
      echo "Downloading $filename..."
      curl -L --progress-bar -o "$TARBALLS_DIR/$filename" "${files[$filename]}"
    fi
  done
  
  printf "\n[OK] Tarballs downloaded"
}


extract_files() {
  printf "\n--- Extracting files ---\n"

  if [ -d "$BUILD_DIR/hysplit" ]; then
    printf "\n[OK] hysplit already extracted, skipping"
  else
    local hysplit_root
    hysplit_root=$(tar -tzf "$TARBALLS_DIR/hysplit.tar.gz" | head -1 | cut -d'/' -f1)
    tar -xzf "$TARBALLS_DIR/hysplit.tar.gz" -C "$BUILD_DIR"
    mv "$BUILD_DIR/$hysplit_root" "$BUILD_DIR/hysplit"
    printf "\n[OK] hysplit extracted to $BUILD_DIR/hysplit"
  fi

  if [ -d "$BUILD_DIR/data2arl" ]; then
    printf "\n[OK] data2arl already extracted, skipping"
  else
    local data2arl_root
    data2arl_root=$(unzip -Z1 "$TARBALLS_DIR/hysplit_data2arl.zip" | head -1 | cut -d'/' -f1)
    unzip -q "$TARBALLS_DIR/hysplit_data2arl.zip" -d "$BUILD_DIR"
    mv "$BUILD_DIR/$data2arl_root" "$BUILD_DIR/data2arl"
    printf "\n[OK] data2arl extracted to $BUILD_DIR/data2arl"
  fi
  
  printf "\n[OK] Tarballs extracted successfully"
}


install_eccodes() {
  local ECCODES_SRC="$DEPS_DIR/eccodes_src"
  local ECCODES_BUILD="$DEPS_DIR/eccodes_build"
  local ECCODES_INSTALL="$DEPS_DIR/eccodes"

  if [ -f "$ECCODES_INSTALL/lib/libeccodes.so" ]; then
    printf "\n[OK] eccodes already installed in $ECCODES_INSTALL, skipping"
    return
  fi

  printf "\n--- Compiling eccodes ---\n"
  mkdir -p "$ECCODES_SRC" "$ECCODES_BUILD"

  tar -xzf "$TARBALLS_DIR/eccodes.tar.gz" -C "$ECCODES_SRC" --strip-components=1

  cd "$ECCODES_BUILD"
  cmake "$ECCODES_SRC" \
    -DCMAKE_INSTALL_PREFIX="$ECCODES_INSTALL" \
    -DENABLE_FORTRAN=ON \
    -DENABLE_NETCDF=OFF \
    -DENABLE_JPG=OFF \
    -DENABLE_AEC=OFF \
    -DBUILD_SHARED_LIBS=ON

  make -j"$(nproc)"
  make install

  rm -rf "$ECCODES_SRC" "$ECCODES_BUILD"
  cd "$PROJECT_DIR"
  printf "\n[OK] eccodes installed in $ECCODES_INSTALL"
}


setup_makefile() {
  local SRC="$BUILD_DIR/data2arl/Makefile.inc.gfortran"
  local DST="$BUILD_DIR/data2arl/Makefile.inc"
  local ERA_MK="$BUILD_DIR/data2arl/era52arl/Makefile"

  printf "\n--- Setting up eccodes path in Makefile.inc---\n"

  cp "$SRC" "$DST"

  sed -i \
    -e "s|^#ECCODES_TOPDIR=.*|ECCODES_TOPDIR= $DEPS_DIR/eccodes|" \
    -e "s|^#ECCODESINC=.*|ECCODESINC= -I$DEPS_DIR/eccodes/include|" \
    -e "s|^#ECCODESLIBS=.*|ECCODESLIBS= -L$DEPS_DIR/eccodes/lib -leccodes_f90 -leccodes|" \
    "$DST"

  printf "\n--- Setting up eccodes binary path in era52arl/Makefile ---\n"
  sed -i \
    -e "s|/usr/lib/x86_64-linux-gnu/libeccodes_f90\.so|$DEPS_DIR/eccodes/lib/libeccodes_f90.so|" \
    -e "s|/usr/lib/x86_64-linux-gnu/libeccodes\.so|$DEPS_DIR/eccodes/lib/libeccodes.so|" \
    "$ERA_MK"

  printf "\n[OK] Makefile configured successfully"
}


compile_library() {
  local LIB_DIR="$BUILD_DIR/data2arl/metprog/library"
  local LIBRARY="$LIB_DIR/libhysplit.a"

  if [ -f "$LIBRARY" ]; then
    printf "\n[OK] libhysplit already compiled, skipping"
    return
  fi

  printf "\n--- Compiling libhysplit ---\n"
  cd "$LIB_DIR"
  make

  if [ ! -f "$LIBRARY" ]; then
    printf "\n[ERROR] Compilation failed — libhysplit.a not found"
    exit 1
  fi

  cd "$PROJECT_DIR"
  printf "\n[OK] libhysplit compiled"
}


compile_era52arl() {
  local ERA_DIR="$BUILD_DIR/data2arl/era52arl"
  local BINARY="$ERA_DIR/era52arl"

  if [ -f "$BINARY" ]; then
    printf "\n[OK] era52arl already compiled, skipping"
    return
  fi

  printf "\n--- Compiling era52arl ---\n"
  cd "$ERA_DIR"
  make

  if [ ! -f "$BINARY" ]; then
    printf "\n[ERROR] Compilation failed — binary not found"
    exit 1
  fi

  cd "$PROJECT_DIR"
  printf "\n[OK] era52arl compiled"
}


era52arl_cfg() {
  local URL="https://raw.githubusercontent.com/amcz/hysplit_metdata/master/era5utils.py"

  if [ -f "$BUILD_DIR/era5utils.py" ]; then
    printf "\n[OK] era5utils.py already exists, skipping"
  else
    printf "\n--- Downloading era5utils.py ---\n"
    curl -L --progress-bar -o "$BUILD_DIR/era5utils.py" "$URL"

    printf "\n[OK] era5utils.py downloaded successfully"
  fi
}


setup_run_dir() {
  printf "\n--- Creating run directory ---\n"
  ln -sf "$BUILD_DIR/data2arl/era52arl/era52arl" "$RUN_DIR/era52arl"
}


# --- Execution ---------------------------------------------------------------

check_compilers
download_files
extract_files
install_eccodes
setup_makefile
compile_library
compile_era52arl
era52arl_cfg
setup_run_dir

curl -L --progress-bar \
      -o "$PROJECT_DIR/run.sh" \
      "https://raw.githubusercontent.com/jsmendozap/hysplit/main/run.sh"

chmod +x "$PROJECT_DIR/run.sh"

printf "\n=== Installation complete ===\n"
rm -- "$0" 