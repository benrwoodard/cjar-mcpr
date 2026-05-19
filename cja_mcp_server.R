#!/usr/bin/env Rscript
# CJA MCP Server
#
# Exposes every exported function from the cjar package as an MCP tool over
# stdio, using the mcpr package. Designed to be launched by Claude Code via:
#
#   claude mcp add cja -- Rscript /absolute/path/to/cja_mcp_server.R
#
# Auth: reads Sys.getenv("CJA_AUTH_FILE") at startup. If that env var is not
# set or auth fails, the server still starts and tools will retry auth on
# first use. Set CJA_AUTH_FILE in your shell or the MCP server config.
#
# IMPORTANT: stdout is reserved for JSON-RPC frames. All logging must go to
# stderr via message().

suppressPackageStartupMessages({
  library(cjar)
  library(mcpr)
  library(jsonlite)
})

log_stderr <- function(...) message("[cja-mcp] ", ...)

# Best-effort startup auth. Errors are reported on stderr and swallowed so the
# server still starts (Claude Code does not surface stderr until a tool call).
tryCatch(
  {
    auth_file <- Sys.getenv("CJA_AUTH_FILE")
    if (nzchar(auth_file)) {
      cja_auth()
      log_stderr("Authenticated with CJA at startup.")
    } else {
      log_stderr("CJA_AUTH_FILE not set; tools will fail until auth is configured.")
    }
  },
  error = function(e) log_stderr("Startup auth failed: ", conditionMessage(e))
)

# ---------------------------------------------------------------------------
# Handler helpers
# ---------------------------------------------------------------------------

# Convert an arbitrary R value into a response_text with JSON content. Falls
# back to printed output when JSON encoding fails (e.g. for unsupported types).
json_response <- function(x) {
  txt <- tryCatch(
    jsonlite::toJSON(
      x,
      dataframe = "rows",
      auto_unbox = TRUE,
      pretty = TRUE,
      null = "null",
      na = "null",
      force = TRUE
    ),
    error = function(e) paste(capture.output(print(x)), collapse = "\n")
  )
  mcpr::response_text(as.character(txt))
}

# Pull arguments out of the MCP `input` list, dropping NULLs so the cjar
# function's own defaults apply. Array inputs arrive as R lists; flatten them
# to atomic vectors. Names listed in `as_date` are converted to Date.
prepare_args <- function(input, as_date = character(0)) {
  args <- list()
  for (nm in names(input)) {
    val <- input[[nm]]
    if (is.null(val)) next
    if (nm %in% as_date) {
      val <- as.Date(unlist(val))
    } else if (is.list(val)) {
      val <- unlist(val)
    }
    args[[nm]] <- val
  }
  args
}

# Build a handler that forwards MCP args to a cjar function and returns JSON.
make_handler <- function(fn, as_date = character(0)) {
  force(fn); force(as_date)
  function(input) {
    args <- prepare_args(input, as_date = as_date)
    result <- do.call(fn, args)
    json_response(result)
  }
}

# Parse a JSON string argument back into an R list. Returns NULL if input is
# NULL/empty so cjar's default kicks in.
parse_json_arg <- function(s) {
  if (is.null(s) || !nzchar(s)) return(NULL)
  jsonlite::fromJSON(s, simplifyVector = FALSE)
}

# ---------------------------------------------------------------------------
# Common reusable properties
# ---------------------------------------------------------------------------

prop_debug <- function() {
  property_boolean(
    "Debug",
    "If TRUE, cjar logs the underlying API request/response to stderr."
  )
}

prop_locale <- function() {
  property_string("Locale", "Locale code, e.g. 'en_US'. Default 'en_US'.")
}

prop_string_array <- function(title, description) {
  property_array(
    title, description,
    items = property_string(title, description)
  )
}

# ---------------------------------------------------------------------------
# Tool: cja_get_me
# ---------------------------------------------------------------------------

tool_get_me <- new_tool(
  name = "cja_get_me",
  description = "Get the authenticated user's CJA profile and the company IDs they have access to. Useful as a connectivity check.",
  input_schema = schema(properties = list(
    expansion = property_string("Expansion", "Comma-delimited extra fields. Only 'admin' is supported."),
    debug = prop_debug()
  )),
  handler = make_handler(cja_get_me)
)

