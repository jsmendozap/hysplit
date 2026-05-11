library(tidyverse)
library(qgisprocess)
library(sf)

qgis <- qgis_project()

######### Study region #################

col <- rnaturalearth::ne_countries() %>% 
	select(name) %>%
	filter(name == "Colombia") %>%
	st_geometry()

amazonian <- st_read('Amazonian.parquet') %>%
	st_make_valid() %>%
	st_geometry()

amazonian_col <- st_intersection(col, amazonian)
rm(col, amazonian)

######### Receptor points ################

qgis_get_argument_specs("native:randompointsinpolygons")

qgis_run_algorithm(
		"native:randompointsinpolygons",
		INPUT = st_sf(amazonian_col),
		POINTS_NUMBER = 500,
		MIN_DISTANCE = 0.25,
		SEED = 1, 
		OUTPUT = "points.parquet"
)

points <- st_read("points.parquet")
qgis$insert_layer(points, 'points')


######### Control file ################

points <- st_coordinates(points) %>%
	as_tibble() %>%
	crossing(alt = c(300, 500, 1500)) %>%
	select(lat = Y, long = X, alt)

n <- nrow(points)

file <- "CONTROL"

# Initial date: YY MM DD HH
cat("26 04 10 23\n", file = file)

# Total points
cat(n, "\n", file = file, append = TRUE)

# Locations 
write.table(points, file = file, append = TRUE, 
            col.names = FALSE, row.names = FALSE, quote = FALSE, sep = " ")

# Duration (hours) - Negative (Backward) or Positive (Forward)
cat("-239\n", file = file, append = TRUE)

# Vertical Motion Method [0-8]
cat("0\n", file = file, append = TRUE)

# Top of the model (meters)
cat("15000.0\n", file = file, append = TRUE) 

# Number of meteorological files
cat("1\n", file = file, append = TRUE)

# Path to meteorological file
cat("<<OUTPUT_DIR>>\n", file = file, append = TRUE)

# Name of meteorological file
cat("MET.ARL\n", file = file, append = TRUE) 

# Output path
cat("../../../output/\n", file = file, append = TRUE)     

# Output filename
cat("trajectories\n", file = file, append = TRUE)

