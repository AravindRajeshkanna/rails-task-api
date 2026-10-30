# Public entry: Route 53 name, ACM certificate, and a WAF in front of the ALB. The ALB is created by the AWS
# Load Balancer Controller from the Ingress annotations (certificate and WAF ARNs come from the outputs).

data "aws_route53_zone" "root" {
  name         = var.root_domain
  private_zone = false
}

# A certificate is regional, so a standby has one of its own for the same name. ACM gives the same DNS validation record to
# every certificate for a name in an account, so the standby does not manage that record (the primary does): it only waits
# for the certificate to be issued. Destroying the primary's stack would remove the record and stop the standby's renewals.
resource "aws_acm_certificate" "api" {
  domain_name       = local.api_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Keyed by the one name the certificate covers, so the set of records is known when planning; the record values AWS returns
# after the certificate exists only appear in the values.
resource "aws_route53_record" "certificate_validation" {
  for_each = local.is_secondary ? toset([]) : toset([local.api_domain])

  zone_id         = data.aws_route53_zone.root.zone_id
  name            = one([for option in aws_acm_certificate.api.domain_validation_options : option.resource_record_name if option.domain_name == each.key])
  type            = one([for option in aws_acm_certificate.api.domain_validation_options : option.resource_record_type if option.domain_name == each.key])
  records         = [one([for option in aws_acm_certificate.api.domain_validation_options : option.resource_record_value if option.domain_name == each.key])]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = local.is_secondary ? null : [for record in aws_route53_record.certificate_validation : record.fqdn]
}

# --- WAF ---
resource "aws_wafv2_web_acl" "api" {
  name        = local.name
  description = "Task API: managed rule sets plus rate limits"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Sign-in, sign-up and password reset are the credential-stuffing surface: a tight per-IP limit.
  rule {
    name     = "rate-limit-credentials"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 100 # requests per 5 minutes per IP
        aggregate_key_type = "IP"
        scope_down_statement {
          regex_match_statement {
            regex_string = "^/api/v1/(session|registrations|passwords)"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-credentials"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-limit-global"
    priority = 2
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-global"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = {
      "AWSManagedRulesAmazonIpReputationList" = 10
      "AWSManagedRulesCommonRuleSet"          = 11
      "AWSManagedRulesKnownBadInputsRuleSet"  = 12
      "AWSManagedRulesSQLiRuleSet"            = 13
    }
    content {
      name     = rule.key
      priority = rule.value
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          name        = rule.key
          vendor_name = "AWS"

          # The API accepts JSON bodies up to 12 MB (attachments); the common rule set's size rule would block them.
          dynamic "rule_action_override" {
            for_each = rule.key == "AWSManagedRulesCommonRuleSet" ? ["SizeRestrictions_BODY"] : []
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.name
    sampled_requests_enabled   = true
  }
}

resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${local.name}" # WAF requires this prefix
  retention_in_days = 30
}

resource "aws_wafv2_web_acl_logging_configuration" "api" {
  resource_arn            = aws_wafv2_web_acl.api.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
}

# --- DNS to the ALB (after the first deploy) ---
data "aws_lb" "api" {
  count = var.alb_exists ? 1 : 0
  name  = local.alb_name
}

# One name, one load balancer: the single-region case, and the primary until its standby exists. With a standby (local.failover) the
# same record becomes the PRIMARY half of a Route 53 failover pair and is only answered while its health check passes.
# Switching between the two forms replaces the record (Route 53 will not hold both), a gap of a few seconds; do it in a quiet moment.
# A standby never owns the name: the primary's stack points it at the standby when it has to.
resource "aws_route53_record" "api" {
  count = var.alb_exists && !local.is_secondary ? 1 : 0

  zone_id        = data.aws_route53_zone.root.zone_id
  name           = local.api_domain
  type           = "A"
  set_identifier = local.failover ? "primary" : null

  health_check_id = local.failover ? aws_route53_health_check.api[0].id : null

  dynamic "failover_routing_policy" {
    for_each = local.failover ? ["PRIMARY"] : []
    content {
      type = failover_routing_policy.value
    }
  }

  alias {
    name                   = data.aws_lb.api[0].dns_name
    zone_id                = data.aws_lb.api[0].zone_id
    evaluate_target_health = true
  }
}

# --- Failover to the standby (primary stack, once the standby's load balancer exists) ---
# The standby's load balancer lives in the other region; the Ingress there names it task-api-<environment>-dr.
data "aws_lb" "standby" {
  provider = aws.peer
  count    = local.failover ? 1 : 0
  name     = local.peer_name
}

resource "aws_route53_record" "api_standby" {
  count = local.failover ? 1 : 0

  zone_id        = data.aws_route53_zone.root.zone_id
  name           = local.api_domain
  type           = "A"
  set_identifier = "standby"

  failover_routing_policy {
    type = "SECONDARY"
  }

  alias {
    name                   = data.aws_lb.standby[0].dns_name
    zone_id                = data.aws_lb.standby[0].zone_id
    evaluate_target_health = false # the last resort is answered even if it looks unhealthy: better a try than no answer
  }
}

# Checks the primary load balancer directly (by its own name, so the answer cannot depend on the failover record it controls).
# Route 53 does not validate the certificate, and /up is exempt from Rails' host check, so the Host header being the load
# balancer's name does not matter. Three failures in a row, 30 seconds apart, is about a minute and a half to decide.
resource "aws_route53_health_check" "api" {
  count = local.failover ? 1 : 0

  fqdn              = data.aws_lb.api[0].dns_name
  type              = "HTTPS"
  port              = 443
  resource_path     = "/up"
  request_interval  = 30
  failure_threshold = 3
  enable_sni        = true

  tags = {
    Name = "${local.name}-api"
  }
}

# Route 53 publishes health check metrics in us-east-1 only, so this alarm exists only where the alerts topic is there too.
resource "aws_cloudwatch_metric_alarm" "api_failover" {
  count = local.failover && var.region == "us-east-1" ? 1 : 0

  alarm_name          = "${local.name}-dns-failed-over"
  alarm_description   = "The primary region's load balancer failed its health check, so DNS now answers with the standby. Runbook: docs/runbooks/regional-failover.md"
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = aws_route53_health_check.api[0].id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