# ---------------------------------------------------------------------------
# Tool: cja_get_dataviews
# ---------------------------------------------------------------------------

tool_get_dataviews <- new_tool(
  name = "cja_get_dataviews",
  description = "List CJA data views (analogous to Adobe Analytics report suites) the user has access to. Returns ids and metadata.",
  input_schema = schema(properties = list(
    expansion = prop_string_array(
      "Expansion fields",
      "Additional metadata fields. Options: name, description, owner, isDeleted, parentDataGroupId, segmentList, currentTimezoneOffset, timezoneDesignator, modified, createdDate, organization, curationEnabled, recentRecordedAccess, sessionDefinition, externalData, containerNames."
    ),
    parentDataGroupId = property_string("Parent data group ID", "Filter by a single parentDataGroupId."),
    externalIds = property_string("External IDs", "Comma-delimited list of external ids."),
    externalParentIds = property_string("External parent IDs", "Comma-delimited list of external parent ids."),
    dataviewIds = property_string("Data view IDs", "Comma-delimited list of data view ids to limit the response."),
    includeType = property_string("Include type", "Include additional data views. Option: 'deleted'."),
    cached = property_boolean("Cached", "Return cached results. Default TRUE."),
    limit = property_number("Limit", "Results per page. Default 1000.", integer = TRUE),
    page = property_number("Page", "Zero-based page number. Default 0.", integer = TRUE),
    sortDirection = property_enum("Sort direction", "Sort direction.", values = c("ASC", "DESC")),
    sortProperty = property_string("Sort property", "Sort property. Allowed: 'modifiedDate', 'id'. Default 'id'."),
    debug = prop_debug()
  )),
  handler = make_handler(cja_get_dataviews)
)

# ---------------------------------------------------------------------------
# Tool: cja_get_dimensions
# ---------------------------------------------------------------------------

tool_get_dimensions <- new_tool(
  name = "cja_get_dimensions",
  description = "List dimensions available in a CJA data view. dataviewId falls back to env var CJA_DATAVIEW_ID if not provided.",
  input_schema = schema(properties = list(
    dataviewId = property_string("Data view ID", "The data view to query. Falls back to env var CJA_DATAVIEW_ID."),
    expansion = property_string(
      "Expansion fields",
      "Comma-delimited metadata fields. Options include description, tags, type, schemaType, hasData, etc."
    ),
    includeType = property_string("Include type", "Options: shared, templates, deleted, internal."),
    locale = prop_locale(),
    debug = prop_debug()
  )),
  handler = make_handler(cja_get_dimensions)
)

# ---------------------------------------------------------------------------
# Tool: cja_get_metrics
# ---------------------------------------------------------------------------

tool_get_metrics <- new_tool(
  name = "cja_get_metrics",
  description = "List metrics available in a CJA data view. dataviewId falls back to env var CJA_DATAVIEW_ID if not provided.",
  input_schema = schema(properties = list(
    dataviewId = property_string("Data view ID", "The data view to query. Falls back to env var CJA_DATAVIEW_ID."),
    expansion = property_string(
      "Expansion fields",
      "Comma-delimited metadata fields. Options include description, tags, type, schemaType, hasData, etc."
    ),
    includeType = property_string("Include type", "Options: shared, templates, deleted, internal."),
    locale = prop_locale(),
    debug = prop_debug()
  )),
  handler = make_handler(cja_get_metrics)
)

# ---------------------------------------------------------------------------
# Tool: cja_get_calculatedmetrics
# ---------------------------------------------------------------------------

