# Lambda entry point: handler "remediate.handler"
$LOAD_PATH.unshift(File.join(__dir__, "lib"))
require "aiops/remediate"

def handler(event:, context:) = Aiops::Remediate.handler(event: event, context: context)
