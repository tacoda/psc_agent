class RpaUploadsController < ApplicationController
  before_action :authenticate_api_user # Add authentication as needed
  
  # GET /rpa_uploads/status
  # Get overall RPA upload status and metrics
  def status
    organization_id = params[:organization_id]
    time_range_hours = (params[:hours] || 24).to_i.hours
    
    report = RpaUploadMonitor.status_report(
      organization_id: organization_id,
      time_range: time_range_hours
    )
    
    render json: {
      status: "success",
      data: report,
      generated_at: Time.current
    }
  end
  
  # GET /rpa_uploads/job_record/:id
  # Get detailed status for a specific job record
  def job_record_status
    job_record_id = params[:id]
    
    begin
      status_info = RpaUploadMonitor.job_record_status(job_record_id)
      
      render json: {
        status: "success",
        data: status_info
      }
    rescue ActiveRecord::RecordNotFound
      render json: {
        status: "error",
        message: "Job record not found"
      }, status: 404
    end
  end
  
  # GET /rpa_uploads/stuck
  # Detect uploads that are stuck and may need intervention
  def stuck_uploads
    threshold_minutes = (params[:threshold_minutes] || 30).to_i
    
    stuck_uploads = RpaUploadMonitor.detect_stuck_uploads(threshold_minutes: threshold_minutes)
    
    render json: {
      status: "success",
      data: {
        stuck_uploads: stuck_uploads,
        count: stuck_uploads.size,
        threshold_minutes: threshold_minutes
      }
    }
  end
  
  # POST /rpa_uploads/escalate_stuck
  # Force escalation of stuck uploads
  def escalate_stuck
    threshold_minutes = (params[:threshold_minutes] || 30).to_i
    
    escalated_count = RpaUploadMonitor.escalate_stuck_uploads!(threshold_minutes: threshold_minutes)
    
    render json: {
      status: "success",
      message: "Escalated #{escalated_count} stuck uploads",
      escalated_count: escalated_count
    }
  end
  
  # POST /rpa_uploads/retry_failed
  # Manually trigger retry of failed uploads
  def retry_failed
    organization_id = params[:organization_id]
    
    # Find failed uploads that can be retried
    retry_candidates = JobRecord.joins(:job)
                                .where(jobs: { agent_type: "PAY_STUB_COLLECTOR" })
                                .where(state: "failed")
                                .where("retry_count < ?", 3)
    
    if organization_id
      retry_candidates = retry_candidates.where(jobs: { organization_id: organization_id })
    end
    
    retry_count = 0
    retry_candidates.find_each do |job_record|
      begin
        # Reset for retry
        job_record.update!(
          state: "retry_scheduled",
          next_attempt_at: Time.current
        )
        
        # Queue retry job
        PayStub::RetryFailedUploadsJob.perform_later
        retry_count += 1
        
      rescue StandardError => e
        Rails.logger.error "Error queuing retry for job_record #{job_record.id}: #{e.message}"
      end
    end
    
    render json: {
      status: "success",
      message: "Queued #{retry_count} uploads for retry",
      retry_count: retry_count
    }
  end
  
  # GET /rpa_uploads/metrics
  # Get aggregated metrics for monitoring systems
  def metrics
    organization_id = params[:organization_id]
    
    # Get basic counts
    base_scope = organization_id ? 
      RpaUpload.joins(job_record: :job).where(jobs: { organization_id: organization_id }) :
      RpaUpload.all
      
    recent_uploads = base_scope.where(created_at: 1.hour.ago..Time.current)
    
    metrics = {
      gauges: {
        "rpa_uploads.active" => base_scope.where(status: "in_progress").count,
        "rpa_uploads.pending_retries" => JobRecord.joins(:job)
                                                  .where(jobs: { agent_type: "PAY_STUB_COLLECTOR" })
                                                  .where(state: "failed")
                                                  .where("retry_count < ?", 3)
                                                  .count,
        "rpa_uploads.stuck" => RpaUploadMonitor.detect_stuck_uploads(threshold_minutes: 30).size
      },
      counters: {
        "rpa_uploads.total_last_hour" => recent_uploads.count,
        "rpa_uploads.succeeded_last_hour" => recent_uploads.where(status: "succeeded").count,
        "rpa_uploads.failed_last_hour" => recent_uploads.where(status: "failed").count
      },
      rates: {
        "rpa_uploads.success_rate_last_hour" => calculate_recent_success_rate(recent_uploads)
      }
    }
    
    render json: {
      status: "success",
      metrics: metrics,
      timestamp: Time.current.to_i
    }
  end

  private

  def authenticate_api_user
    # Implement API authentication here
    # This could be:
    # 1. API key validation
    # 2. JWT token validation  
    # 3. Basic auth
    # 4. Session-based auth
    
    api_key = request.headers["X-API-Key"] || params[:api_key]
    expected_key = Rails.application.credentials.monitoring_api_key
    
    unless api_key == expected_key
      render json: { status: "error", message: "Unauthorized" }, status: 401
    end
  end

  def calculate_recent_success_rate(uploads)
    total = uploads.where(status: ["succeeded", "failed"]).count
    return 0 if total.zero?
    
    succeeded = uploads.where(status: "succeeded").count
    (succeeded.to_f / total * 100).round(1)
  end
end
