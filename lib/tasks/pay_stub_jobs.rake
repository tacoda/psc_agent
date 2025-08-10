namespace :pay_stub do

  desc "Run all Pay Stub jobs in sequence for a given JobRecord ID"
  task :agent, [:job_record_id] => :environment do |_, args|
    ensure_id!(args[:job_record_id])
    # PayStub::AgentJob.perform_later(args[:job_record_id])
    puts "Enqueued AgentJob for JobRecord #{args[:job_record_id]}"
  end

  # Define a method to get job classes after Rails environment loads
  def self.job_classes
    {
      define:    PayStub::DefineJob,
      locate:    PayStub::LocateJob,
      prepare:   PayStub::PrepareJob,
      confirm:   PayStub::ConfirmJob,
      execute:   PayStub::ExecuteJob,
      monitor:   PayStub::MonitorJob,
      # modify:    PayStub::ModifyJob,
      # conclude:  PayStub::ConcludeJob
    }
  end
  
  # Create tasks for each job class
  [:define, :locate, :prepare, :confirm, :execute, :monitor].each do |name|
    desc "Run PayStub::#{name.to_s.camelize}Job for a given JobRecord ID"
    task name, [:job_record_id] => :environment do |_, args|
      ensure_id!(args[:job_record_id])
      job_class = job_classes[name]
      job_class.perform_later(args[:job_record_id])
      puts "Enqueued #{job_class.name} for JobRecord #{args[:job_record_id]}"
    end
  end

  # Helper method inside namespace
  def ensure_id!(id)
    if id.nil? || id.strip.empty?
      puts "ERROR: You must pass a JobRecord ID, e.g., rake agents:pay_stub:define[123]"
      exit 1
    end
  end
end
