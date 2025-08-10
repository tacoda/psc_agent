class JobRecord < ApplicationRecord
  belongs_to :job
  belongs_to :loan_application
  has_many :rpa_uploads, dependent: :destroy
  has_many :events, dependent: :destroy
  has_many :notifications, dependent: :destroy
end
