class Event < ApplicationRecord
  belongs_to :organization
  belongs_to :user
  belongs_to :job
  belongs_to :job_record
end