tool_get_calculatedmetrics <- new_tool(
  name = "cja_get_calculatedmetrics",
  description = "List calculated metrics. Use the returned IDs in cja_freeform_table metrics arg.",
  input_schema = schema(properties = list(
    expansion = prop_string_array(
      "Expansion fields",
      "Extra metadata. Options: ownerFullName, modified, definition, compatibility, reportSuiteName, tags, dataName, approved, favorite, shares, sharesFullName, usageSummary, usageSummaryWithRelevancyScore, siteTitle, migratedIds, isDeleted, authorization, legacyId, internal, dataGroup, categories."
    ),
    includeType = property_enum(
      "Include type",
      "Which metrics to include.",
      values = c("all", "shared", "templates", "unauthorized", "deleted", "internal", "curatedItem")
    ),
    dataviewIds = prop_string_array("Data view IDs", "Filter to metrics tied to these data view ids."),
    ownerId = property_string("Owner ID", "Filter to metrics owned by this loginId."),
    filterByIds = prop_string_array("Filter by IDs", "Only include these calculated metric ids."),
    toBeUsedInRsid = property_string("To be used in RSID", "Data view that compatibility/permissions are computed against."),
    locale = prop_locale(),
    favorite = property_boolean("Favorite", "Only return favorites if TRUE."),
    approved = property_boolean("Approved", "Only return approved metrics if TRUE."),
    pagination = property_boolean("Pagination", "Paginated results. Default TRUE."),
    limit = property_number("Limit", "Results per page. Default 10.", integer = TRUE),
    page = property_number("Page", "Zero-based page number. Default 0.", integer = TRUE),
    sortDirection = property_enum("Sort direction", "Sort direction.", values = c("ASC", "DESC")),
    sortProperty = property_enum("Sort property", "Sort property.", values = c("id", "name", "modified_date")),
    debug = prop_debug()
  )),
  handler = make_handler(cja_get_calculatedmetrics)
)

# ---------------------------------------------------------------------------
# Tool: cja_get_filters
# ---------------------------------------------------------------------------

tool_get_filters <- new_tool(
  name = "cja_get_filters",
  description = "Paginated list of CJA filters (a.k.a. Adobe Analytics segments).",
  input_schema = schema(properties = list(
    expansion = prop_string_array(
      "Expansion fields",
      "Extra metadata fields, e.g. definition, modified, owner, tags, sharesFullName, approved, favorite."
    ),
    includeType = property_enum(
      "Include type",
      "Which filters to include.",
      values = c("all", "shared", "templates", "deleted", "internal")
    ),
    dataviewIds = prop_string_array("Data view IDs", "Filter to filters tied to these data view ids."),
    ownerId = property_string("Owner ID", "Filter to filters owned by this imsUserId."),
    filterByIds = prop_string_array("Filter by IDs", "Only include these filter ids."),
    toBeUsedInRsid = property_string("To be used in RSID", "Report suite for compatibility/permissions."),
    locale = prop_locale(),
    name = property_string("Name contains", "Filter to filters whose name contains this string."),
    filterByModifiedAfter = property_string("Modified after", "Only filters modified since this date. Format yyyy-mm-dd."),
    cached = property_boolean("Cached", "Return cached results. Default TRUE."),
    pagination = property_boolean("Pagination", "Return paginated results. Default TRUE."),
    limit = property_number("Limit", "Results per page. Default 10.", integer = TRUE),
    page = property_number("Page", "Zero-based page number. Default 0.", integer = TRUE),
    sortDirection = property_enum("Sort direction", "Sort direction.", values = c("ASC", "DESC")),
    sortProperty = property_enum("Sort property", "Sort property.", values = c("name", "modified_date", "performanceScore", "id")),
    debug = prop_debug()
  )),
  handler = make_handler(cja_get_filters)
)

# ---------------------------------------------------------------------------
# Tool: cja_get_filter
# ---------------------------------------------------------------------------

tool_get_filter <- new_tool(
  name = "cja_get_filter",
  description = "Retrieve a single CJA filter (segment) by id.",
  input_schema = schema(properties = list(
    id = property_string("Filter ID", "The filter id to retrieve.", required = TRUE),
    toBeUsedInRsid = property_string("To be used in RSID", "Data view used for compatibility/permissions."),
    locale = prop_locale(),
    expansion = property_string(
      "Expansion fields",
      "Comma-delimited extra fields, e.g. definition, modified, owner, tags. Default 'definition'."
    ),
    debug = prop_debug()
  )),
  handler = make_handler(cja_get_filter)
)

# ---------------------------------------------------------------------------
# Tool: cja_get_dateranges
# ---------------------------------------------------------------------------

tool_get_dateranges <- new_tool(
  name = "cja_get_dateranges",
  description = "Paginated list of stored CJA date ranges.",
  input_schema = schema(properties = list(
    locale = prop_locale(),
    filterByIds = property_string("Filter by IDs", "Comma-delimited list of date range ids."),
    limit = property_number("Limit", "Results per page. Default 10.", integer = TRUE),
    page = property_number("Page", "Zero-based page number. Default 0.", integer = TRUE),
    expansion = property_string(
      "Expansion fields",
      "Comma-delimited extra fields. Options: definition, modified, ownerFullName, sharesFullName, shares, tags. Default 'definition'."
    ),
    includeType = property_enum(
      "Include type",
      "Which to include.",
      values = c("all", "shared", "templates")
    ),
    debug = prop_debug()
  )),
  handler = make_handler(cja_get_dateranges)
)

