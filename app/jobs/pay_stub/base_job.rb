# frozen_string_literal: true
module PayStub
  class BaseJob < ApplicationJob
    queue_as :pay_stub

    # Common retry policy (align with RetryPolicy "default": 3 attempts, backoff)
    retry_on StandardError, attempts: 3, wait: -> (executions) { executions ** 2 }

    # Optional: use discard_on for non-retriable domain errors
    # discard_on(Agents::NonRetriable) {}

    around_perform do |job, block|
      @started_at = Time.current
      audit(:started, job: job)
      block.call
      audit(:succeeded, job: job)
    rescue => e
      audit(:failed, job: job, error: e)
      raise
    ensure
      @ended_at = Time.current
    end

    private

    # Minimal audit helper writing to events table
    def audit(event_type, job:, error: nil, extra: {})
      jr = job_record
      return unless jr

      Event.create!(
        organization_id: jr.job.organization_id,
        user_id: jr.job.user_id,
        job_id: jr.job_id,
        job_record_id: jr.id,
        event_type: event_type.to_s,          # e.g., "started" | "succeeded" | "failed"
        phase: self.class.name.demodulize.underscore.delete_suffix("_job"),
        severity: (error ? "error" : "info"),
        message: error ? "#{error.class}: #{error.message}" : "OK",
        ts: Time.current,
        trace_id: extra[:trace_id] || SecureRandom.hex(10)
      )
    end

    # Resolve the JobRecord for all phase jobs
    def job_record
      @job_record ||= JobRecord.find_by(id: arguments.first) if arguments.present?
    end

    # Helpers most phases will need
    def with_lock!(jr, &blk)
      # Replace with a DB advisory lock or redis lock if desired
      jr.with_lock { blk.call }
    end
  end
end
