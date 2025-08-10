module PayStub
  class LocateJob < BaseJob

    def perform(job_record_id)
      jr = job_record or raise "JobRecord not found"
      # Find or create a Document metadata row; request secure upload link, etc.
      Document.find_or_create_by!(loan_application_id: jr.loan_application_id, document_type: "PAY_STUB") do |d|
        d.status = "requested"
        d.sha256 = nil
        d.size_bytes = nil
        d.storage_url = "s3://placeholder/#{jr.loan_application_id}/paystub.pdf"
        d.kms_key_id = "kms-key-#{jr.job.organization_id}"
      end
    end
  end
end
