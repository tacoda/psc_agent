class Job < ApplicationRecord
  belongs_to :organization
  belongs_to :user
  has_many :job_records, dependent: :destroy
  has_many :events, dependent: :destroy
end
