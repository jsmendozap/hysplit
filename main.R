library(tidyverse)
library(sf)

source("https://raw.githubusercontent.com/jsmendozap/hysplit/main/config.R")

######### Study region ###################

url <- "https://data.hydrosheds.org/file/HydroBASINS/standard/hybas_sa_lev03_v1c.zip"
amazonian <- st_read(paste0("/vsizip/vsicurl/", url)) %>%
  filter(HYBAS_ID == 6030007000) %>%
  st_make_valid() %>%
  st_geometry()

col <- rnaturalearth::ne_countries() %>%
  select(name) %>%
  filter(name == "Colombia") %>%
  st_geometry()

amazonian_col <- st_intersection(col, amazonian)
rm(col, amazonian, url)


######### Configuration file ################

START_DATE <- "2026-02-05 00:00:00"
END_DATE <- "2026-01-25 00:00:00"
DURATION <- 240
N <- 100
HEIGHTS <- c(300, 500, 1500)
CONFIG_PATH <- "/Users/juan/Desktop/config.json"
AOI <- st_bbox(c(xmin = -85, ymin = -25, xmax = -30, ymax = 15))
TOP_MODEL <- 10000
VERTICAL_METHOD <- 0
INTERVAL_TRAJ <- 6
OUTPUT_VARS <- list("tm_sphu")
PRES_VARS <- "specific_humidity"
SFC_VARS <- c(
  "boundary_layer_height",
  "surface_sensible_heat_flux",
  "surface_latent_heat_flux",
  "total_precipitation",
  "surface_pressure"
)

POINTS <- st_sample(x = amazonian_col, type = "random", size = N) %>%
  st_coordinates() %>%
  as.data.frame() %>%
  crossing(height = HEIGHTS) %>%
  select(lat = Y, lon = X, height)

project_setup(
  path = CONFIG_PATH,
  date.start = START_DATE,
  date.end = END_DATE,
  duration = DURATION,
  bbox = AOI,
  points = POINTS,
  top.model = TOP_MODEL,
  vertical.method = VERTICAL_METHOD,
  interval.traj = INTERVAL_TRAJ,
  output.vars = OUTPUT_VARS,
  pres.vars = PRES_VARS,
  sfc.vars = SFC_VARS
)
