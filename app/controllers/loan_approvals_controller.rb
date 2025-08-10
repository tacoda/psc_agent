class LoanApprovalsController < ApplicationController
  before_action :authenticate_webhook # Add authentication as needed
  
  # POST /loan_approvals/webhook
  # Called when a loan is approved by the LOS system
  def webhook
    loan_data = params.require(:loan_application)
    organization_id = params.require(:organization_id)
    
    organization = Organization.find(organization_id)
    
    # Find or update the loan application
    loan_application = LoanApplication.find_or_create_by(
      los_external_id: loan_data[:los_external_id],
      organization: organization
    ) do |loan|
      loan.applicant_id = loan_data[:applicant_id]
      loan.status = loan_data[:status]
      loan.income_doc_required = loan_data[:income_doc_required]
      loan.approved_at = loan_data[:approved_at] ? Time.parse(loan_data[:approved_at]) : nil
    end

    # Update existing loan application with new data from webhook
    loan_application.update!(
      status: loan_data[:status],
      income_doc_required: loan_data[:income_doc_required],
      approved_at: loan_data[:approved_at] ? Time.parse(loan_data[:approved_at]) : nil
    )

    # Check if this triggers pay stub collection
    if should_trigger_collection?(loan_application, loan_data)
      # Find appropriate system user for triggering (automation user)
      system_user = organization.users.find_by(role: "automation") || 
                   organization.users.find_by(role: "lending_officer")
      
      raise "No suitable user found for triggering agent" unless system_user

      # Trigger the pay stub collection agent
      notes = loan_data[:notes] || loan_data[:approval_notes] || ""
      result = LoanApprovalTrigger.call!(
        loan_application: loan_application,
        triggered_by_user: system_user,
        notes: notes
      )

      render json: {
        status: "success",
        message: "Pay stub collection agent triggered",
        job_id: result[:job].id,
        job_record_id: result[:job_record].id
      }
    else
      render json: {
        status: "success", 
        message: "Loan application updated, no agent trigger required"
      }
    end

  rescue ActiveRecord::RecordNotFound => e
    render json: { status: "error", message: "Record not found: #{e.message}" }, status: 404
  rescue StandardError => e
    Rails.logger.error "Loan approval webhook error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { status: "error", message: e.message }, status: 500
  end

  # POST /loan_approvals/batch_webhook
  # Called when multiple loans are approved and need batch processing
  def batch_webhook
    loan_applications_data = params.require(:loan_applications)
    organization_id = params.require(:organization_id)
    batch_size = params[:batch_size]&.to_i || 10_000
    
    organization = Organization.find(organization_id)
    
    # Find appropriate system user for triggering (automation user)
    system_user = organization.users.find_by(role: "automation") || 
                 organization.users.find_by(role: "lending_officer")
    
    raise "No suitable user found for triggering batch agent" unless system_user
    
    # Extract loan application IDs or create/update loan applications
    if loan_applications_data.first.is_a?(Hash)
      # If we received full loan data, create/update loan applications
      loan_ids = process_batch_loan_data(loan_applications_data, organization)
    else
      # If we received just IDs, use them directly
      loan_ids = loan_applications_data
    end
    
    # Create batch jobs
    result = BatchJobTrigger.create_batch_job_from_ids!(
      organization: organization,
      loan_application_ids: loan_ids,
      triggered_by_user: system_user,
      batch_size: batch_size,
      trigger_source: "batch_webhook"
    )
    
    render json: {
      status: "success",
      message: result[:message],
      total_jobs_created: result[:total_jobs_created],
      total_records_processed: result[:total_records_processed],
      job_ids: result[:jobs].map { |j| j[:job].id }
    }
    
  rescue ActiveRecord::RecordNotFound => e
    render json: { status: "error", message: "Record not found: #{e.message}" }, status: 404
  rescue StandardError => e
    Rails.logger.error "Batch webhook error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { status: "error", message: e.message }, status: 500
  end
  
  # POST /loan_approvals/manual_batch_trigger
  # Manually trigger batch pay stub collection for multiple loans
  def manual_batch_trigger
    loan_application_ids = params.require(:loan_application_ids)
    user_id = params.require(:user_id)
    batch_size = params[:batch_size]&.to_i || 10_000
    
    user = User.find(user_id)
    
    # Validate all loan applications belong to user's organization
    loan_applications = LoanApplication.where(id: loan_application_ids)
    invalid_loans = loan_applications.where.not(organization_id: user.organization_id)
    
    if invalid_loans.exists?
      render json: {
        status: "error", 
        message: "Some loan applications do not belong to user's organization",
        invalid_loan_ids: invalid_loans.pluck(:id)
      }, status: 403
      return
    end
    
    result = BatchJobTrigger.create_batch_job!(
      organization: user.organization,
      loan_applications: loan_applications,
      triggered_by_user: user,
      batch_size: batch_size,
      trigger_source: "manual_batch"
    )
    
    render json: {
      status: "success",
      message: result[:message],
      total_jobs_created: result[:total_jobs_created],
      total_records_processed: result[:total_records_processed],
      job_ids: result[:jobs].map { |j| j[:job].id }
    }
    
  rescue ActiveRecord::RecordNotFound => e
    render json: { status: "error", message: "Record not found: #{e.message}" }, status: 404
  rescue StandardError => e
    Rails.logger.error "Manual batch trigger error: #{e.message}"
    render json: { status: "error", message: e.message }, status: 500
  end

  # POST /loan_approvals/manual_trigger
  # Manually trigger pay stub collection for a specific loan
  def manual_trigger
    loan_application_id = params.require(:loan_application_id)
    user_id = params.require(:user_id)
    
    loan_application = LoanApplication.find(loan_application_id)
    user = User.find(user_id)
    
    # Validate user belongs to same organization
    unless user.organization_id == loan_application.organization_id
      render json: { status: "error", message: "User does not belong to loan application organization" }, status: 403
      return
    end

    result = LoanApprovalTrigger.call!(
      loan_application: loan_application,
      triggered_by_user: user
    )

    render json: {
      status: "success",
      message: "Pay stub collection agent triggered manually",
      job_id: result[:job].id,
      job_record_id: result[:job_record].id
    }

  rescue ActiveRecord::RecordNotFound => e
    render json: { status: "error", message: "Record not found: #{e.message}" }, status: 404
  rescue StandardError => e
    Rails.logger.error "Manual trigger error: #{e.message}"
    render json: { status: "error", message: e.message }, status: 500
  end

  private

  def should_trigger_collection?(loan_application, loan_data)
    # Check for the specific note or flag indicating pay stub is required
    notes = loan_data[:notes] || loan_data[:approval_notes] || ""
    
    # Trigger if:
    # 1. Loan is approved
    # 2. Income doc is required OR notes mention "pay stub required"
    # 3. Not already triggered (check for existing job records)
    loan_application.status == "approved" &&
      (loan_application.income_doc_required? || notes.downcase.include?("pay stub required")) &&
      !already_triggered?(loan_application)
  end

  def already_triggered?(loan_application)
    # Check if there's already an active pay stub collection job for this loan
    JobRecord.joins(:job)
             .where(loan_application: loan_application)
             .where(jobs: { agent_type: "PAY_STUB_COLLECTOR" })
             .where.not(jobs: { status: ["completed", "failed"] })
             .exists?
  end

  def process_batch_loan_data(loan_applications_data, organization)
    loan_ids = []
    
    loan_applications_data.each do |loan_data|
      # Convert to symbol keys for consistency
      loan_data = loan_data.symbolize_keys if loan_data.respond_to?(:symbolize_keys)
      
      # Find or create loan application
      loan_application = LoanApplication.find_or_create_by(
        los_external_id: loan_data[:los_external_id],
        organization: organization
      ) do |loan|
        loan.applicant_id = loan_data[:applicant_id]
        loan.status = loan_data[:status]
        loan.income_doc_required = loan_data[:income_doc_required]
        loan.approved_at = loan_data[:approved_at] ? Time.parse(loan_data[:approved_at]) : nil
      end

      # Update existing loan application with new data
      loan_application.update!(
        status: loan_data[:status],
        income_doc_required: loan_data[:income_doc_required],
        approved_at: loan_data[:approved_at] ? Time.parse(loan_data[:approved_at]) : nil
      )
      
      # Only include loans that should trigger collection based on the updated data
      if should_trigger_collection?(loan_application, loan_data)
        loan_ids << loan_application.id
      end
    end
    
    loan_ids
  end

  def authenticate_webhook
    # Implement webhook authentication here
    # This could be:
    # 1. API key validation
    # 2. HMAC signature verification
    # 3. JWT token validation
    # 4. IP whitelist check
    
    api_key = request.headers["X-API-Key"]
    expected_key = Rails.application.credentials.loan_webhook_api_key
    
    unless api_key == expected_key
      render json: { status: "error", message: "Unauthorized" }, status: 401
    end
  end
end
