module PayStub
  class BatchAgentJob < BaseJob
    queue_as :pay_stub_batch

    # Process a batch job containing multiple job records
    # @param job_id [Integer] The ID of the Job containing multiple JobRecords
    def perform(job_id)
      job = Job.find(job_id)
      
      Rails.logger.info "Starting batch processing for job #{job_id} with #{job.total_records} records"
      
      # Update job status
      job.update!(status: "processing", started_at: Time.current)
      
      # Track batch processing metrics
      batch_stats = {
        total_records: job.total_records,
        processed: 0,
        succeeded: 0,
        failed: 0,
        skipped: 0,
        start_time: Time.current
      }

      begin
        # Process job records in smaller chunks to avoid memory issues
        job.job_records.includes(:loan_application).find_each(batch_size: 100) do |job_record|
          process_job_record(job_record, batch_stats)
          batch_stats[:processed] += 1
          
          # Log progress every 100 records
          if batch_stats[:processed] % 100 == 0
            log_batch_progress(job, batch_stats)
          end
        end

        # Mark job as completed
        complete_batch_job(job, batch_stats)
        
      rescue StandardError => e
        # Handle batch-level failures
        fail_batch_job(job, batch_stats, e)
        raise
      ensure
        log_final_batch_stats(job, batch_stats)
      end
    end

    private

    def process_job_record(job_record, batch_stats)
      Rails.logger.debug "Processing job record #{job_record.id} for loan #{job_record.loan_application.los_external_id}"
      
      # Skip if already processed or in wrong state
      unless job_record.state == "triggered"
        Rails.logger.warn "Skipping job record #{job_record.id} - state is #{job_record.state}, expected 'triggered'"
        batch_stats[:skipped] += 1
        return
      end

      begin
        # Update job record state to indicate processing started
        job_record.update!(state: "processing")
        
        # Queue individual agent job for this record
        # We use perform_later to allow for proper queue management and retry handling
        PayStub::AgentJob.perform_later(job_record.id)
        
        # Update state to indicate it's been queued
        job_record.update!(state: "queued")
        batch_stats[:succeeded] += 1
        
        # Log successful queueing
        Event.create!(
          organization_id: job_record.job.organization_id,
          user_id: job_record.job.user_id,
          job_id: job_record.job_id,
          job_record_id: job_record.id,
          event_type: "batch_record_queued",
          phase: "batch_process",
          severity: "info",
          message: "Record queued for individual processing",
          ts: Time.current,
          trace_id: SecureRandom.hex(10)
        )
        
      rescue StandardError => e
        Rails.logger.error "Failed to process job record #{job_record.id}: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        
        # Mark job record as failed
        job_record.update!(
          state: "failed",
          last_error_code: "batch_processing_error",
          last_error_msg: "Failed during batch processing: #{e.message}"
        )
        
        batch_stats[:failed] += 1
        
        # Log the failure
        Event.create!(
          organization_id: job_record.job.organization_id,
          user_id: job_record.job.user_id,
          job_id: job_record.job_id,
          job_record_id: job_record.id,
          event_type: "batch_record_failed",
          phase: "batch_process",
          severity: "error",
          message: "Failed during batch processing: #{e.message}",
          ts: Time.current,
          trace_id: SecureRandom.hex(10)
        )
      end
    end

    def log_batch_progress(job, batch_stats)
      progress_pct = (batch_stats[:processed].to_f / batch_stats[:total_records] * 100).round(1)
      elapsed_time = Time.current - batch_stats[:start_time]
      records_per_second = batch_stats[:processed] / elapsed_time
      
      Rails.logger.info "Batch job #{job.id} progress: #{batch_stats[:processed]}/#{batch_stats[:total_records]} (#{progress_pct}%) " \
                       "- #{batch_stats[:succeeded]} succeeded, #{batch_stats[:failed]} failed, #{batch_stats[:skipped]} skipped " \
                       "- #{records_per_second.round(1)} records/sec"

      # Create progress event every 1000 records
      if batch_stats[:processed] % 1000 == 0
        Event.create!(
          organization_id: job.organization_id,
          user_id: job.user_id,
          job_id: job.id,
          job_record_id: nil,
          event_type: "batch_progress_update",
          phase: "batch_process",
          severity: "info",
          message: "Processed #{batch_stats[:processed]}/#{batch_stats[:total_records]} records (#{progress_pct}%)",
          ts: Time.current,
          trace_id: SecureRandom.hex(10)
        )
      end
    end

    def complete_batch_job(job, batch_stats)
      job.update!(
        status: "completed",
        completed_at: Time.current
      )

      Rails.logger.info "Batch job #{job.id} completed successfully"
      
      # Log completion event
      Event.create!(
        organization_id: job.organization_id,
        user_id: job.user_id,
        job_id: job.id,
        job_record_id: nil,
        event_type: "batch_job_completed",
        phase: "batch_process",
        severity: "info",
        message: "Batch job completed - #{batch_stats[:succeeded]} succeeded, #{batch_stats[:failed]} failed, #{batch_stats[:skipped]} skipped",
        ts: Time.current,
        trace_id: SecureRandom.hex(10)
      )
    end

    def fail_batch_job(job, batch_stats, error)
      job.update!(
        status: "failed",
        completed_at: Time.current
      )

      Rails.logger.error "Batch job #{job.id} failed: #{error.message}"
      
      # Log failure event
      Event.create!(
        organization_id: job.organization_id,
        user_id: job.user_id,
        job_id: job.id,
        job_record_id: nil,
        event_type: "batch_job_failed",
        phase: "batch_process",
        severity: "error",
        message: "Batch job failed after processing #{batch_stats[:processed]}/#{batch_stats[:total_records]} records: #{error.message}",
        ts: Time.current,
        trace_id: SecureRandom.hex(10)
      )
    end

    def log_final_batch_stats(job, batch_stats)
      elapsed_time = Time.current - batch_stats[:start_time]
      records_per_second = batch_stats[:processed] / elapsed_time
      
      Rails.logger.info "Batch job #{job.id} final stats: " \
                       "#{batch_stats[:processed]}/#{batch_stats[:total_records]} processed " \
                       "in #{elapsed_time.round(2)}s (#{records_per_second.round(1)} records/sec) " \
                       "- #{batch_stats[:succeeded]} succeeded, #{batch_stats[:failed]} failed, #{batch_stats[:skipped]} skipped"
    end
  end
end