# ---------------------------------------------------------------------------
# Tool: cja_get_projects
# ---------------------------------------------------------------------------

tool_get_projects <- new_tool(
  name = "cja_get_projects",
  description = "Paginated list of CJA Workspace Projects.",
  input_schema = schema(properties = list(
    includeType = property_enum(
      "Include type",
      "Which to include.",
      values = c("all", "shared")
    ),
    expansion = property_string(
      "Expansion fields",
      "Comma-delimited extra fields. Options: shares, tags, accessLevel, modified, externalReferences, definition. Default 'definition'."
    ),
    locale = prop_locale(),
    filterByIds = property_string("Filter by IDs", "Comma-delimited list of project ids."),
    pagination = property_string("Pagination", "Return paginated results. 'true' (default) or 'false'."),
    ownerId = property_string("Owner ID", "Filter to projects owned by this imsUserId."),
    limit = property_number("Limit", "Results per page. Default 10.", integer = TRUE),
    page = property_number("Page", "Zero-based page number. Default 0.", integer = TRUE),
    debug = prop_debug()
  )),
  handler = make_handler(cja_get_projects)
)

# ---------------------------------------------------------------------------
# Tool: cja_get_project_config
# ---------------------------------------------------------------------------

tool_get_project_config <- new_tool(
  name = "cja_get_project_config",
  description = "Retrieve a single project's configuration JSON.",
  input_schema = schema(properties = list(
    id = property_string("Project ID", "Project id to retrieve.", required = TRUE),
    expansion = property_string(
      "Expansion fields",
      "Comma-delimited extra fields. Options: shares, tags, accessLevel, modified, externalReferences, definition. Default 'definition'."
    ),
    locale = prop_locale(),
    debug = prop_debug()
  )),
  handler = make_handler(cja_get_project_config)
)

# ---------------------------------------------------------------------------
# Tool: cja_get_audit_logs
# ---------------------------------------------------------------------------

tool_get_audit_logs <- new_tool(
  name = "cja_get_audit_logs",
  description = "List audit logs filtered by action, component, user, or date range.",
  input_schema = schema(properties = list(
    startDate = property_string("Start date", "Inclusive lower bound. Required if endDate given."),
    endDate = property_string("End date", "Inclusive upper bound. Required if startDate given."),
    action = property_enum(
      "Action",
      "Action to filter by.",
      values = c("CREATE", "EDIT", "DELETE", "LOGIN_FAILED", "LOGIN_SUCCESSFUL", "API_REQUEST", "LOGOUT", "APPROVE", "UNAPPROVE", "SHARE", "UNSHARE", "TRANSFER", "ORG_CHANGE")
    ),
    component = property_enum(
      "Component",
      "Component type.",
      values = c("ANNOTATION", "CALCULATED_METRIC", "CONNECTION", "DATA_GROUP", "DATA_VIEW", "DATE_RANGE", "FILTER", "MOBILE", "PROJECT", "REPORT", "SCHEDULED_PROJECT", "USER", "USER_GROUP", "IMS_ORG", "FEATURE_ACCESS")
    ),
    componentId = property_string("Component ID", "The id of the component."),
    userType = property_string("User type", "The user type."),
    userId = property_string("User ID", "The user id."),
    userEmail = property_string("User email", "The user's email."),
    description = property_string("Description", "Log description to filter by."),
    pageSize = property_number("Page size", "Results per page. Default 100. Max 1000.", integer = TRUE),
    pageNumber = property_number("Page number", "Zero-based page number. Default 0.", integer = TRUE),
    debug = prop_debug()
  )),
  handler = make_handler(cja_get_audit_logs)
)

# ---------------------------------------------------------------------------
# Tool: cja_get_audit_logs_search
# ---------------------------------------------------------------------------

