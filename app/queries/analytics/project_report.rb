module Analytics
  # Numbers about one project's tasks, computed by the database: counts by status and priority,
  # tasks created and completed per period, how long completed tasks took, and who is carrying
  # what. Everything reads the live (not soft-deleted) tasks; periods are UTC and start on
  # Monday (weeks) or the 1st (months).
  #
  # The interval is mapped through an allow-list before it reaches SQL, never interpolated as given.
  class ProjectReport
    TRUNC_UNITS = { "day" => "day", "week" => "week", "month" => "month" }.freeze
    WORKLOAD_LIMIT = 20

    def initialize(project, form)
      @project = project
      @form = form
      @unit = TRUNC_UNITS.fetch(form.interval)
    end

    def call
      {
        range: { from: @form.from_date, to: @form.to_date, interval: @form.interval },
        totals: totals,
        by_status: by_status,
        by_priority: by_priority,
        throughput: throughput,
        cycle_time_hours: cycle_time_hours,
        workload: workload
      }
    end

    private
      def tasks = @project.tasks.kept

      def window = @form.from_date.in_time_zone("UTC").beginning_of_day..@form.to_date.in_time_zone("UTC").end_of_day

      def by_status
        @by_status ||= begin
          counts = tasks.group(:status).count
          Task.statuses.keys.index_with { |status| counts.fetch(status, 0) }
        end
      end

      # Open work only: what is still to be done is what priorities are for.
      def by_priority
        counts = tasks.where.not(status: :done).group(:priority).count
        Task.priorities.keys.index_with { |priority| counts.fetch(priority, 0) }
      end

      def totals
        open = by_status.except("done").values.sum
        {
          total: by_status.values.sum,
          open: open,
          done: by_status.fetch("done"),
          overdue: tasks.overdue.count,
          unassigned: tasks.where.not(status: :done).where(assignee_id: nil).count
        }
      end

      # Created and completed per period, with empty periods present as zeros so charts need no gap-filling.
      def throughput
        created = per_period(:created_at)
        completed = per_period(:completed_at)

        periods.map { |start| { period: start, created: created.fetch(start, 0), completed: completed.fetch(start, 0) } }
      end

      def per_period(column)
        tasks.where(column => window).group(Arel.sql("date_trunc('#{@unit}', tasks.#{column})")).count
             .transform_keys { |bucket| bucket.to_date }
      end

      def periods
        start = bucket_start(@form.from_date)
        Enumerator.produce(start) { |date| step(date) }.take_while { |date| date <= @form.to_date }
      end

      def bucket_start(date)
        case @unit
        when "week" then date.beginning_of_week(:monday)
        when "month" then date.beginning_of_month
        else date
        end
      end

      def step(date)
        case @unit
        when "week" then date + 7
        when "month" then date.next_month
        else date + 1
        end
      end

      # Elapsed time from creation to completion for tasks finished in the window.
      def cycle_time_hours
        elapsed = "EXTRACT(EPOCH FROM (tasks.completed_at - tasks.created_at))"
        count, median, p90 = tasks.where(completed_at: window).pick(
          Arel.sql("count(*)"),
          Arel.sql("percentile_cont(0.5) WITHIN GROUP (ORDER BY #{elapsed})"),
          Arel.sql("percentile_cont(0.9) WITHIN GROUP (ORDER BY #{elapsed})")
        )

        { sample: count, median: to_hours(median), p90: to_hours(p90) }
      end

      def to_hours(seconds) = seconds&.then { |value| (value.to_f / 3600).round(1) }

      def workload
        overdue = Task.sanitize_sql_array([ "count(*) FILTER (WHERE tasks.due_on < ?)", Date.current ])
        rows = tasks.where.not(status: :done).where.not(assignee_id: nil).group(:assignee_id)
                    .pluck(:assignee_id, Arel.sql("count(*)"), Arel.sql(overdue))
        people = User.where(id: rows.map(&:first)).index_by(&:id)

        rows.sort_by { |_, open, late| [ -late, -open ] }.first(WORKLOAD_LIMIT).map do |assignee_id, open, late|
          { assignee: UserSummaryResource.new(people.fetch(assignee_id)).serializable_hash.symbolize_keys, open: open, overdue: late }
        end
      end
  end
end
