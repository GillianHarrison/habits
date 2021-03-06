# Complete shiny app for the HABITS DST.
#
# Expects the required files to exist in a subdir "data" of the working directory.

library(shiny)
library(leaflet)
# Install my fork
# devtools::install_github("cmcaine/leaflet.extras")
library(leaflet.extras)
library(sf)
library(ggplot2)
library(dplyr)
library(jsonlite)
library(raster)
library(purrr)

### Load and prepare data ###

# Crop a Simple Features Data Frame to the extent of a raster
crop.sf <- function(sfdf, rasta) {
  # Get extent and crs
  ext.sp <- as(extent(rasta), "SpatialPolygons")
  crs(ext.sp) <- crs(rasta)

  # crop
  st_intersection(sfdf, st_as_sf(ext.sp))
}

# Get pollution raster for overlay
pollution_brick = raster("data/pollution_brick")

# Get aggregated lines

# Didn't do this in the end:
# Each segment will have a list of trips IDs that start, intersect, or end in the segment
# Table of trips relates trip ID to aggregate statistics
# load("../data/roads_sf.Rdata")


# Get trips

trips.export = read_sf("data/sensitive/trips.gpkg")
st_crs(trips.export)<-4326
# trips.export = crop.sf(trips.export, pollution_brick)
# Assign each trip to Thursday of the week its in.
trips.export$startWeek = as.Date(strptime(strftime(trips.export$startDT, "%Y %W 4"), format = "%Y %W %u"))
trips.export$MET[is.na(trips.export$MET)] = 0.1
# Exclude rare modes
modes = c("Bike", "Bus", "Car", "Foot", "Train")
trips.export = trips.export[trips.export$modality %in% modes, ]
# Extract start and end points
geom_head = function(geom) {
  st_point(c(geom[[1]], geom[[length(geom)/2+1]]))
}
geom_tail = function(geom) {
  len = length(geom)
  st_point(c(geom[[len/2]], geom[[len]]))
}
trips.export$origin = st_sfc(lapply(trips.export$geom, geom_head))
st_crs(trips.export$origin)<-4326
trips.export$destination = st_sfc(lapply(trips.export$geom, geom_tail))
st_crs(trips.export$destination)<-4326

# Far too long
# group_by(st_cast(trips.export, "POINT"), tripId) %>% summarise(tripId, startDT, modality, MET, start = st_sfc(geometry[[1]]), end = st_sfc(geometry[[length(geometry)]]))


# Colours and theming
cbbPalette <-
  c("#E69F00",
    "#56B4E9",
    "#009E73",
    "#F0E442",
    "#0072B2",
    "#D55E00",
    "#CC79A7")
defraPalette <- c("#01237D", "#57FF00", "#FB0400")
theme_update(text = element_text(size = 20))

### Update logic ###

update <- function(input, output, regions) {
  # Update map and both plots. Bit expensive, could be a reactive expression
  print("Updating")
  # Filter trips.export to match input$filter
  trips = filterTrips(input$filter, regions, input$dateRange)
  output$plot = updatePlot(input$variable, trips, quote(factor(startWeek)), "Start week")
  BA_xaxis = substitute(startDT > intervention_date,
    list(intervention_date = input$intervention_date))
  output$before_after_plot = updatePlot(input$variable, trips, BA_xaxis, "After intervention")
  updateMap("map", input$variable, trips)
}

# NB: this can be a reactive value to avoid recomputation
filterTrips <- function(filter, regions, dateRange) {
  # Return a subset of trips.export
  trips = trips.export

  # Subset by date, but only if we have to because making new sf objects is expensive.
  if (dateRange[[1]] != min(trips$startDT) ||
      dateRange[[2]] != max(trips$startDT)) {
    # Function local copy.
    trips = trips[(trips$startDT >= dateRange[[1]]) & (trips$startDT <= dateRange[[2]]), ]
  }

  if (filter == "region") {
    # Find all intersecting regions
    if (nrow(regions) > 0) {
      inter = unique(unlist(st_intersects(subset(regions, filter == "intersects"), trips$geom)))
      start = unique(unlist(st_intersects(subset(regions, filter == "starts in"), trips$origin)))
      end = unique(unlist(st_intersects(subset(regions, filter == "ends in"), trips$destination)))
      inter = c(inter, start, end)
      if (length(inter) != 0) {
        trips[inter, ]
      } else {
        subset(trips, F)
      }
    } else {
      subset(trips, F)
    }
  } else if (filter == "none") {
    trips
  }
}

