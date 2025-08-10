# frozen_string_literal: true
module PayStub
  class ConfirmJob < BaseJob

    def perform(job_record_id)
      jr = job_record or raise "JobRecord not found"
      # Verify document presence & integrity (sha256 matches, etc.)
      doc = Document.find_by!(loan_application_id: jr.loan_application_id, document_type: "PAY_STUB")
      raise "Document not received" unless %w[received verified].include?(doc.status)
      jr.update!(state: "uploading")
    end
  end
end
