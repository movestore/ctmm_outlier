library(shiny)
library(dplyr)
library(ggplot2)
library(ggiraph)
library(hrbrthemes)
library(ctmm)
library(purrr)
library(shinycssloaders)
library(shinyjs)

# Default styling for the interactive (ggiraph) histogram
hrbrthemes::import_roboto_condensed()

set_girafe_defaults(
  opts_zoom = opts_zoom(min = 1, max = 4),
  opts_tooltip = opts_tooltip(css = "padding:3px;background-color:#333333;color:white;"),
  opts_sizing = opts_sizing(rescale = TRUE),
  opts_toolbar = opts_toolbar(saveaspng = FALSE, position = "bottom", delay_mouseout = 5000),
  opts_selection = opts_selection(type = "none")
)

# Format a number for display, rounding up (not to nearest) to 4 significant
# digits, and never rounding away whole units (10987.4 shows as 10,988).
# Rounding up means a displayed value can be typed as the cutoff without
# accidentally excluding the point it came from.
format_round_up <- function(x, digits = 4) {
  # Size of one unit in the last digit shown, e.g. 0.0001 for 0.9311
  step <- pmin(10^(floor(log10(abs(x))) - digits + 1), 1)
  # The small subtraction stops floating-point noise (e.g. 9400.0000001)
  # from rounding up a value that is already exact
  up <- ifelse(x == 0, 0, ceiling(x / step - 1e-9) * step)
  formatC(up, digits = digits, format = "fg", big.mark = ",")
}

# to display messages to the user in the log file of the App in MoveApps
# one can use the function from the src/common/logger.R file:
# logger.fatal() -> logger.trace()

