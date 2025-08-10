class SecureDocumentCollector
  class << self
    # Generate secure upload link and send collection request to applicant
    def collect_pay_stub!(job_record:)
      loan_application = job_record.loan_application
      organization = loan_application.organization
      
      # Find or create document record
      document = Document.find_or_create_by!(
        loan_application_id: loan_application.id, 
        document_type: "PAY_STUB"
      ) do |d|
        d.status = "requested"
        d.sha256 = nil
        d.size_bytes = nil
        d.storage_url = generate_secure_storage_path(loan_application)
        d.kms_key_id = generate_kms_key_id(organization)
      end

      # Generate secure upload link with expiration
      upload_link = generate_secure_upload_link(document)
      
      # Create collection request with security token
      collection_request = create_collection_request!(
        loan_application: loan_application,
        document: document,
        upload_link: upload_link
      )

      # Send secure notification to applicant
      send_collection_notification!(
        loan_application: loan_application,
        collection_request: collection_request
      )

      # Update document status
      document.update!(status: "collection_sent")

      # Log the collection event
      Event.create!(
        organization: organization,
        user: job_record.job.user,
        job: job_record.job,
        job_record: job_record,
        event_type: "document_collection_initiated",
        phase: "collect",
        severity: "info",
        message: "Secure pay stub collection request sent to applicant #{loan_application.applicant_id}",
        ts: Time.current,
        trace_id: SecureRandom.hex(10)
      )

      {
        document: document,
        collection_request: collection_request,
        upload_link: upload_link,
        message: "Secure collection request sent successfully"
      }
    end

    # Process received document and validate it
    def process_received_document!(document:, file_data:, checksum:)
      # Validate file integrity
      calculated_checksum = Digest::SHA256.hexdigest(file_data)
      raise "File integrity check failed" unless calculated_checksum == checksum

      # Virus scan (placeholder - integrate with actual scanner)
      raise "File failed security scan" unless passes_security_scan?(file_data)

      # Validate file type and size
      validate_document!(file_data)

      # Store document securely
      storage_url = store_document_securely!(document, file_data)

      # Update document record
      document.update!(
        status: "received",
        sha256: calculated_checksum,
        size_bytes: file_data.bytesize,
        storage_url: storage_url
      )

      # Log successful receipt
      Event.create!(
        organization: document.loan_application.organization,
        user: User.find_by(role: "automation", organization: document.loan_application.organization), # system user
        job_id: nil, # Will be linked when processing
        job_record_id: nil,
        event_type: "document_received",
        phase: "collect",
        severity: "info",
        message: "Pay stub document received and validated for applicant #{document.loan_application.applicant_id}",
        ts: Time.current,
        trace_id: SecureRandom.hex(10)
      )

      document
    end

    private

    def generate_secure_storage_path(loan_application)
      org_id = loan_application.organization_id
      app_id = loan_application.id
      timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
      "s3://secure-psc-documents/#{org_id}/#{app_id}/paystub_#{timestamp}.pdf"
    end

    def generate_kms_key_id(organization)
      "arn:aws:kms:us-east-1:#{organization.id}:key/pay-stub-encryption-key"
    end

    def generate_secure_upload_link(document)
      # Generate presigned S3 upload URL with security constraints
      token = SecureRandom.urlsafe_base64(32)
      expiry = 24.hours.from_now
      
      {
        url: "https://secure-upload.example.com/upload/#{document.id}",
        token: token,
        expires_at: expiry,
        max_file_size: 10.megabytes,
        allowed_types: %w[application/pdf image/jpeg image/png]
      }
    end

    def create_collection_request!(loan_application:, document:, upload_link:)
      # In a real implementation, this would create a secure collection request record
      # with encrypted tokens and audit trail
      {
        id: SecureRandom.uuid,
        loan_application_id: loan_application.id,
        document_id: document.id,
        security_token: SecureRandom.urlsafe_base64(48),
        expires_at: upload_link[:expires_at],
        status: "sent",
        created_at: Time.current
      }
    end

    def send_collection_notification!(loan_application:, collection_request:)
      # In a real implementation, this would:
      # 1. Send secure email/SMS with encrypted link
      # 2. Use multi-factor authentication
      # 3. Provide clear instructions and security notices
      # 4. Log all communication attempts
      
      Rails.logger.info "Sending secure document collection request to applicant #{loan_application.applicant_id}"
      Rails.logger.info "Collection request ID: #{collection_request[:id]}"
      
      # Placeholder for actual notification system
      true
    end

    def passes_security_scan?(file_data)
      # Placeholder for virus/malware scanning
      # In production, integrate with ClamAV, VirusTotal, or similar
      file_data.present? && file_data.bytesize > 0
    end

    def validate_document!(file_data)
      # Basic validation - in production add more sophisticated checks
      raise "File too large" if file_data.bytesize > 10.megabytes
      raise "File too small" if file_data.bytesize < 1.kilobyte
      
      # Check file signature for PDF/image
      file_signature = file_data[0, 8]
      pdf_signature = file_signature.start_with?("%PDF")
      jpeg_signature = file_signature.start_with?("\xFF\xD8\xFF")
      png_signature = file_signature.start_with?("\x89PNG")
      
      unless pdf_signature || jpeg_signature || png_signature
        raise "Invalid file type - must be PDF, JPEG, or PNG"
      end
    end

    def store_document_securely!(document, file_data)
      # In production, this would:
      # 1. Upload to encrypted S3 bucket
      # 2. Apply server-side encryption with customer keys
      # 3. Set proper access controls and policies
      # 4. Create audit log of storage operation
      
      Rails.logger.info "Storing document securely for loan application #{document.loan_application_id}"
      document.storage_url # Return the pre-generated storage URL
    end
  end
end
