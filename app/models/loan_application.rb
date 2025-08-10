class LoanApplication < ApplicationRecord
  belongs_to :organization
  has_many :documents, dependent: :destroy
  has_many :job_records, dependent: :destroy
end