plotMeta = data.frame(
  variable = c('MET-h', '# Journeys', '% Journeys'),
  title = c(
    "Change in MET-h per mode over time",
    "Number of Journeys by mode per week",
    "Proportion of Journeys by mode per week"
  ),
  row.names = 'variable'
)

updatePlot <- function(variable, trips, xaxis, xlabel) {
  # Prepare a ggplot according to variable and xaxis
  if (nrow(trips) < 1) {
    trips = trips.export
  }

  if (nrow(trips) == nrow(trips.export)) {
    title = "(All data)"
  } else {
    title = "(Subset)"
  }

  plot = switch(
    as.character(variable),
    'MET-h' = {
      activeTrips = subset(trips, MET > 0.1)
      plot = (ggplot(trips, aes_(
        x = xaxis,
        y = ~ MET,
        color = ~ modality
      ))
        + scale_y_log10())

      if (nrow(trips) > 500) {
        plot = (
          plot + geom_violin(data = activeTrips)
          + geom_smooth(
            data = activeTrips,
            method = 'lm',
            aes(group = modality)
          )
        )
      } else {
        plot = plot + geom_jitter(data = activeTrips, height = 0)
      }

      plot + scale_linetype_manual(values = cbbPalette) + geom_smooth(method = 'lm', aes(group = 1, color = "All modes"))
    },
    '# Journeys' = (
      ggplot(trips, aes_(x = xaxis, fill = ~ modality))
      + geom_histogram(stat = "count")
      + scale_fill_manual(values = cbbPalette)
    ),
    '% Journeys' = (
      ggplot(trips, aes_(x = xaxis, fill = ~ modality))
      + geom_histogram(stat = "count", position = "fill")
      + scale_fill_manual(values = cbbPalette)
    )
  )

  plot = plot + xlab(xlabel) + ylab(variable) + ggtitle(paste(plotMeta[variable, 'title'], title))

  # Render it to outPlot
  renderPlot(plot)
}

# Partial application of $
cg <- function (name) {
  function (df) {
    df[[name]]
  }
}

mapMeta = list(
  "MET-h" = list(
    col = function(trips) {
      log(trips$MET)
    },
    pal = colorNumeric(palette = "RdBu", domain = log(trips.export$MET))
  ),
  "# Journeys" = list(
    col = cg("modality"),
    pal = colorFactor(cbbPalette, trips.export$modality)
  ),
  "% Journeys" = list(
    col = cg("modality"),
    pal = colorFactor(cbbPalette, trips.export$modality)
  )
)

addTrips <- function (map, trips, variable) {
  meta <- mapMeta[[variable]]
  col <- meta$col(trips)
  addPolylines(
    map,
    group = "routes",
    data = trips,
    color = meta$pal(col),
    label = col
  ) %>%
    addLegend(
      "bottomright",
      pal = meta$pal,
      values = col,
      layerId = "routesLegend"
    )
}

updateMap <- function(mapref, variable, trips) {
  # Redraw routes, coloured by $variable
  map <- leafletProxy(mapref) %>% clearGroup('routes')
  if (nrow(trips) > 0) {
    addTrips(map, trips, variable)
  }
}


### Define UI ###

variables = c('# Journeys', '% Journeys', 'MET-h') #, 'Health impact (total)', 'Health impact (pollution)')
filters = c('region')
splits = c('modality', 'IMD', 'age', 'gender', 'region')

