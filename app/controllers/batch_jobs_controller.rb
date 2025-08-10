class BatchJobsController < ApplicationController
  before_action :authenticate_webhook # Reuse existing authentication
  
  # GET /batch_jobs
  # List batch jobs with optional filters
  def index
    organization_id = params[:organization_id]&.to_i
    status = params[:status]
    limit = [params[:limit]&.to_i || 50, 100].min # Cap at 100
    
    batch_jobs = BatchJobMonitor.list_batch_jobs(
      organization_id: organization_id,
      status: status,
      limit: limit
    )
    
    render json: {
      status: "success",
      batch_jobs: batch_jobs,
      total_returned: batch_jobs.size
    }
  end
  
  # GET /batch_jobs/running
  # Get all currently running batch jobs
  def running
    running_jobs = BatchJobMonitor.running_batch_jobs
    
    render json: {
      status: "success",
      running_batch_jobs: running_jobs,
      total_running: running_jobs.size
    }
  end
  
  # GET /batch_jobs/:id/status
  # Get detailed status for a specific batch job
  def status
    job_id = params[:id].to_i
    
    status_report = BatchJobMonitor.status_report(job_id)
    
    render json: {
      status: "success",
      **status_report
    }
  rescue ActiveRecord::RecordNotFound => e
    render json: { 
      status: "error", 
      message: "Batch job not found: #{e.message}" 
    }, status: 404
  rescue StandardError => e
    Rails.logger.error "Batch job status error: #{e.message}"
    render json: { 
      status: "error", 
      message: e.message 
    }, status: 500
  end
  
  # GET /batch_jobs/analytics
  # Get performance analytics for batch processing
  def analytics
    organization_id = params[:organization_id]&.to_i
    days_back = [params[:days_back]&.to_i || 7, 30].min # Cap at 30 days
    
    analytics = BatchJobMonitor.performance_analytics(
      organization_id: organization_id,
      days_back: days_back
    )
    
    if analytics.empty?
      render json: {
        status: "success",
        message: "No batch jobs found in the specified time range",
        analytics: {}
      }
    else
      render json: {
        status: "success",
        time_range_days: days_back,
        organization_id: organization_id,
        analytics: analytics
      }
    end
  rescue StandardError => e
    Rails.logger.error "Batch analytics error: #{e.message}"
    render json: { 
      status: "error", 
      message: e.message 
    }, status: 500
  end
  
  # POST /batch_jobs/:id/cancel
  # Cancel a running batch job (if possible)
  def cancel
    job_id = params[:id].to_i
    job = Job.find(job_id)
    
    unless job.agent_type == "PAY_STUB_COLLECTOR" && job.total_records > 1
      render json: { 
        status: "error", 
        message: "Not a batch job" 
      }, status: 400
      return
    end
    
    unless job.status == "running"
      render json: { 
        status: "error", 
        message: "Job is not running (status: #{job.status})" 
      }, status: 400
      return
    end
    
    # Mark job as cancelled
    job.update!(status: "cancelled", completed_at: Time.current)
    
    # Cancel remaining job records that haven't started processing
    cancelled_count = job.job_records
                         .where(state: %w[triggered queued])
                         .update_all(
                           state: "cancelled",
                           last_error_code: "user_cancelled",
                           last_error_msg: "Batch job cancelled by user",
                           updated_at: Time.current
                         )
    
    # Log cancellation event
    Event.create!(
      organization_id: job.organization_id,
      user_id: job.user_id,
      job_id: job.id,
      job_record_id: nil,
      event_type: "batch_job_cancelled",
      phase: "batch_process",
      severity: "info",
      message: "Batch job cancelled - #{cancelled_count} pending records cancelled",
      ts: Time.current,
      trace_id: SecureRandom.hex(10)
    )
    
    render json: {
      status: "success",
      message: "Batch job cancelled",
      job_id: job.id,
      records_cancelled: cancelled_count
    }
  rescue ActiveRecord::RecordNotFound => e
    render json: { 
      status: "error", 
      message: "Batch job not found: #{e.message}" 
    }, status: 404
  rescue StandardError => e
    Rails.logger.error "Batch job cancel error: #{e.message}"
    render json: { 
      status: "error", 
      message: e.message 
    }, status: 500
  end
  
  # POST /batch_jobs/:id/retry_failed
  # Retry all failed records in a batch job
  def retry_failed
    job_id = params[:id].to_i
    job = Job.find(job_id)
    
    unless job.agent_type == "PAY_STUB_COLLECTOR" && job.total_records > 1
      render json: { 
        status: "error", 
        message: "Not a batch job" 
      }, status: 400
      return
    end
    
    # Find failed records that can be retried
    max_attempts = RetryPolicy.find_by(name: "default")&.max_attempts || 3
    
    failed_records = job.job_records
                        .where(state: "failed")
                        .where("retry_count < ?", max_attempts)
    
    if failed_records.empty?
      render json: {
        status: "success",
        message: "No failed records eligible for retry",
        retried_count: 0
      }
      return
    end
    
    retried_count = 0
    
    failed_records.find_each do |job_record|
      begin
        # Reset the record for retry
        job_record.update!(
          state: "triggered",
          retry_count: job_record.retry_count + 1,
          next_attempt_at: Time.current,
          last_error_code: nil,
          last_error_msg: nil
        )
        
        # Queue the individual agent job
        PayStub::AgentJob.perform_later(job_record.id)
        retried_count += 1
        
        # Log retry event
        Event.create!(
          organization_id: job_record.job.organization_id,
          user_id: job_record.job.user_id,
          job_id: job_record.job_id,
          job_record_id: job_record.id,
          event_type: "batch_record_retried",
          phase: "batch_process",
          severity: "info",
          message: "Failed record queued for retry (attempt #{job_record.retry_count})",
          ts: Time.current,
          trace_id: SecureRandom.hex(10)
        )
        
      rescue StandardError => e
        Rails.logger.error "Failed to retry job record #{job_record.id}: #{e.message}"
      end
    end
    
    render json: {
      status: "success",
      message: "Failed records queued for retry",
      retried_count: retried_count,
      total_failed: failed_records.count
    }
  rescue ActiveRecord::RecordNotFound => e
    render json: { 
      status: "error", 
      message: "Batch job not found: #{e.message}" 
    }, status: 404
  rescue StandardError => e
    Rails.logger.error "Batch retry failed error: #{e.message}"
    render json: { 
      status: "error", 
      message: e.message 
    }, status: 500
  end
  
  private
  
  def authenticate_webhook
    # Reuse existing authentication logic
    api_key = request.headers["X-API-Key"]
    expected_key = Rails.application.credentials.loan_webhook_api_key
    
    unless api_key == expected_key
      render json: { status: "error", message: "Unauthorized" }, status: 401
    end
  end
end
