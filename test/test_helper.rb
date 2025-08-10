ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Load mocha for mocking
require "mocha/minitest"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
    
    # Helper to create test organizations with required associations
    def create_test_organization(name: "Test Organization")
      Organization.create!(name: name, status: "active")
    end
    
    # Helper to create test users with required roles
    def create_test_user(organization:, role: "lending_officer", email_suffix: "testcu.org")
      User.create!(
        organization: organization,
        email: "#{role.gsub('_', '.')}@#{email_suffix}",
        name: "Test #{role.titleize}",
        role: role,
        status: "active"
      )
    end
    
    # Helper to create loan applications for testing
    def create_test_loan_application(organization:, status: "approved")
      LoanApplication.create!(
        organization: organization,
        applicant_id: "APP-TEST-#{SecureRandom.hex(3)}",
        los_external_id: "LOS-TEST-#{SecureRandom.hex(3)}",
        status: status,
        income_doc_required: true,
        approved_at: status == "approved" ? 1.hour.ago : nil
      )
    end
    
    # Helper to create test documents
    def create_test_document(loan_application:, status: "received")
      Document.create!(
        loan_application: loan_application,
        document_type: "PAY_STUB",
        status: status,
        sha256: SecureRandom.hex(32),
        size_bytes: rand(50_000..200_000),
        storage_url: "s3://test-bucket/#{loan_application.id}/paystub.pdf",
        kms_key_id: "test-kms-key"
      )
    end
    
    # Helper to mock successful RPA uploads
    def mock_successful_rpa_upload
      Random.expects(:rand).returns(0.9).at_least_once # Above all failure thresholds
    end
    
    # Helper to mock failed RPA uploads
    def mock_failed_rpa_upload(error_type: :timeout)
      case error_type
      when :timeout
        Random.expects(:rand).returns(0.1).at_least_once # Within timeout range
      when :system_error
        Random.expects(:rand).returns(0.2).at_least_once # Within system error range  
      when :format_error
        Random.expects(:rand).returns(0.26).at_least_once # Within format error range
      when :auth_error
        Random.expects(:rand).returns(0.05).at_least_once # Within auth error range during auth step
      end
    end
    
    # Helper to assert notification was sent
    def assert_notification_sent(job_record:, user:, channel: "email")
      notification = Notification.find_by(
        job_record: job_record,
        user: user,
        channel: channel,
        status: "sent"
      )
      assert notification.present?, "Expected #{channel} notification to #{user.email} was not sent"
      notification
    end
    
    # Helper to assert event was logged
    def assert_event_logged(job_record:, event_type:, phase: nil)
      event = Event.find_by(
        job_record: job_record,
        event_type: event_type,
        phase: phase
      )
      assert event.present?, "Expected event '#{event_type}' was not logged"
      event
    end
  end
end