inputWidgets = inputPanel(
  selectInput('variable', 'variable', variables),
  selectInput('filter', 'filter', filters),
  # Show split panel unless active tab is the map. Map is the first active tab, hence the more elaborate function
  conditionalPanel(
    '(() => {
      tab = document.querySelector(\'[aria-expanded="true"][data-toggle="tab"]\')
      if (tab == null) {
        return false
      } else {
        return tab.getAttribute("data-value") !== map
      }
    })()',
    selectInput('split', 'split', splits)
  ),
  conditionalPanel(
    'document.querySelector(\'[aria-expanded="true"][data-value="before and after"][data-toggle="tab"]\') !== null',
    dateInput('intervention_date', 'intervention date', value = "2017-08-01")
  ),
  dateRangeInput('dateRange', 'Study period', start = min(trips.export$startDT), end = max(trips.export$startDT)),
  uiOutput('regionFilter')
)

plot = plotOutput("plot", height = "100%")
map = leafletOutput("map", height = "100%")
before_after_plot = plotOutput("before_after_plot", height = "100%")

ui <- fluidPage(# titlePanel("HABITS Decision Support Tool"),

  fluidRow(column(2, inputWidgets),
    column(
      10,
      tabsetPanel(
        tabPanel("map", map),
        tabPanel("plot", plot),
        tabPanel("before and after", before_after_plot)
      )
    )
  ),

  fluidRow(
    class = "footer",

    column(12,
    tags$div(
      style = "width: 100%",
      tags$p("The project leading to this application has received funding through the ESRC (grant ES/P01139X/1) and the European Union’s Horizon 2020 research and innovation programme under grant agreement no 636249."),
      tags$img(src="esrc_logo.png"),
      tags$img(src="eu_logo.jpg")
    )
  )),

  # Fix the size of various ancestor elements so we can use 100% as a size
  # without messing everything up.
  theme = "custom.css")

# Alternative entirely custom version
# ui <- htmlTemplate(filename = "www/split-pane-template.html", map = map, plot = plot)


### Server-side logic (setup and observers) ###

