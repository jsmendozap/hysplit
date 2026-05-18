# HYSPLIT & ERA5 Automated Workflow

This project provides an automated workflow to configure, install, and execute the **HYSPLIT** dispersion and trajectory model (NOAA) using **ERA5** reanalysis meteorological data (Copernicus).

The workflow is designed to run entirely on a **Linux environment** and consists of three main phases:

1. **Project structure and compilation**: A bash script configures:

- The project structure
- Downloads and compiles HYSPLIT and data2arl along with their corresponding dependencies.
- Downloads the `run.sh` script.

2. **Configuration**: Using R as the entry point, the user defines the spatial study area, receptor/emitter points, and specify variables and time periods to generate a `config.json` file.

3. **Execution**: A pipeline automatically downloads ERA5 data via the Copernicus API, converts it to ARL format, and executes HYSPLIT.

---

## Requirements

### Linux Environment

- **R** with the following libraries: `tidyverse`, `sf`, `jsonlite` (and optionally `rnaturalearth`).
- **Compilers**: `gfortran`, `gcc`, `g++`, `cmake`
- **Copernicus API Token**: Inside a `.env` file containing `KEY=private_token_here` at the root of the project directory.

---

## Step-by-Step Workflow

### Phase 1: Project Initialization (`setup.sh`)

The `setup.sh` script installs everything. It creates the workspace, compiles `eccodes`, the HYSPLIT core, and `era52arl`.

```bash
chmod +x setup.sh
./setup.sh --project simulation
```

### Phase 2: Configuration (`main.R`)

The `main.R` script acts as the entry point for the project. In this file, the simulation parameters are defined and saved into a `config.json` file. **This file must be stored in the project's root directory** (e.g., inside the newly created `simulation` folder).

_Note for Backward Trajectories: `date.start` is chronologically newer than `date.end`._

### Phase 3: Download & Execution (`run.sh`)

In the project folder, the `run.sh` script has already been downloaded into it by the setup process. Now, simply trigger the download and computation phases.

```bash
cd simulation

# Start the API download, conversion, and HYSPLIT simulation
./run.sh --download

# Alternatively, if data is already inside data/, just run:
# ./run.sh
```

---

## Project Structure

After running the setup and run scripts, the project folder will mirror this structure:

- `build/`: Extracted source codes (HYSPLIT, data2arl).
- `deps/`: Compiled dependencies natively built on your server (e.g., `eccodes`).
- `data/`: Raw `.GRIB` downloads from Copernicus and their converted `.ARL` counterparts.
- `tarballs/`: Cached source archives (to prevent re-downloading source code).
- `run/`: Your active execution environment (contains generated `CONTROL`, `SETUP.CFG` files).
- `output/`: Final HYSPLIT trajectory results (`traj_out_*.txt`).

---

## Important Notes on Data Processing

- **Monthly Execution Logic:** The workflow is fundamentally designed to operate on a strict **monthly basis**. Regardless of the total duration of the study defined during configuration, the pipeline always downloads ERA5 data, performs ARL format conversions, and executes HYSPLIT in discrete monthly chunks.

- **File Naming Conventions:** If the download phase is skipped (e.g., by manually providing pre-downloaded GRIB or ARL data inside the `data/` directory), the files **must** adhere to a strict naming pattern. Failing to match these patterns will result in execution errors:
  - **GRIB files:** Must be formatted as `<output_prefix>_YYYY_MM.GRIB` (e.g., `PRES_2025_01.GRIB`). The prefix must exactly match the output string defined for each dataset in the `config.json` file.
  - **ARL files:** Converted meteorological files must be formatted as `MET_YYYY_MM.ARL` (e.g., `MET_2025_01.ARL`).

---

## Credits

The generation of the `era52arl.cfg` mappings relies on the `era5utils.py` script provided by the [hysplit_metdata repository](https://github.com/hysplit/hysplit_metdata).
