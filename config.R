library(jsonlite)
library(sf)

#' Setup HYSPLIT Project Configuration
#'
#' @description Generates a `config.json` file to configure the HYSPLIT simulation parameters.
#'
#' @param path Character string. The file path where `config.json` will be saved.
#' @param date.start Character string. The start date and time of the simulation.
#' @param date.end Character string. The end date and time of the simulation.
#' @param bbox An object of class `bbox` (from `sf` package) defining the spatial bounding box for ERA5 data.
#' @param points A `data.frame` with columns `lat`, `lon`, and `height` defining the receptor/emitter points.
#' @param top.model Numeric. The top of the model domain (in meters).
#' @param vertical.method Numeric. The vertical motion calculation method.
#' @param download Logical. Whether to include the datasets section for downloading ERA5 data. Default is `TRUE`.
#' @param pres.levels Numeric vector. The pressure levels to download. Default levels: from 100 to 1000 hPa.
#' @param pres.vars Character vector. Additional pressure level variables to include. The basic variables required by the software for the GRIB to ARL conversion are automatically included by default, but additional variables can be added to the final file.
#' @param sfc.vars Character vector. Additional surface level variables to include. The basic variables required by the software for the GRIB to ARL conversion are automatically included by default, but additional variables can be added to the final file.
#' @param setup Optional named string vector. Advanced HYSPLIT setup parameters. For a full list of available parameters and their descriptions, see \url{https://www.ready.noaa.gov/hysplitusersguide/S410.htm}.
#' @param output.vars list. Specific meteorological variables to output along the trajectory. Possible values include:
#' \itemize{
#'   \item \code{"tm_tpot"}: Potential temperature
#'   \item \code{"tm_tamb"}: Ambient temperature
#'   \item \code{"tm_rain"}: Precipitation
#'   \item \code{"tm_mixd"}: Mixing depth
#'   \item \code{"tm_relh"}: Relative humidity
#'   \item \code{"tm_sphu"}: Specific humidity
#'   \item \code{"tm_mixr"}: Water vapor mixing ratio
#'   \item \code{"tm_dswf"}: Solar radiation
#'   \item \code{"tm_terr"}: Terrain height
#'   \item \code{"tm_uwnd"}: U-component of wind
#'   \item \code{"tm_vwnd"}: V-component of wind
#' }
#'

project_setup <- function(path,
                          date.start,
                          date.end,
                          bbox,
                          points,
                          top.model,
                          vertical.method,
                          download = T,
                          pres.levels = c(seq(100, 250, 25), seq(300, 750, 50), seq(775, 1000, 25)),
                          pres.vars = NULL,
                          sfc.vars = NULL,
                          setup = NULL,
                          output.vars = NULL) {
  if (!inherits(bbox, "bbox")) stop("bbox must be of class 'bbox'")

  if (!inherits(points, "data.frame") || dim(points)[2] != 3 || !all(c("lat", "lon", "height") %in% names(points))) {
    stop("Points must be a data.frame with columns: lat, lon, height.")
  }

  out.vars <- c("tm_tpot", "tm_tamb", "tm_rain", "tm_mixd", "tm_relh", "tm_sphu", "tm_mixr", "tm_dswf", "tm_terr", "tm_uwnd", "tm_vwnd")
  if (!is.null(output.vars) && !all(output.vars %in% out.vars)) {
    stop("Output variables must be one of: ", paste(out.vars, collapse = ", "))
  }

  config <- list(
    date_start = date.start,
    date_end = date.end,
    area = c(bbox$ymax, bbox$xmin, bbox$ymin, bbox$xmax),
    control = list(
      vertical_method = vertical.method,
      top_model = top.model,
      points = points
    )
  )

  if (download) {
    config$datasets <- list(
      pressure = list(
        name = "reanalysis-era5-pressure-levels",
        pressure_levels = pres.levels,
        variables = c(
          "geopotential",
          "u_component_of_wind",
          "v_component_of_wind",
          "temperature",
          "relative_humidity",
          "vertical_velocity",
          pres.vars
        ) |> unique()
      ),
      surface = list(
        name = "reanalysis-era5-single-levels",
        variables = c(
          "geopotential",
          "10m_u_component_of_wind",
          "10m_v_component_of_wind",
          "2m_temperature",
          sfc.vars
        ) |> unique()
      )
    )
  }

  if (!is.null(setup)) config$setup <- setup
  if (!is.null(output.vars)) config$output <- output.vars

  write_json(x = config, path = path, pretty = T, auto_unbox = T)
}
