# frozen_string_literal: true

namespace :pay_stub do

  desc "Run all Pay Stub jobs in sequence for a given JobRecord ID"
  task :agent, [:job_record_id] => :environment do |_, args|
    ensure_id!(args[:job_record_id])
    # PayStub::AgentJob.perform_later(args[:job_record_id])
    puts "Enqueued AgentJob for JobRecord #{args[:job_record_id]}"
  end

  # Define tasks after environment loads to access constants
  task :_define_job_tasks => :environment do
    job_classes = {
      define:    PayStub::DefineJob,
      # locate:    PayStub::LocateJob,
      # prepare:   PayStub::PrepareJob,
      # confirm:   PayStub::ConfirmJob,
      # execute:   PayStub::ExecuteJob,
      # monitor:   PayStub::MonitorJob,
      # modify:    PayStub::ModifyJob,
      # conclude:  PayStub::ConcludeJob
    }
    
    job_classes.each do |name, job_class|
      Rake::Task.define_task name, [:job_record_id] => :environment do |_, args|
        ensure_id!(args[:job_record_id])
        job_class.perform_later(args[:job_record_id])
        puts "Enqueued #{job_class.name} for JobRecord #{args[:job_record_id]}"
      end
      
      # Add description
      Rake::Task["pay_stub:#{name}"].add_description("Run #{job_class.name} for a given JobRecord ID")
    end
  end
  
  # Create a simple define task that can be called directly
  desc "Run PayStub::DefineJob for a given JobRecord ID"
  task :define, [:job_record_id] => :environment do |_, args|
    ensure_id!(args[:job_record_id])
    PayStub::DefineJob.perform_later(args[:job_record_id])
    puts "Enqueued PayStub::DefineJob for JobRecord #{args[:job_record_id]}"
  end

  # Helper method inside namespace
  def ensure_id!(id)
    if id.nil? || id.strip.empty?
      puts "ERROR: You must pass a JobRecord ID, e.g., rake agents:pay_stub:define[123]"
      exit 1
    end
  end
end