tool_get_audit_logs_search <- new_tool(
  name = "cja_get_audit_logs_search",
  description = "POST a JSON search query against the audit logs endpoint.",
  input_schema = schema(properties = list(
    body = property_string("Body", "JSON string with the audit log search request body.", required = TRUE),
    debug = prop_debug()
  )),
  handler = function(input) {
    result <- cja_get_audit_logs_search(
      body = input$body,
      debug = isTRUE(input$debug)
    )
    json_response(result)
  }
)

# ---------------------------------------------------------------------------
# Tool: cja_freeform_table
# ---------------------------------------------------------------------------

tool_freeform_table <- new_tool(
  name = "cja_freeform_table",
  description = paste(
    "Run a CJA Freeform Table report and return rows as JSON. The order of `dimensions` matters for performance:",
    "the first dimension is queried first, then each value is broken down by the next dimension (one API call per value),",
    "so put dimensions with fewer unique values first when possible. Use `top` to cap rows per breakdown level",
    "(e.g. top=[0, 5] = all of the first dimension's values, top-5 of the second).",
    "`date_range` is a 2-element array of ISO dates [start, end]. Defaults to the last 30 days.",
    "`metrics` and `dimensions` should be ids from cja_get_metrics, cja_get_calculatedmetrics, and cja_get_dimensions.",
    sep = " "
  ),
  input_schema = schema(properties = list(
    dataviewId = property_string("Data view ID", "Required unless CJA_DATAVIEW_ID env var is set."),
    date_range = property_array(
      "Date range",
      "Two ISO date strings: [start, end]. Default: last 30 days.",
      items = property_string("Date", "ISO date YYYY-MM-DD."),
      min_items = 2, max_items = 2
    ),
    dimensions = prop_string_array(
      "Dimensions",
      "Dimension ids. Up to 20. Order affects performance heavily — see tool description."
    ),
    metrics = prop_string_array("Metrics", "Metric ids (regular or calculated)."),
    top = property_array(
      "Top",
      "Per-level cap. Single value caps every level; a vector caps each breakdown. Use 0 in the first slot when the first dim is a daterange to return all date buckets.",
      items = property_number("N", "Row cap.", integer = TRUE)
    ),
    page = property_number("Page", "Zero-based page used with `top`. Default 0.", integer = TRUE),
    filterType = property_string("Filter type", "Currently only 'breakdown' is supported."),
    segmentId = prop_string_array("Segment IDs", "One or more filter (segment) ids ANDed together."),
    metricSort = prop_string_array("Metric sort", "'asc' or 'desc' per metric. Default 'desc'."),
    include_unspecified = property_boolean("Include unspecified", "Include the 'Unspecified (None)' bucket. Default TRUE."),
    search = prop_string_array(
      "Search",
      "Per-dimension search filter strings (case-insensitive). Operators: AND, OR, NOT, MATCH, CONTAINS, BEGINS-WITH, ENDS-WITH. Default operator CONTAINS."
    ),
    prettynames = property_boolean("Pretty names", "Use UI-style column names instead of API ids. Default FALSE."),
    allowRemoteLoad = property_enum("Allow remote load", "Allow Oberon to remote load.", values = c("default", "true", "false")),
    useCache = property_boolean("Use cache", "Component cache for permission checks. Default TRUE."),
    useResultsCache = property_boolean("Use results cache", "Pass-through Oberon results cache. Default FALSE."),
    includeOberonXml = property_boolean("Include Oberon XML", "Debug only. Default FALSE."),
    includePlatformPredictiveObjects = property_boolean("Include platform predictive objects", "Debug only. Default FALSE."),
    debug = prop_debug(),
    check_components = property_boolean("Check components", "Validate metric/dimension ids before query. Default FALSE.")
  )),
  handler = make_handler(cja_freeform_table, as_date = "date_range")
)

# ---------------------------------------------------------------------------
# Tool: filter_rule
# ---------------------------------------------------------------------------

