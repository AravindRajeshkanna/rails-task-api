class AttachmentResource < ApplicationResource
  attributes :id

  attribute(:filename) { |attachment| attachment.filename.to_s }
  attribute(:content_type) { |attachment| attachment.content_type }
  attribute(:byte_size) { |attachment| attachment.byte_size }
  attribute(:url) { |attachment| attachment_url(attachment) }
end
