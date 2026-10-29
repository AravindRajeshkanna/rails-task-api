# Lambda entry point: handler "rca.handler"
$LOAD_PATH.unshift(File.join(__dir__, "lib"))
require "aiops/rca"

def handler(event:, context:) = Aiops::Rca.handler(event: event, context: context)
