class BatchJobMonitor
  class << self
    # Get comprehensive status of a batch job
    # @param job_id [Integer] The ID of the batch Job
    # @return [Hash] Detailed status information
    def status_report(job_id)
      job = Job.find(job_id)
      job_records = job.job_records.includes(:loan_application, :events, :rpa_uploads)
      
      {
        job_info: build_job_info(job),
        progress_summary: build_progress_summary(job, job_records),
        state_breakdown: build_state_breakdown(job_records),
        performance_metrics: build_performance_metrics(job, job_records),
        recent_events: build_recent_events(job),
        failed_records: build_failed_records(job_records),
        sample_records: build_sample_records(job_records)
      }
    end

    # Get batch jobs by status or organization
    # @param organization_id [Integer] Optional organization filter
    # @param status [String] Optional status filter ("running", "completed", "failed")
    # @param limit [Integer] Maximum number of jobs to return
    # @return [Array<Hash>] List of batch jobs with summary info
    def list_batch_jobs(organization_id: nil, status: nil, limit: 50)
      jobs_query = Job.where(agent_type: "PAY_STUB_COLLECTOR")
                      .where("total_records > ?", 1) # Only batch jobs (more than 1 record)
                      .includes(:organization, :user)
                      .order(created_at: :desc)
                      .limit(limit)

      jobs_query = jobs_query.where(organization_id: organization_id) if organization_id
      jobs_query = jobs_query.where(status: status) if status

      jobs_query.map do |job|
        {
          job_id: job.id,
          organization: job.organization.name,
          triggered_by: job.user.name,
          trigger_source: job.trigger_source,
          status: job.status,
          total_records: job.total_records,
          created_at: job.created_at,
          started_at: job.started_at,
          completed_at: job.completed_at,
          duration: job.completed_at ? (job.completed_at - job.started_at) : nil,
          progress_summary: calculate_quick_progress(job)
        }
      end
    end

    # Get all currently running batch jobs across organizations
    # @return [Array<Hash>] Running batch jobs with progress info
    def running_batch_jobs
      list_batch_jobs(status: "running").select do |job|
        job[:status] == "running"
      end
    end

    # Get performance metrics for batch processing over time
    # @param organization_id [Integer] Optional organization filter
    # @param days_back [Integer] Number of days to look back (default: 7)
    # @return [Hash] Performance analytics
    def performance_analytics(organization_id: nil, days_back: 7)
      start_date = days_back.days.ago.beginning_of_day
      
      jobs_query = Job.where(agent_type: "PAY_STUB_COLLECTOR")
                      .where("total_records > ?", 1)
                      .where("created_at >= ?", start_date)
                      .where.not(status: "running")

      jobs_query = jobs_query.where(organization_id: organization_id) if organization_id
      
      completed_jobs = jobs_query.to_a

      return {} if completed_jobs.empty?

      {
        summary: {
          total_batch_jobs: completed_jobs.size,
          total_records_processed: completed_jobs.sum(&:total_records),
          avg_batch_size: (completed_jobs.sum(&:total_records).to_f / completed_jobs.size).round(1),
          success_rate: calculate_batch_success_rate(completed_jobs)
        },
        performance: {
          avg_duration_minutes: calculate_avg_duration(completed_jobs),
          avg_records_per_second: calculate_avg_throughput(completed_jobs),
          fastest_job: find_fastest_job(completed_jobs),
          slowest_job: find_slowest_job(completed_jobs)
        },
        daily_breakdown: build_daily_breakdown(completed_jobs, start_date)
      }
    end

    private

    def build_job_info(job)
      {
        id: job.id,
        organization: job.organization.name,
        triggered_by: job.user.name,
        trigger_source: job.trigger_source,
        status: job.status,
        total_records: job.total_records,
        created_at: job.created_at,
        started_at: job.started_at,
        completed_at: job.completed_at,
        duration_seconds: job.completed_at ? (job.completed_at - job.started_at) : nil
      }
    end

    def build_progress_summary(job, job_records)
      total = job.total_records
      states = job_records.group(:state).count
      
      completed_states = %w[completed succeeded verified]
      failed_states = %w[failed]
      in_progress_states = %w[triggered queued processing collecting uploading]
      
      completed = states.select { |state, _| completed_states.include?(state) }.values.sum
      failed = states.select { |state, _| failed_states.include?(state) }.values.sum
      in_progress = states.select { |state, _| in_progress_states.include?(state) }.values.sum
      
      {
        total_records: total,
        completed: completed,
        failed: failed,
        in_progress: in_progress,
        not_started: total - (completed + failed + in_progress),
        completion_percentage: total > 0 ? (completed.to_f / total * 100).round(1) : 0,
        success_rate: (completed + failed) > 0 ? (completed.to_f / (completed + failed) * 100).round(1) : 0
      }
    end

    def build_state_breakdown(job_records)
      job_records.group(:state).count.transform_keys(&:to_s)
    end

    def build_performance_metrics(job, job_records)
      return {} unless job.started_at

      elapsed_time = job.completed_at ? (job.completed_at - job.started_at) : (Time.current - job.started_at)
      processed_count = job_records.where.not(state: %w[triggered queued]).count
      
      {
        elapsed_time_seconds: elapsed_time.round(1),
        records_processed: processed_count,
        records_per_second: processed_count > 0 ? (processed_count / elapsed_time).round(2) : 0,
        estimated_completion: estimate_completion_time(job, job_records, elapsed_time),
        throughput_trend: calculate_throughput_trend(job, job_records)
      }
    end

    def build_recent_events(job)
      Event.where(job: job)
           .order(ts: :desc)
           .limit(20)
           .map do |event|
        {
          timestamp: event.ts,
          event_type: event.event_type,
          phase: event.phase,
          severity: event.severity,
          message: event.message,
          job_record_id: event.job_record_id
        }
      end
    end

    def build_failed_records(job_records)
      job_records.where(state: "failed")
                 .includes(:loan_application)
                 .limit(10)
                 .map do |jr|
        {
          job_record_id: jr.id,
          loan_application: {
            id: jr.loan_application.id,
            applicant_id: jr.loan_application.applicant_id,
            los_external_id: jr.loan_application.los_external_id
          },
          retry_count: jr.retry_count,
          last_error_code: jr.last_error_code,
          last_error_msg: jr.last_error_msg,
          next_attempt_at: jr.next_attempt_at
        }
      end
    end

    def build_sample_records(job_records)
      %w[completed in_progress failed].map do |category|
        sample_states = case category
                       when "completed" then %w[completed succeeded verified]
                       when "in_progress" then %w[collecting uploading processing]
                       when "failed" then %w[failed]
                       end

        records = job_records.where(state: sample_states)
                             .includes(:loan_application)
                             .limit(5)
                             .map do |jr|
          {
            job_record_id: jr.id,
            state: jr.state,
            loan_application: {
              applicant_id: jr.loan_application.applicant_id,
              los_external_id: jr.loan_application.los_external_id
            },
            retry_count: jr.retry_count,
            updated_at: jr.updated_at
          }
        end

        {
          category: category,
          count: job_records.where(state: sample_states).count,
          sample_records: records
        }
      end
    end

    def calculate_quick_progress(job)
      job_records = job.job_records
      total = job.total_records
      completed = job_records.where(state: %w[completed succeeded verified]).count
      
      {
        completed: completed,
        total: total,
        percentage: total > 0 ? (completed.to_f / total * 100).round(1) : 0
      }
    end

    def estimate_completion_time(job, job_records, elapsed_time)
      return nil unless job.status == "running"
      
      processed = job_records.where.not(state: %w[triggered queued]).count
      remaining = job.total_records - processed
      
      return nil if processed == 0
      
      rate = processed / elapsed_time
      estimated_seconds = remaining / rate
      
      {
        estimated_seconds_remaining: estimated_seconds.round,
        estimated_completion_at: Time.current + estimated_seconds.seconds
      }
    end

    def calculate_throughput_trend(job, job_records)
      # Sample throughput over the last hour vs first hour
      now = Time.current
      one_hour_ago = 1.hour.ago
      
      recent_processed = job_records.joins(:events)
                                   .where(events: { event_type: "batch_record_queued" })
                                   .where(events: { ts: one_hour_ago..now })
                                   .count
      
      return "stable" if recent_processed == 0
      
      recent_rate = recent_processed / 3600.0 # per second
      
      if job.started_at && job.started_at < one_hour_ago
        early_processed = job_records.joins(:events)
                                     .where(events: { event_type: "batch_record_queued" })
                                     .where(events: { ts: job.started_at..(job.started_at + 1.hour) })
                                     .count
        early_rate = early_processed / 3600.0
        
        if recent_rate > early_rate * 1.1
          "improving"
        elsif recent_rate < early_rate * 0.9
          "declining"
        else
          "stable"
        end
      else
        "stable"
      end
    end

    def calculate_batch_success_rate(jobs)
      return 0 if jobs.empty?
      
      successful_jobs = jobs.count { |job| job.status == "completed" }
      (successful_jobs.to_f / jobs.size * 100).round(1)
    end

    def calculate_avg_duration(jobs)
      completed_jobs = jobs.select { |job| job.completed_at && job.started_at }
      return 0 if completed_jobs.empty?
      
      total_duration = completed_jobs.sum { |job| job.completed_at - job.started_at }
      (total_duration / completed_jobs.size / 60).round(1) # in minutes
    end

    def calculate_avg_throughput(jobs)
      completed_jobs = jobs.select { |job| job.completed_at && job.started_at }
      return 0 if completed_jobs.empty?
      
      total_throughput = completed_jobs.sum do |job|
        duration = job.completed_at - job.started_at
        job.total_records / duration
      end
      
      (total_throughput / completed_jobs.size).round(2)
    end

    def find_fastest_job(jobs)
      fastest = jobs.select { |job| job.completed_at && job.started_at }
                    .min_by { |job| job.completed_at - job.started_at }
      
      return nil unless fastest
      
      {
        job_id: fastest.id,
        duration_seconds: (fastest.completed_at - fastest.started_at).round(1),
        records: fastest.total_records,
        throughput: (fastest.total_records / (fastest.completed_at - fastest.started_at)).round(2)
      }
    end

    def find_slowest_job(jobs)
      slowest = jobs.select { |job| job.completed_at && job.started_at }
                    .max_by { |job| job.completed_at - job.started_at }
      
      return nil unless slowest
      
      {
        job_id: slowest.id,
        duration_seconds: (slowest.completed_at - slowest.started_at).round(1),
        records: slowest.total_records,
        throughput: (slowest.total_records / (slowest.completed_at - slowest.started_at)).round(2)
      }
    end

    def build_daily_breakdown(jobs, start_date)
      jobs.group_by { |job| job.created_at.to_date }
          .transform_values do |day_jobs|
            {
              job_count: day_jobs.size,
              total_records: day_jobs.sum(&:total_records),
              avg_batch_size: (day_jobs.sum(&:total_records).to_f / day_jobs.size).round(1),
              success_rate: calculate_batch_success_rate(day_jobs)
            }
          end
    end
  end
end
