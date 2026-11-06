namespace :erasure do
  desc "Send user.erased again for people already erased (ADR 79): USER_IDS=41,42 or SINCE=2026-11-01. For an erasure the other services never got: a consumer that was down longer than the queue keeps messages, or people erased before the event existed. Safe to repeat"
  task publish: :environment do
    abort "EVENTS_SNS_TOPIC_ARN is not set: there is nowhere to publish to." unless Events::Outbox.enabled?

    # Only people who have been erased, whatever is asked for: the event makes the Auth service delete an identity, and it must never name someone who has not asked.
    erased = User.where.not(erased_at: nil)
    people =
      if ENV["USER_IDS"].present?
        erased.where(id: ENV["USER_IDS"].split(",").map { |id| Integer(id.strip) })
      elsif ENV["SINCE"].present?
        erased.where(erased_at: Time.zone.parse(ENV["SINCE"]).beginning_of_day..)
      else
        abort "Say whom: USER_IDS=41,42 or SINCE=2026-11-01."
      end

    sent = people.find_each.sum do |user|
      Events::SnsPublisher.publish(Events::Outbox.erasure_envelope(user, auth_subject: user.auth_subject))
      1
    end
    puts "Published user.erased for #{sent} erased #{'person'.pluralize(sent)}."
    skipped = ENV["USER_IDS"].present? ? ENV["USER_IDS"].split(",").size - sent : 0
    puts "#{skipped} of the ids asked for #{skipped == 1 ? 'is' : 'are'} not an erased user and #{skipped == 1 ? 'was' : 'were'} left alone." if skipped.positive?
  end
end