# Draw the map and plot and react to changes in inputs, map draw events, etc.
server <- function(input, output) {

  # Get LSOAs for chloropleth
  combined_lsoas = read_sf("regions.gpkg")

  addLSOAs <- function(map, data = combined_lsoas, ...) {
    addSelectableRegions(map,
      data = data,
      label = ~ htmltools::htmlEscape(label),
      ...)
  }

  addSelectableRegions <- function(map, data, ...) {
    # The labels are fussy
    #   Warning: Error in sum: invalid 'type' (list) of argument
    addPolygons(
      map,
      data = data,
      weight = 2,
      layerId = ~ id,
      group = ~ group,
      ...
    )
  }

  addPolutionRaster <- function(map, rasta, group, ...) {
    minmax <- c(cellStats(rasta, min), cellStats(rasta, max))
    palette = colorNumeric(palette = defraPalette, domain = c(0, 70))
    map %>%
      addRasterImage(rasta,
        group = "Pollution map",
        opacity = .4,
        col = palette) %>%
      addLegend("bottomright",
        pal = palette,
        values = minmax,
        group = "Pollution map")
  }

  output$map <- renderLeaflet({
    map = leaflet(options = leafletOptions(preferCanvas = T)) %>%
      addProviderTiles(provider = "CartoDB.Positron") %>%
      setView(-1.61, 54.97, zoom = 13) %>%
      addDrawToolbar(
        targetGroup = 'draw',
        polylineOptions = F,
        circleOptions = F,
        markerOptions = F,
        circleMarkerOptions = F,
        editOptions = editToolbarOptions()
      ) %>%
      addLayersControl(overlayGroups = c("Pollution map", "LSOAs")) %>%
      addPolutionRaster(pollution_brick[[1]]) %>%
      addLSOAs(combined_lsoas) %>%
      hideGroup(c("Pollution map", "LSOAs"))
    # addPolygons(data = roads, smoothFactor = 20)
  })

  ### Reactive/dynamic stuff ###

  # Persistent variables
  regions = combined_lsoas
  lastClickedRegion = NA

  # Observers

  # Update drawn_shapes
  observeEvent(input$map_draw_all_features, {
    if (length(input$map_draw_all_features$features) > 0) {
      drawn_shapes <-
        read_sf(toJSON(
          input$map_draw_all_features,
          force = T,
          auto_unbox = T
        )) %>%
        rename(id = `_leaflet_id`, geom = geometry) %>%
        # This event returns some duplicate shapes. Probably a side effect of
        # the "redraw red" code in map_shape_click handler.
        subset(is.na(id) == F, select = c("id", "geom"))
      drawn_shapes$label = NA
      drawn_shapes$group = "draw"

      # Get old filter values
      drawn_shapes$filter = NA
      vs = function(vs) {
        if (length(vs) == 1) {
          "off"
        } else {
          max(vs, na.rm = T)
        }
      }
      drawn_shapes = group_by(rbind(drawn_shapes, subset(regions, group == "draw")), id) %>%
        summarise(filter = vs(filter))
      drawn_shapes$label = NA
      drawn_shapes$group = "draw"

      # Replace regions
      regions <<- rbind(subset(regions, group != "draw"), drawn_shapes)
    }
  })

  # Attempt to fix double geometry problem with drawn features
  # observeEvent(input$map_draw_new_feature, {
  #   shape = read_sf(toJSON(input$map_draw_new_feature, force=T, auto_unbox = T)) %>%
  #       rename(id = X_leaflet_id) %>% cbind(list(., group="draw", label=.$id))
  #   leafletProxy("map") %>%
  #     removeShape(shape$id) %>%
  #     addSelectableRegions(shape)
  # })

  updateRegionFilterUI = function(region) {
    output$regionFilter = renderUI({
      selectizeInput('regionFilter', region$id, selected = region$filter, c("off", "intersects", "starts in", "ends in"))
    })
  }

  observeEvent(input$regionFilter, {
    regions[regions$id == lastClickedRegion$id, ]$filter <<- input$regionFilter
    update(input, output, regions)
  })

  # Update regions on click
  observeEvent(input$map_shape_click, {
    print(input$map_shape_click)

    # This event can fire draw_all_features, so check if shape exists
    id <- input$map_shape_click$id
    reg <- regions[regions$id == id, ]

    if (nrow(reg) != 0) {
      # Test if reg == last
      # if not, uncolour last, colour reg, and set last = reg.

      if (is.na(lastClickedRegion)) {
        # Colour new region
        leafletProxy("map") %>%
          addLSOAs(reg, fillColor = "red")
        lastClickedRegion <<- reg
      }

      if (reg$id != lastClickedRegion$id) {
        # Uncolour old, colour new
        leafletProxy("map") %>%
          addLSOAs(lastClickedRegion) %>%
          addLSOAs(reg, fillColor = "red")
        lastClickedRegion <<- reg
      }

      updateRegionFilterUI(reg)
      # activeRegions = subset(regions, filter != "off")

      # if (nrow(activeRegions) > 0) {
      #   # Uncolour currently selected activeRegions
      #   leafletProxy("map") %>%
      #     addLSOAs(activeRegions)
      # }

      # # Update regions var.
      # reg$filter <- switch(reg$filter,
      #   "off" = "intersection",
      #   "intersection" = "off"
      # )

      # # Update region
      # regions[regions$id == id, ] <<- reg

      # Highlight selected regions.
      # activeRegions = subset(regions, filter != "off")
      # leafletProxy("map") %>%
      #   addLSOAs(activeRegions, fillColor = 'red')

      # Update everything else
      # update(input, output, activeRegions)
    }
  })

  # Update everything on events
  observe({
    update(input, output, regions)
  })
}

# Run the application
shinyApp(ui = ui, server = server)
