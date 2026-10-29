# Public entry: Route 53 name, ACM certificate, and a WAF in front of the ALB. The ALB is created by the AWS
# Load Balancer Controller from the Ingress annotations (certificate and WAF ARNs come from the outputs).

data "aws_route53_zone" "root" {
  name         = var.root_domain
  private_zone = false
}

resource "aws_acm_certificate" "api" {
  domain_name       = local.api_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "certificate_validation" {
  for_each = {
    for option in aws_acm_certificate.api.domain_validation_options : option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.root.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for record in aws_route53_record.certificate_validation : record.fqdn]
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

resource "aws_route53_record" "api" {
  count = var.alb_exists ? 1 : 0

  zone_id = data.aws_route53_zone.root.zone_id
  name    = local.api_domain
  type    = "A"

  alias {
    name                   = data.aws_lb.api[0].dns_name
    zone_id                = data.aws_lb.api[0].zone_id
    evaluate_target_health = true
  }
}
