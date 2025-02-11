### This file downloads all the station data from the NOAA's http servers and saves them to compressed rds files
library(here)
library(progressr)
library(dplyr)
library(tidyr)
library(purrr)
library(furrr)
library(lubridate)
library(stringr)
library(readr)


build_station_url <- function(station_id){
  paste0(
    "https://www1.ncdc.noaa.gov/pub/data/normals/1981-2010/products/auxiliary/station/",
    station_id,
    ".normals.txt"
  )
}

check_for_data <- function(station_text, data_id){
  # If we're missing the data field dont bother trying to find it
  id_missing <- !str_detect(string = station_text, pattern = data_id)
  if(id_missing){
    stop("Data not in provided station text")
  }
}

# Extract temperature info from the station text
get_temp_data <- possibly(
  function(station_text){
    c("dly-tmax-normal", "dly-tavg-normal", "dly-tmin-normal") %>%
      purrr::map_dfr(extract_month_level_data, file_lines = station_text) %>%
      mutate(type = str_remove_all(type, "dly-t|-normal"),
             # Results are given in tenths of a degree so we need to divide by 10
             # See https://www1.ncdc.noaa.gov/pub/data/normals/1981-2010/readme.txt
             value = value/10) %>%
      pivot_wider(names_from = c(type), values_from = c(value))
  },
  otherwise = NULL)

# Extract temperature info from the station text
get_prcp_data <- possibly(
  function(station_text){

    check_for_data(station_text, "mly-prcp-normal")

    months_prcp_avgs <- station_text %>%
      stringr::str_extract("(?<=mly-prcp-normal)((.|\\\n)*?)(?=\n)") %>%
      str_trim() %>%
      str_remove_all("[A-Z]") %>%
      str_split("\\s+") %>%
      pluck(1) %>%
      as.numeric()

    tibble(date = twelve_month_seq,
           # Data reported as 100ths of an inch
           # -7777 is used to denote a value that rounds to 0 but is not technically zero
           avg_precipitation = ifelse(months_prcp_avgs == -7777, 0, months_prcp_avgs/100))
  },
  otherwise = NULL)



# Look through raw text downloaded from NOAA servers for a given station and
# extract the table for the desired data_id text as a dataframe
extract_month_level_data <- function(data_id, file_lines){
  check_for_data(file_lines, data_id)

  file_lines %>%
    # A semi hairy regex to extract block of relevant data
    stringr::str_extract(paste0("(?<=", data_id, ")((.|\\\n)*?)(?=\n \n)")) %>%
    str_remove_all("\\s+(?=\n)") %>%
    str_remove_all("(?<=\n)\\s+") %>%
    paste0("\n") %>%
    readr::read_table2(col_names = c("month", 1:31)) %>%
    pivot_longer(-month, names_to = "day") %>%
    filter(!(value %in% c(-8888, -9999))) %>%
    transmute(type = data_id,
              value = as.numeric(str_remove(value, "[A-Z]")),
              # After filter so we dont try and parse dates like feb 31st
              date = lubridate::mdy(paste0(month, "-", day, "-2000")))
}


# We need this sequence a good bit and it's a bit of a mouthful so let's store
# it here
twelve_month_seq <- seq(ymd("2000-1-1"), ymd("2000-12-1"), by = "months")


# We have an already build station to city df we are using for lookups
stations_to_download <- read_rds(here("data/station_to_city.rds")) %>% sample_n(50)

options(progressr.enable = TRUE)
plan(multisession, workers = 6)


print("Starting download process!")
with_progress({
  p <- progressor(steps = nrow(stations_to_download))

  furrr::future_walk(
    stations_to_download$station,
    ~ {
      p()
      station_id <- .x
      rds_path <- here(paste0("data/scrape_data/scraped_data/", station_id, ".rds"))

      # Dont redownload data
      if (file.exists(rds_path)) {
        return()
      }

      station_text <- possibly(readr::read_file, otherwise = NULL)(build_station_url(station_id))

      saveRDS(
        list(
          temp = get_temp_data(station_text),
          prcp_data = get_prcp_data(station_text)
        ),
        file = rds_path
      )
    }
  )
})
