# =============================================================================
# Dashboard: "Larkspur Ridge Smart Lighting", five pages, each for a different
# audience in the demo (the panel can play these roles):
#
#   1. Executive            city leadership / executive buyer: are the lights
#                           working, are we meeting our promise, what is open
#   2. Lighting Operations  operations: which devices, which districts
#   3. Golden Signals       SRE: latency, traffic, errors, saturation
#   4. MELT                 the assignment's requirement: Metrics, Events,
#                           Logs and Traces in one place, from several agents
#   5. AWS and Log Archive  cloud team: EC2, Lambda export, S3 archive
#
# Every widget is a NRQL query, so anything shown here can be opened, edited
# and reused in the query builder.
# =============================================================================

locals {
  slo_light = newrelic_service_level.light_response.sli_guid
  slo_avail = newrelic_service_level.api_availability.sli_guid
  slo_lat   = newrelic_service_level.api_latency.sli_guid
}

resource "newrelic_one_dashboard" "lighting" {
  name        = "Larkspur Ridge Smart Lighting"
  permissions = "public_read_only"

  # ---------------------------------------------------------------------------
  page {
    name = "Executive"

    widget_markdown {
      title  = ""
      row    = 1
      column = 1
      width  = 12
      height = 1
      text   = "**City of Larkspur Ridge, Tennessee (fictional): Smart Lighting program.** 48 LED streetlights and 12 traffic signals in four districts. Our promise to residents: a light responds to a command within 2 seconds, 99% of the time."
    }

    widget_billboard {
      title    = "Promise kept: commands answered within 2 s (7 days)"
      row      = 2
      column   = 1
      width    = 3
      height   = 3
      critical = 99
      nrql_query {
        query = "FROM Metric SELECT clamp_max(sum(newrelic.sli.good) / sum(newrelic.sli.valid) * 100, 100) AS 'SLO attainment %' WHERE sli.guid = '${local.slo_light}' SINCE 7 days ago"
      }
    }

    widget_billboard {
      title  = "Devices online now"
      row    = 2
      column = 4
      width  = 3
      height = 3
      nrql_query {
        query = "SELECT uniqueCount(deviceId) AS 'of 60 devices' FROM LightingCheckIn SINCE 2 minutes ago"
      }
    }

    widget_billboard {
      title  = "Lamps reporting a fault"
      row    = 2
      column = 7
      width  = 3
      height = 3
      nrql_query {
        query = "SELECT uniqueCount(deviceId) AS 'Faulty lamps' FROM LightingCheckIn WHERE lampOk IS false SINCE 5 minutes ago"
      }
    }

    widget_billboard {
      title  = "Crews dispatched (24 h)"
      row    = 2
      column = 10
      width  = 3
      height = 3
      nrql_query {
        query = "FROM Span SELECT count(*) AS 'Work orders' WHERE service.name = 'lighting-crew-dispatch' AND name = 'assign_crew' SINCE 1 day ago"
      }
    }

    widget_line {
      title  = "How long lights take to respond, by district (95th percentile, ms)"
      row    = 5
      column = 1
      width  = 8
      height = 3
      nrql_query {
        query = "SELECT percentile(ackMs, 95) FROM LightCommand FACET district SINCE 3 hours ago TIMESERIES"
      }
    }

    widget_billboard {
      title  = "Service level objectives (7 days)"
      row    = 5
      column = 9
      width  = 4
      height = 3
      nrql_query {
        query = "FROM Metric SELECT clamp_max(filter(sum(newrelic.sli.good), WHERE sli.guid = '${local.slo_avail}') / filter(sum(newrelic.sli.valid), WHERE sli.guid = '${local.slo_avail}') * 100, 100) AS 'API availability %', clamp_max(filter(sum(newrelic.sli.good), WHERE sli.guid = '${local.slo_lat}') / filter(sum(newrelic.sli.valid), WHERE sli.guid = '${local.slo_lat}') * 100, 100) AS 'API under 500 ms %' SINCE 7 days ago"
      }
    }

    widget_bar {
      title  = "Outage reports by district (24 h)"
      row    = 8
      column = 1
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT count(*) FROM Transaction WHERE appName = 'lighting-api' AND name LIKE '%report_outage%' FACET district SINCE 1 day ago"
      }
    }

    widget_table {
      title  = "Open incidents"
      row    = 8
      column = 7
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT latest(title) AS 'Incident', latest(priority) AS 'Priority' FROM NrAiIncident WHERE policyName = 'Larkspur Ridge Smart Lighting' AND event = 'open' FACET incidentId SINCE 1 day ago LIMIT 20"
      }
    }
  }

  # ---------------------------------------------------------------------------
  page {
    name = "Lighting Operations"

    widget_table {
      title  = "Every device right now"
      row    = 1
      column = 1
      width  = 7
      height = 5
      nrql_query {
        query = "SELECT latest(kind) AS 'Type', latest(district) AS 'District', latest(lampOk) AS 'Lamp OK', latest(powerW) AS 'Watts', max(timestamp) AS 'Last check-in' FROM LightingCheckIn FACET deviceId SINCE 5 minutes ago LIMIT 100"
      }
    }

    widget_table {
      title  = "Slowest devices to respond (last hour)"
      row    = 1
      column = 8
      width  = 5
      height = 5
      nrql_query {
        query = "SELECT max(ackMs) AS 'Slowest ms', average(ackMs) AS 'Avg ms', count(*) AS 'Commands' FROM LightCommand FACET deviceId, district SINCE 1 hour ago LIMIT 15"
      }
    }

    widget_histogram {
      title  = "Command acknowledgement time distribution (ms)"
      row    = 6
      column = 1
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT histogram(ackMs, 10000, 20) FROM LightCommand SINCE 1 hour ago"
      }
    }

    widget_line {
      title  = "On-time commands % by device type"
      row    = 6
      column = 7
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT percentage(count(*), WHERE ackMs <= 2000) FROM LightCommand FACET kind SINCE 3 hours ago TIMESERIES"
      }
    }

    widget_bar {
      title  = "Commands sent by type (last hour)"
      row    = 9
      column = 1
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT count(*) FROM LightCommand FACET command SINCE 1 hour ago"
      }
    }

    widget_line {
      title  = "Devices checking in"
      row    = 9
      column = 7
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT uniqueCount(deviceId) FROM LightingCheckIn FACET kind SINCE 3 hours ago TIMESERIES 1 minute"
      }
    }
  }

  # ---------------------------------------------------------------------------
  page {
    name = "Golden Signals"

    widget_line {
      title  = "Latency: 95th percentile response time (s), agent and OpenTelemetry services"
      row    = 1
      column = 1
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT percentile(duration, 95) FROM Transaction WHERE appName LIKE 'lighting-%' AND transactionType = 'Web' FACET appName SINCE 3 hours ago TIMESERIES"
      }
      nrql_query {
        query = "FROM Span SELECT percentile(duration.ms, 95) / 1000 AS 'lighting-crew-dispatch' WHERE service.name = 'lighting-crew-dispatch' AND span.kind = 'server' SINCE 3 hours ago TIMESERIES"
      }
    }

    widget_line {
      title  = "Traffic: requests per minute"
      row    = 1
      column = 7
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT rate(count(*), 1 minute) FROM Transaction WHERE appName LIKE 'lighting-%' AND transactionType = 'Web' FACET appName SINCE 3 hours ago TIMESERIES"
      }
    }

    widget_line {
      title  = "Errors: % of requests"
      row    = 4
      column = 1
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT percentage(count(*), WHERE error IS true) FROM Transaction WHERE appName LIKE 'lighting-%' AND transactionType = 'Web' FACET appName SINCE 3 hours ago TIMESERIES"
      }
    }

    widget_line {
      title  = "Saturation: CPU % per host and container"
      row    = 4
      column = 7
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT average(cpuPercent) FROM SystemSample WHERE hostname LIKE 'lighting-%' OR clusterName = '${var.k8s_cluster_name}' FACET hostname SINCE 3 hours ago TIMESERIES"
      }
      nrql_query {
        query = "SELECT average(cpuCoresUtilization) FROM K8sContainerSample WHERE namespaceName = 'lighting' FACET containerName SINCE 3 hours ago TIMESERIES"
      }
    }

    widget_line {
      title  = "Database: time per request spent in PostgreSQL (s)"
      row    = 7
      column = 1
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT average(databaseDuration) FROM Transaction WHERE appName = 'lighting-api' FACET name SINCE 3 hours ago TIMESERIES LIMIT 5"
      }
    }

    widget_line {
      title  = "Cache: Redis hit rate %"
      row    = 7
      column = 7
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT average(db.keyspaceHitsPerSecond) / (average(db.keyspaceHitsPerSecond) + average(db.keyspaceMissesPerSecond)) * 100 AS 'Hit rate %' FROM RedisSample SINCE 3 hours ago TIMESERIES"
      }
    }
  }

  # ---------------------------------------------------------------------------
  page {
    name = "MELT"

    widget_markdown {
      title  = ""
      row    = 1
      column = 1
      width  = 12
      height = 1
      text   = "**Metrics, Events, Logs, Traces** from six sources: APM agents (Python, Node.js), OpenTelemetry, Browser, Infrastructure with NGINX/PostgreSQL/Redis integrations, Kubernetes, and AWS."
    }

    widget_line {
      title  = "M: NGINX requests per second and PostgreSQL commits per second (on-host integrations)"
      row    = 2
      column = 1
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT average(net.requestsPerSecond) AS 'NGINX req/s' FROM NginxSample SINCE 3 hours ago TIMESERIES"
      }
      nrql_query {
        query = "SELECT average(db.commitsPerSecond) AS 'PostgreSQL commits/s' FROM PostgresqlDatabaseSample SINCE 3 hours ago TIMESERIES"
      }
    }

    widget_line {
      title  = "M: work orders created (OpenTelemetry custom metric)"
      row    = 2
      column = 7
      width  = 6
      height = 3
      nrql_query {
        query = "FROM Metric SELECT sum(lighting.work_orders.created) FACET district SINCE 3 hours ago TIMESERIES"
      }
    }

    widget_line {
      title  = "E: business events (APM custom events and Browser page actions)"
      row    = 5
      column = 1
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT count(*) FROM LightCommand, LightingCheckIn FACET eventType() SINCE 3 hours ago TIMESERIES"
      }
      nrql_query {
        query = "SELECT count(*) FROM PageAction FACET actionName SINCE 3 hours ago TIMESERIES"
      }
    }

    widget_line {
      title  = "L: log lines by service"
      row    = 5
      column = 7
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT count(*) FROM Log FACET if(entity.name IS NOT NULL, entity.name, if(service.name IS NOT NULL, service.name, service)) SINCE 3 hours ago TIMESERIES"
      }
    }

    widget_log_table {
      title  = "L: warnings and errors across all services"
      row    = 8
      column = 1
      width  = 12
      height = 4
      nrql_query {
        query = "SELECT timestamp, if(entity.name IS NOT NULL, entity.name, if(service.name IS NOT NULL, service.name, service)) AS 'source', level, message FROM Log WHERE level IN ('WARNING', 'WARN', 'ERROR', 'warning', 'error') OR message LIKE '%duration:%' SINCE 1 hour ago LIMIT 50"
      }
    }

    widget_table {
      title  = "T: slowest traces (last hour)"
      row    = 12
      column = 1
      width  = 6
      height = 4
      nrql_query {
        query = "FROM Span SELECT max(duration.ms) AS 'Duration ms', latest(name) AS 'Entry point', uniqueCount(service.name) AS 'Services' WHERE nr.entryPoint IS true OR span.kind = 'server' FACET trace.id SINCE 1 hour ago LIMIT 10"
      }
    }

    widget_bar {
      title  = "T: spans by service (agent and OpenTelemetry)"
      row    = 12
      column = 7
      width  = 6
      height = 4
      nrql_query {
        query = "FROM Span SELECT count(*) FACET if(appName IS NOT NULL, appName, service.name) SINCE 1 hour ago"
      }
    }
  }

  # ---------------------------------------------------------------------------
  page {
    name = "AWS and Log Archive"

    widget_line {
      title  = "EC2 CPU utilization as reported by AWS CloudWatch"
      row    = 1
      column = 1
      width  = 6
      height = 3
      nrql_query {
        query = "FROM Metric SELECT average(aws.ec2.CPUUtilization) FACET aws.ec2.InstanceId SINCE 6 hours ago TIMESERIES"
      }
      # API polling stores AWS data as event samples; this second query reads
      # that form. Whichever form your account receives is the one that draws.
      nrql_query {
        query = "FROM ComputeSample SELECT average(provider.cpuUtilization.Average) WHERE provider = 'Ec2Instance' FACET entityName SINCE 6 hours ago TIMESERIES"
      }
    }

    widget_line {
      title  = "Log export Lambda: invocations and errors"
      row    = 1
      column = 7
      width  = 6
      height = 3
      nrql_query {
        query = "FROM Metric SELECT sum(aws.lambda.Invocations) AS 'Invocations', sum(aws.lambda.Errors) AS 'Errors' WHERE aws.lambda.FunctionName LIKE 'smart-lighting%' SINCE 1 day ago TIMESERIES 1 hour"
      }
      nrql_query {
        query = "FROM ServerlessSample SELECT sum(provider.invocations.Sum) AS 'Invocations', sum(provider.errors.Sum) AS 'Errors' WHERE provider = 'LambdaFunction' AND entityName LIKE 'smart-lighting%' SINCE 1 day ago TIMESERIES 1 hour"
      }
    }

    widget_billboard {
      title  = "S3 log archive size (MB)"
      row    = 4
      column = 1
      width  = 4
      height = 3
      nrql_query {
        query = "FROM Metric SELECT latest(aws.s3.BucketSizeBytes) / 1e6 AS 'MB archived' WHERE aws.s3.BucketName LIKE 'smart-lighting-log-archive%' SINCE 2 days ago"
      }
      nrql_query {
        query = "FROM DatastoreSample SELECT latest(provider.bucketSizeBytes.Average) / 1e6 AS 'MB archived (polling)' WHERE provider = 'S3Bucket' AND entityName LIKE 'smart-lighting-log-archive%' SINCE 2 days ago"
      }
    }

    widget_line {
      title  = "EBS volume write throughput (bytes)"
      row    = 4
      column = 5
      width  = 8
      height = 3
      nrql_query {
        query = "FROM Metric SELECT sum(aws.ebs.VolumeWriteBytes) FACET aws.ebs.VolumeId SINCE 6 hours ago TIMESERIES"
      }
      nrql_query {
        query = "FROM BlockDeviceSample SELECT sum(provider.volumeWriteBytes.Sum) WHERE provider = 'EbsVolume' FACET entityName SINCE 6 hours ago TIMESERIES"
      }
    }
  }
}