tool_filter_rule <- new_tool(
  name = "filter_rule",
  description = paste(
    "Build a single rule (predicate) for a CJA filter. Returns the rule as a JSON object",
    "that can be passed to filter_con, filter_seq, or filter_build via their respective JSON args.",
    "Exactly one of `dimension` or `metric` must be specified.",
    sep = " "
  ),
  input_schema = schema(properties = list(
    dimension = property_string("Dimension ID", "Dimension id (mutually exclusive with metric)."),
    metric = property_string("Metric ID", "Metric id (mutually exclusive with dimension)."),
    verb = property_string("Verb", "The verb (operator). See filter_verbs tool for all 30+ options.", required = TRUE),
    object = property_string("Object", "The value(s) the rule compares against. JSON-encode arrays if needed."),
    description = property_string("Description", "Optional internal description."),
    is_distinct = property_boolean("Is distinct", "Filter by distinct count within a dimension. Default FALSE."),
    attribution = property_enum("Attribution", "Attribution model.", values = c("repeating", "instance", "nonrepeating")),
    attribution_context = property_enum("Attribution context", "Context for nonrepeating attribution.", values = c("visitors", "visits")),
    validate = property_boolean("Validate", "Validate metric/dimension against the data view. Default FALSE."),
    dataviewId = property_string("Data view ID", "Required if validate=TRUE; falls back to CJA_DATAVIEW_ID.")
  )),
  handler = function(input) {
    # `object` may be a scalar or a JSON-encoded array — try to parse as JSON first.
    obj <- input$object
    if (!is.null(obj) && nzchar(obj)) {
      parsed <- tryCatch(jsonlite::fromJSON(obj), error = function(e) NULL)
      if (!is.null(parsed)) obj <- parsed
    }
    args <- prepare_args(input)
    if (!is.null(obj)) args$object <- obj
    result <- do.call(filter_rule, args)
    json_response(result)
  }
)

# ---------------------------------------------------------------------------
# Tool: filter_con
# ---------------------------------------------------------------------------

tool_filter_con <- new_tool(
  name = "filter_con",
  description = paste(
    "Combine one or more rules (from filter_rule) into a filter container.",
    "Returns a JSON list object suitable for filter_build's `containers` argument.",
    sep = " "
  ),
  input_schema = schema(properties = list(
    context = property_enum("Context", "Level the filter operates on.", values = c("hits", "visits", "visitors")),
    conjunction = property_enum("Conjunction", "How rules combine.", values = c("and", "or")),
    rules = property_string(
      "Rules JSON",
      "JSON array of rule objects from filter_rule. Pass the JSON string directly.",
      required = TRUE
    ),
    exclude = property_boolean("Exclude", "Negate the container. Default FALSE.")
  )),
  handler = function(input) {
    rules <- parse_json_arg(input$rules)
    args <- list(rules = rules)
    if (!is.null(input$context)) args$context <- input$context
    if (!is.null(input$conjunction)) args$conjunction <- input$conjunction
    if (!is.null(input$exclude)) args$exclude <- input$exclude
    result <- do.call(filter_con, args)
    json_response(result)
  }
)

# ---------------------------------------------------------------------------
# Tool: filter_seq
# ---------------------------------------------------------------------------

tool_filter_seq <- new_tool(
  name = "filter_seq",
  description = paste(
    "Combine rules into a sequence container (ordered/unordered checkpoint sequence).",
    "Returns a JSON list object suitable for filter_build's `sequences` argument.",
    sep = " "
  ),
  input_schema = schema(properties = list(
    context = property_enum("Context", "Sequence context.", values = c("hits", "visits", "visitors")),
    rules = property_string(
      "Rules JSON",
      "JSON array of rules (and/or filter_then objects) in checkpoint order.",
      required = TRUE
    ),
    sequence = property_enum(
      "Sequence type",
      "How items are evaluated.",
      values = c("in_order", "before", "after", "and", "or")
    ),
    exclude = property_boolean("Exclude", "Negate the sequence container. Default FALSE."),
    exclude_checkpoint = property_array(
      "Exclude checkpoint",
      "Indices of checkpoints to exclude (e.g. [2] excludes the 2nd rule).",
      items = property_number("Index", "Checkpoint index (1-based).", integer = TRUE)
    )
  )),
  handler = function(input) {
    rules <- parse_json_arg(input$rules)
    args <- list(rules = rules)
    if (!is.null(input$context)) args$context <- input$context
    if (!is.null(input$sequence)) args$sequence <- input$sequence
    if (!is.null(input$exclude)) args$exclude <- input$exclude
    if (!is.null(input$exclude_checkpoint)) args$exclude_checkpoint <- unlist(input$exclude_checkpoint)
    result <- do.call(filter_seq, args)
    json_response(result)
  }
)

# ---------------------------------------------------------------------------
# Tool: filter_then
# ---------------------------------------------------------------------------

