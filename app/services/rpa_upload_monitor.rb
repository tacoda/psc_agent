class RpaUploadMonitor
  class << self
    # Get comprehensive status of RPA uploads for monitoring dashboard
    def status_report(organization_id: nil, time_range: 24.hours)
      base_scope = organization_id ? 
        RpaUpload.joins(job_record: :job).where(jobs: { organization_id: organization_id }) :
        RpaUpload.all

      uploads_in_range = base_scope.where(created_at: time_range.ago..Time.current)

      {
        summary: generate_summary(uploads_in_range),
        success_rate: calculate_success_rate(uploads_in_range),
        failure_breakdown: analyze_failures(uploads_in_range),
        retry_analysis: analyze_retries(uploads_in_range),
        performance_metrics: calculate_performance_metrics(uploads_in_range),
        currently_active: count_active_uploads(base_scope),
        pending_retries: count_pending_retries(organization_id),
        recent_events: recent_upload_events(organization_id, limit: 10)
      }
    end

    # Get detailed status for a specific job record
    def job_record_status(job_record_id)
      job_record = JobRecord.find(job_record_id)
      uploads = job_record.rpa_uploads.order(:created_at)
      
      {
        job_record: {
          id: job_record.id,
          state: job_record.state,
          retry_count: job_record.retry_count,
          next_attempt_at: job_record.next_attempt_at,
          last_error: {
            code: job_record.last_error_code,
            message: job_record.last_error_msg
          }
        },
        loan_application: {
          id: job_record.loan_application.id,
          applicant_id: job_record.loan_application.applicant_id,
          los_external_id: job_record.loan_application.los_external_id
        },
        upload_attempts: uploads.map do |upload|
          {
            attempt: upload.attempt,
            status: upload.status,
            started_at: upload.started_at,
            ended_at: upload.ended_at,
            duration: upload.ended_at ? (upload.ended_at - upload.started_at) : nil,
            error: {
              code: upload.error_code,
              message: upload.error_msg
            },
            session_id: upload.los_session_id
          }
        end,
        timeline: build_timeline(job_record)
      }
    end

    # Check for stuck uploads that may need intervention
    def detect_stuck_uploads(threshold_minutes: 30)
      stuck_threshold = threshold_minutes.minutes.ago
      
      stuck_uploads = RpaUpload.joins(job_record: :job)
                               .where(status: "in_progress")
                               .where("started_at < ?", stuck_threshold)
                               .includes(job_record: [:job, :loan_application])

      stuck_uploads.map do |upload|
        {
          rpa_upload_id: upload.id,
          job_record_id: upload.job_record_id,
          session_id: upload.los_session_id,
          started_at: upload.started_at,
          duration_minutes: ((Time.current - upload.started_at) / 60).round,
          loan_application: {
            id: upload.job_record.loan_application.id,
            applicant_id: upload.job_record.loan_application.applicant_id,
            los_external_id: upload.job_record.loan_application.los_external_id
          },
          organization_id: upload.job_record.job.organization_id
        }
      end
    end

    # Escalate stuck uploads to human intervention
    def escalate_stuck_uploads!(threshold_minutes: 30)
      stuck_uploads = detect_stuck_uploads(threshold_minutes: threshold_minutes)
      
      stuck_uploads.each do |stuck_info|
        begin
          upload = RpaUpload.find(stuck_info[:rpa_upload_id])
          job_record = upload.job_record
          
          # Mark upload as failed
          upload.update!(
            status: "failed",
            ended_at: Time.current,
            error_code: "timeout",
            error_msg: "Upload stuck for #{stuck_info[:duration_minutes]} minutes - escalated to human"
          )
          
          # Mark job record as failed and schedule for human review
          job_record.update!(
            state: "failed",
            last_error_code: "timeout",
            last_error_msg: "RPA upload stuck - escalated to human intervention"
          )
          
          # Send escalation notification
          Notifications::EscalateFailure.call!(job_record: job_record)
          
          # Log escalation event
          Event.create!(
            organization_id: job_record.job.organization_id,
            user_id: job_record.job.user_id,
            job_id: job_record.job_id,
            job_record_id: job_record.id,
            event_type: "upload_stuck_escalated",
            phase: "upload",
            severity: "error",
            message: "RPA upload stuck for #{stuck_info[:duration_minutes]} minutes - escalated to human intervention",
            ts: Time.current,
            trace_id: SecureRandom.hex(10)
          )
          
          Rails.logger.error "Escalated stuck upload: job_record #{job_record.id}, stuck for #{stuck_info[:duration_minutes]} minutes"
          
        rescue StandardError => e
          Rails.logger.error "Error escalating stuck upload #{stuck_info[:rpa_upload_id]}: #{e.message}"
        end
      end
      
      stuck_uploads.size
    end

    private

    def generate_summary(uploads)
      total = uploads.count
      succeeded = uploads.where(status: "succeeded").count
      failed = uploads.where(status: "failed").count
      in_progress = uploads.where(status: "in_progress").count
      
      {
        total_uploads: total,
        succeeded: succeeded,
        failed: failed,
        in_progress: in_progress,
        success_percentage: total > 0 ? (succeeded.to_f / total * 100).round(1) : 0
      }
    end

    def calculate_success_rate(uploads)
      completed_uploads = uploads.where(status: ["succeeded", "failed"])
      total_completed = completed_uploads.count
      return 0 if total_completed.zero?
      
      succeeded = completed_uploads.where(status: "succeeded").count
      (succeeded.to_f / total_completed * 100).round(1)
    end

    def analyze_failures(uploads)
      failed_uploads = uploads.where(status: "failed")
      
      failure_counts = failed_uploads.group(:error_code).count
      failure_counts.transform_keys { |code| code || "unknown" }
    end

    def analyze_retries(uploads)
      retry_analysis = uploads.group(:attempt).count
      max_attempts = retry_analysis.keys.max || 0
      
      {
        attempts_distribution: retry_analysis,
        max_attempts_seen: max_attempts,
        first_attempt_success_rate: calculate_first_attempt_success_rate(uploads)
      }
    end

    def calculate_first_attempt_success_rate(uploads)
      first_attempts = uploads.where(attempt: 1)
      total_first = first_attempts.count
      return 0 if total_first.zero?
      
      succeeded_first = first_attempts.where(status: "succeeded").count
      (succeeded_first.to_f / total_first * 100).round(1)
    end

    def calculate_performance_metrics(uploads)
      completed_uploads = uploads.where.not(ended_at: nil)
                                 .where.not(started_at: nil)
      
      return {} if completed_uploads.empty?
      
      durations = completed_uploads.map { |u| u.ended_at - u.started_at }
      
      {
        average_duration_seconds: (durations.sum / durations.size).round(1),
        median_duration_seconds: durations.sort[durations.size / 2].round(1),
        min_duration_seconds: durations.min.round(1),
        max_duration_seconds: durations.max.round(1)
      }
    end

    def count_active_uploads(base_scope)
      base_scope.where(status: "in_progress").count
    end

    def count_pending_retries(organization_id)
      base_scope = JobRecord.joins(:job)
                            .where(jobs: { agent_type: "PAY_STUB_COLLECTOR" })
                            .where(state: ["uploading", "failed"])
                            .where("next_attempt_at <= ?", Time.current)
                            .where("retry_count < ?", 3)
      
      if organization_id
        base_scope = base_scope.where(jobs: { organization_id: organization_id })
      end
      
      base_scope.count
    end

    def recent_upload_events(organization_id, limit: 10)
      events_scope = Event.where(event_type: ["rpa_upload_success", "rpa_upload_failure", "upload_retry_scheduled"])
                          .order(ts: :desc)
                          .limit(limit)
      
      if organization_id
        events_scope = events_scope.where(organization_id: organization_id)
      end
      
      events_scope.map do |event|
        {
          id: event.id,
          event_type: event.event_type,
          severity: event.severity,
          message: event.message,
          timestamp: event.ts,
          job_record_id: event.job_record_id
        }
      end
    end

    def build_timeline(job_record)
      events = Event.where(job_record: job_record)
                   .where(phase: "upload")
                   .order(:ts)
                   
      uploads = job_record.rpa_uploads.order(:created_at)
      
      timeline_events = []
      
      # Add upload attempt events
      uploads.each do |upload|
        timeline_events << {
          timestamp: upload.started_at,
          type: "upload_started",
          details: "Upload attempt #{upload.attempt} started (session: #{upload.los_session_id})"
        }
        
        if upload.ended_at
          timeline_events << {
            timestamp: upload.ended_at,
            type: upload.status == "succeeded" ? "upload_completed" : "upload_failed",
            details: upload.status == "succeeded" ? 
              "Upload attempt #{upload.attempt} completed successfully" :
              "Upload attempt #{upload.attempt} failed: #{upload.error_msg}"
          }
        end
      end
      
      # Add event log entries
      events.each do |event|
        timeline_events << {
          timestamp: event.ts,
          type: event.event_type,
          details: event.message
        }
      end
      
      # Sort by timestamp
      timeline_events.sort_by { |e| e[:timestamp] }
    end
  end
end
