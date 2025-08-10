module PayStub
  class LocateJob < BaseJob

    def perform(job_record_id)
      jr = job_record or raise "JobRecord not found"
      
      # Use secure document collector to initiate pay stub collection
      result = SecureDocumentCollector.collect_pay_stub!(job_record: jr)
      
      # Update job record state to reflect collection has been initiated
      jr.update!(state: "collecting")
      
      Rails.logger.info "Secure pay stub collection initiated: #{result[:message]}"
    end
  end
end