tool_filter_then <- new_tool(
  name = "filter_then",
  description = paste(
    "Create a time-restriction object ('then ... within/after N units') used between checkpoints in filter_seq.",
    "Returns a JSON list object that can be inserted into the rules array for filter_seq.",
    sep = " "
  ),
  input_schema = schema(properties = list(
    limit = prop_string_array("Limit", "'within' (default) or 'after'. Length-1 or length-2 vector."),
    count = property_array(
      "Count",
      "Number of units. Length-1 or length-2.",
      items = property_number("N", "Count.", integer = TRUE)
    ),
    unit = prop_string_array(
      "Unit",
      "Time unit. One of: hit, visit, minute, hour, day, week (default), month, quarter, year."
    )
  )),
  handler = make_handler(filter_then)
)

# ---------------------------------------------------------------------------
# Tool: filter_build
# ---------------------------------------------------------------------------

tool_filter_build <- new_tool(
  name = "filter_build",
  description = paste(
    "Compose rules, containers, and/or sequences into a complete CJA filter (segment).",
    "By default returns the segment JSON without creating it; set create_filter=TRUE to POST it.",
    "Exactly one of `rules`, `containers`, or `sequences` should be provided as a JSON array string.",
    sep = " "
  ),
  input_schema = schema(properties = list(
    dataviewId = property_string("Data view ID", "Required. Falls back to CJA_DATAVIEW_ID."),
    name = property_string("Name", "Filter display name.", required = TRUE),
    description = property_string("Description", "Filter description.", required = TRUE),
    containers = property_string("Containers JSON", "JSON array of container objects from filter_con."),
    rules = property_string("Rules JSON", "JSON array of rule objects from filter_rule."),
    sequences = property_string("Sequences JSON", "JSON array of sequence objects from filter_seq."),
    context = property_enum("Context", "Top-level container context.", values = c("hits", "visits", "visitors")),
    conjunction = property_enum("Conjunction", "How multiple items combine.", values = c("and", "or")),
    sequence = property_enum("Sequence type", "Only when sequences provided.", values = c("in_order", "before", "after")),
    sequence_context = property_enum("Sequence context", "Sub-container context for sequences.", values = c("hits", "visits", "visitors")),
    exclude = property_boolean("Exclude", "Negate the top-level container. Default FALSE."),
    create_filter = property_boolean("Create filter", "POST the filter to CJA if TRUE. Default FALSE (return JSON only)."),
    locale = prop_locale(),
    expansion = property_string("Expansion", "Comma-delimited extra fields when create_filter=TRUE."),
    debug = prop_debug()
  )),
  handler = function(input) {
    args <- list(
      containers = parse_json_arg(input$containers),
      rules = parse_json_arg(input$rules),
      sequences = parse_json_arg(input$sequences)
    )
    for (nm in c("dataviewId", "name", "description", "context", "conjunction",
                 "sequence", "sequence_context", "exclude", "create_filter",
                 "locale", "expansion", "debug")) {
      val <- input[[nm]]
      if (!is.null(val)) args[[nm]] <- val
    }
    result <- do.call(filter_build, args)
    json_response(result)
  }
)

# ---------------------------------------------------------------------------
# Tool: filter_val
# ---------------------------------------------------------------------------

tool_filter_val <- new_tool(
  name = "filter_val",
  description = "Validate a filter JSON body against the CJA filters/validate endpoint.",
  input_schema = schema(properties = list(
    filter_body = property_string("Filter body JSON", "The JSON-encoded filter definition to validate.", required = TRUE),
    debug = prop_debug()
  )),
  handler = function(input) {
    result <- filter_val(filter_body = input$filter_body, debug = isTRUE(input$debug))
    json_response(result)
  }
)

# ---------------------------------------------------------------------------
# Tool: filter_verbs
# ---------------------------------------------------------------------------

tool_filter_verbs <- new_tool(
  name = "filter_verbs",
  description = "Return the catalogue of verbs (operators) available for use in filter_rule, with type/class/description.",
  input_schema = schema(properties = list(
    placeholder = property_string("Unused", "This tool takes no parameters; the field is ignored.")
  )),
  handler = function(input) {
    csv_path <- system.file("extdata", "filter_verbs.csv", package = "cjar")
    verbs <- if (nzchar(csv_path)) utils::read.csv(csv_path) else cjar::filter_verbs
    json_response(verbs)
  }
)

