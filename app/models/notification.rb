class Notification < ApplicationRecord
  belongs_to :organization
  belongs_to :job_record
  belongs_to :user
end