shinyModuleUserInterface <- function(id, label) {
  ns <- NS(id) ## all IDs of UI functions need to be wrapped in ns()
  tagList(
    # Add CSS to apply button so it is easier to tell when it's been invalidated
    tags$style(HTML("
      .apply-btn:not(:disabled) {
        background-color: #337ab7;
        border-color: #2e6da4;
        color: #ffffff;
        box-shadow: 0 0 6px rgba(51, 122, 183, 0.5);
      }
      .apply-btn:not(:disabled):hover,
      .apply-btn:not(:disabled):focus {
        background-color: #286090;
        border-color: #204d74;
        color: #ffffff;
      }
      .apply-btn:disabled {
        background-color: #eeeeee;
        border-color: #d5d5d5;
        color: #555555;
      }

      .cutoff-buttons { display: flex; flex-wrap: wrap; gap: 6px; }
      
      .checkbox input:disabled + span { color: #999999; }

      @media (min-width: 768px) {
        .outlier-sidebar { position: sticky; top: 10px; }
      }
    ")),
    useShinyjs(),
    titlePanel("Outlier detection"),
    sidebarLayout(
      tagAppendAttributes(class = "outlier-sidebar", sidebarPanel(
        width = 3,
        selectInput(
          ns("select_var"),
          label = "Select Variable",
          choices = c("Speed (m/s)" = "speed", "Distance (m)" = "distance")
        ),
        checkboxInput(ns("recursive"), "Recursive (speed only)", value = FALSE),
        uiOutput(ns("cutoff_ui")),
        uiOutput(ns("dropped_note")),
        hr(),
        helpText(
          "The outlier plot shows each location's distance from the median ",
          "location (x-axis) and the minimum speed required to explain its ",
          "displacement as straight-line motion (y-axis)."
        )
      )),
      mainPanel(
        width = 9,
        withSpinner(plotOutput(ns("outl_plot"), height = "400px"), hide.ui = FALSE),
        hr(),
        # height = "auto" lets the box follow the histogram's height, which
        # scales with the panel width
        withSpinner(girafeOutput(ns("plot"), height = "auto"), hide.ui = FALSE)
      )
    )
  )
}

shinyModule <- function(input, output, session, data){ ## The parameter "data" is reserved for the data object passed on from the previous app
  ns <- session$ns ## all IDs of UI functions need to be wrapped in ns()

  # Disable recursive checkbox unless speed is the selected variable.
  observeEvent(input$select_var, {
    toggleState("recursive", condition = input$select_var == "speed")
  })

  # Raw outliers; not affected by recursion. Sets the default cutoffs, so they
  # stay anchored to the actual data max.
  outl_raw <- reactive({
    lapply(data, \(x) outlie(x, plot = FALSE))
  })

  # Largest value of each variable in the data
  var_max <- reactive({
    sped_vals <- lapply(outl_raw(), function(x) x[["speed"]])
    dist_vals <- lapply(outl_raw(), function(x) x[["distance"]])
    
    c(speed = max(unlist(sped_vals)), distance = max(unlist(dist_vals)))
  })

  # Scale step length used in input box up/down arrows to the data. Uses a
  # round number near 1/100 of the data max. This ensures that step length
  # is reasonable both for speed and distance, which are typically on very
  # different scales.
  cutoff_step <- reactive({
    sapply(
      var_max(),
      function(x) {
        if (!is.finite(x) || x <= 0) {
          return(1)
        }
        
        target <- x / 100
        power <- 10^floor(log10(target))
        nice <- c(1, 2, 5, 10)
        power * nice[which.min(abs(nice - target / power))]
      }
    )
  })

  # Default cutoff is the data max rounded to the next step up, with floating
  # point noise rounded out.
  cutoff_default <- reactive({
    round(ceiling(var_max() / cutoff_step()) * cutoff_step(), 10)
  })

  # Build conditional panel containing the UI for each variable. Only one
  # variable is shown at a time. The numeric input for the cutoff depends on
  # which variable (speed or distance) is selected.
  output$cutoff_ui <- renderUI({
    m <- var_max()
    def <- cutoff_default()
    step <- cutoff_step()
    
    cutoff_panel <- function(var, label, unit) {
      conditionalPanel(
        condition = sprintf("input.select_var == '%s'", var),
        ns = ns,
        numericInput(
          ns(paste0("cutoff_", var)),
          label,
          value = def[[var]],
          min = 0,
          step = step[[var]]
        ),
        helpText(paste0("Largest value in the data: ", format_round_up(m[[var]]), " ", unit))
      )
    }
    
    tagList(
      cutoff_panel("speed", "Maximum speed (m/s)", "m/s"),
      cutoff_panel("distance", "Maximum distance (m)", "m"),
      div(
        class = "cutoff-buttons",
        actionButton(ns("apply_cutoff"), "Apply", class = "btn-sm apply-btn", disabled = TRUE),
        actionButton(ns("reset_cutoff"), "Reset to maximum", class = "btn-sm")
      )
    )
  })

  # Don't store button clicks in bookmark. Otherwise a reset clicked at any
  # point would be restored on session start, overriding any true stored
  # settings.
  setBookmarkExclude(c("apply_cutoff", "reset_cutoff"))

  # Store the values currently in place for each variable. This allows us to
  # identify when the "Apply" button has been invalidated and needs to be
  # clicked again.
  applied <- reactiveValues(speed = NULL, distance = NULL)
  
  # Set the currently applied value from the input box's starting value for
  # each variable. Necessary because the inputs themselves don't trigger plot
  # updates, only the applied values do. If it's blank (i.e. if settings were
  # saved with no value in the box) then fall back to the default.
  observeEvent(input$cutoff_speed, {
    x <- input$cutoff_speed
    if (is.numeric(x) && !is.na(x)) {
      applied$speed <- x
    } else {
      applied$speed <- cutoff_default()[["speed"]]
      updateNumericInput(session, "cutoff_speed", value = applied$speed)
    }
  }, once = TRUE)

  observeEvent(input$cutoff_distance, {
    x <- input$cutoff_distance
    if (is.numeric(x) && !is.na(x)) {
      applied$distance <- x
    } else {
      applied$distance <- cutoff_default()[["distance"]]
      updateNumericInput(session, "cutoff_distance", value = applied$distance)
    }
  }, once = TRUE)

  # Determine if the apply button needs to be clicked. Returns TRUE when
  # the selected variable's input box contains a number different from its
  # currently applied cutoff.
  apply_pending <- reactive({
    req(input$select_var)
    x <- input[[paste0("cutoff_", input$select_var)]]
    current <- applied[[input$select_var]]
    is.numeric(x) && !is.na(x) && !is.null(current) && x != current
  })

  observe({
    updateActionButton(session, "apply_cutoff", disabled = !apply_pending())
  })

  observeEvent(input$apply_cutoff, {
    # The button is disabled unless there's a valid value to apply, but check
    # anyway in case the box changed after the button was last updated
    req(apply_pending())
    var <- input$select_var
    applied[[var]] <- input[[paste0("cutoff_", var)]]
  })

  # Put the selected variable's cutoff back to its default (the data maximum)
  # and apply it
  observeEvent(input$reset_cutoff, {
    var <- input$select_var
    def <- cutoff_default()[[var]]
    updateNumericInput(session, paste0("cutoff_", var), value = def)
    applied[[var]] <- def
  })

  # Applied cutoff for the selected variable
  cutoff <- reactive({
    req(input$select_var)
    req(applied[[input$select_var]])
  })

  outl_rows <- reactive({
    if (input$select_var == "speed" && isTRUE(input$recursive)) {
      threshold <- cutoff()
      map2(data, outl_raw(), function(x, xx) {
        rows <- seq_len(nrow(x))
        while (nrow(x) > 0 && max(xx[["speed"]]) > threshold) {
          keep <- xx[["speed"]] <= threshold
          if (!any(keep)) break
          x <- x[keep, ]
          rows <- rows[keep]
          xx <- outlie(x, plot = FALSE)
        }
        
        # Return row indices along with outlier output. When `recursive = TRUE`,
        # we remove some rows from the data at each pass, meaning that the
        # indices can drift from the original input to the data that we're
        # actually returning. Passing `rows` along means we can index relative
        # to the original data.
        list(outl = xx, rows = rows)
      })
    } else {
      map2(data, outl_raw(), \(x, xx) list(outl = xx, rows = seq_len(nrow(x))))
    }
  })

  outl <- reactive({
    lapply(outl_rows(), \(r) r$outl)
  })

  filtered_outl <- reactive({
    var <- input$select_var
    hi <- cutoff()
    filtered <- lapply(outl(), \(x) {
      keep <- x[[var]] <= hi
      out <- x[keep, , drop = FALSE]
      # `outlie` is an S4 object; data.frame subsetting drops that bit and breaks plot dispatch.
      class(out) <- class(x)
      asS4(out)
    })
    # Leave out individuals with no points at or below the cutoff, matching the returned
    # data. ctmm's plot method can't draw an individual with zero rows.
    purrr::keep(filtered, \(x) nrow(x) > 0)
  })

  output$outl_plot <- renderPlot({
    validate(need(length(filtered_outl()) > 0, "No points at or below the cutoff."))
    
    # Use `units = FALSE` to ensure that the input box units match the plot
    # units. ctmm picks the most appropriate unit, so without this, the units
    # can change as points are filtered.
    par(mar = c(4.5, 4.5, 1, 1))
    plot(filtered_outl(), units = FALSE)
  })

  reactive_data <- reactive({
    req(input$select_var)

    # Values of the selected variable (speed or distance), pooled across
    # animals. lapply() keeps this a plain vector; sapply() would return a
    # matrix when all animals have the same number of locations.
    values <- unlist(lapply(outl(), \(x) x[[input$select_var]]), use.names = FALSE)
    req(length(values) > 0)

    tibble(value = values)
  })

  output$plot <- renderGirafe({

    hi <- cutoff()

    plot_data <- reactive_data() |>
      filter(value <= hi)

    validate(need(nrow(plot_data) > 0, "No points at or below the cutoff."))

    unit <- if (input$select_var == "speed") "m/s" else "m"

    gg <- ggplot(plot_data, aes(x = value)) +
      geom_histogram_interactive(hover_nearest = TRUE) +
      labs(x = if (input$select_var == "speed") "Speed (m/s)" else "Distance (m)") +
      theme_ipsum_rc(plot_margin = margin(10, 10, 10, 10))

    # Plot ticks below histogram showing where data values are. This allows us
    # to see points even where they are very sparse. Hovering on a tick shows
    # its value so that value can be used as an input if desired. We tally
    # values in small bins to avoid making a tick for every point in large
    # datasets.
    rng <- range(plot_data$value)
    slice_width <- diff(rng) / 1000
    rug_data <- plot_data |>
      mutate(slice = if (slice_width > 0) floor((value - rng[1]) / slice_width) else 0) |>
      group_by(slice) |>
      summarise(value = max(value), n = n()) |>
      mutate(tooltip = paste0(
        format_round_up(value), " ", unit,
        ifelse(n > 1, paste0(" (", n, " points)"), "")
      ))

    # Draw ticks in a row below y=0. Tick height is scaled to the highest
    # bar in the histogram.
    top <- max(layer_data(gg)$count)
    
    gg <- gg +
      geom_linerange_interactive(
        data = rug_data,
        aes(x = value, ymin = -0.09 * top, ymax = -0.02 * top,
            tooltip = tooltip, data_id = slice),
        inherit.aes = FALSE, linewidth = 0.4, colour = "#333333",
        hover_nearest = TRUE
      ) +
      scale_y_continuous(
        expand = expansion(mult = c(0.02, 0.05)),
        breaks = \(lims) pretty(c(0, lims[2])),
        minor_breaks = \(lims) {
          b <- pretty(c(0, lims[2]))
          seq(0, max(b), by = diff(b)[1] / 2)
        }
      )

    girafe(ggobj = gg, width_svg = 8, height_svg = 3)

  })

  # Each individual's data at or below the cutoff; NULL if it has no such points
  filtered_data <- reactive({

    var <- input$select_var
    hi <- cutoff()
    map2(data, outl_rows(), function(a, r) {
      b <- r$outl
      ind <- which(b[[var]] <= hi)
      if (length(ind) > 0) {
        a[r$rows[ind], ]
      } else {
        NULL
      }
    })
  })

  # Individuals with no points at or below the cutoff, which are left out of the output
  dropped_ids <- reactive({
    names(purrr::keep(filtered_data(), is.null))
  })

  output$dropped_note <- renderUI({
    ids <- dropped_ids()
    if (length(ids) == 0) return(NULL)
    p(
      class = "text-warning",
      paste0(
        "No points at or below the cutoff for: ", paste(ids, collapse = ", "),
        ". These animals will not be passed to the next app."
      )
    )
  })

  dat.f <- reactive({
    ids <- dropped_ids()
    if (length(ids) > 0) {
      logger.warn(
        "No points at or below the cutoff for: %s. Removed from the output.",
        paste(ids, collapse = ", ")
      )
    }

    # Remove NULL entries, which result from individuals with no points that
    # meet the input thresholds. Downstream apps may fail on NULL input.
    filtered <- purrr::compact(filtered_data())

    if (length(filtered) == 0) {
      NULL
    } else {
      filtered
    }
  })

  # The applied cutoffs are only set once the UI has been opened in a browser.
  # Until then, pass the input data on unchanged so the next app can run.
  return(
    reactive({
      if (is.null(applied$speed)) data else dat.f()
    })
  )
}