# ---------------------------------------------------------------------------
# Tool: cja_auth (manual reauth)
# ---------------------------------------------------------------------------

tool_cja_auth <- new_tool(
  name = "cja_auth",
  description = paste(
    "Force a new authentication using credentials from Sys.getenv('CJA_AUTH_FILE').",
    "Normally not needed — startup auth and lazy token refresh handle this automatically.",
    sep = " "
  ),
  input_schema = schema(properties = list(
    type = property_enum("Auth type", "Authentication type.", values = c("s2s", "jwt", "oauth"))
  )),
  handler = function(input) {
    tryCatch(
      {
        if (!is.null(input$type)) cja_auth(type = input$type) else cja_auth()
        mcpr::response_text("Authenticated.")
      },
      error = function(e) mcpr::response_error(conditionMessage(e))
    )
  }
)

# ---------------------------------------------------------------------------
# Tool: cja_auth_with / cja_auth_path / cja_auth_name
# ---------------------------------------------------------------------------

tool_cja_auth_with <- new_tool(
  name = "cja_auth_with",
  description = "Get or set the cjar.auth_type option for the session. Pass no args to read current value.",
  input_schema = schema(properties = list(
    type = property_enum("Auth type", "Set the session auth type.", values = c("s2s", "jwt", "oauth"))
  )),
  handler = function(input) {
    val <- if (is.null(input$type)) cja_auth_with() else cja_auth_with(input$type)
    json_response(list(cjar.auth_type = val))
  }
)

tool_cja_auth_path <- new_tool(
  name = "cja_auth_path",
  description = "Get or set the cjar.auth_path option (directory for cached token).",
  input_schema = schema(properties = list(
    path = property_string("Path", "Directory path for the cached token.")
  )),
  handler = function(input) {
    val <- if (is.null(input$path)) cja_auth_path() else cja_auth_path(input$path)
    json_response(list(cjar.auth_path = val))
  }
)

tool_cja_auth_name <- new_tool(
  name = "cja_auth_name",
  description = "Get or set the cjar.auth_name option (filename for cached token).",
  input_schema = schema(properties = list(
    name = property_string("Name", "Filename for the cached token (default 'cja_auth.rds').")
  )),
  handler = function(input) {
    val <- if (is.null(input$name)) cja_auth_name() else cja_auth_name(input$name)
    json_response(list(cjar.auth_name = val))
  }
)

# ---------------------------------------------------------------------------
# Assemble and serve
# ---------------------------------------------------------------------------

server <- new_server(
  name = "cja-mcp",
  description = "MCP server exposing Adobe Customer Journey Analytics via the cjar R package.",
  version = "0.1.0"
)

tools <- list(
  tool_cja_auth,
  tool_cja_auth_with,
  tool_cja_auth_path,
  tool_cja_auth_name,
  tool_get_me,
  tool_get_dataviews,
  tool_get_dimensions,
  tool_get_metrics,
  tool_get_calculatedmetrics,
  tool_get_filters,
  tool_get_filter,
  tool_get_dateranges,
  tool_get_projects,
  tool_get_project_config,
  tool_get_audit_logs,
  tool_get_audit_logs_search,
  tool_freeform_table,
  tool_filter_verbs,
  tool_filter_rule,
  tool_filter_con,
  tool_filter_seq,
  tool_filter_then,
  tool_filter_build,
  tool_filter_val
)

for (tool in tools) {
  server <- add_capability(server, tool)
}

log_stderr("Registered ", length(tools), " tools. Listening on stdio.")

# mcpr's serve_io calls readLines("stdin", n=1) inside the loop, which on
# Windows Rscript reopens stdin each iteration and only ever reads the first
# line. Open the connection once and reuse it; otherwise behaves identically
# to mcpr::serve_io.
serve_io_persistent <- function(mcp) {
  con <- file("stdin", open = "r", blocking = TRUE)
  on.exit(close(con), add = TRUE)
  repeat {
    line <- readLines(con, n = 1, warn = FALSE)
    if (length(line) == 0) break
    response <- mcpr:::parse_request(line, mcp)
    if (!length(response)) next
    mcpr:::send(response, stdout())
  }
}

serve_io_persistent(server)
