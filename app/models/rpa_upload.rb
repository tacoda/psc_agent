class RpaUpload < ApplicationRecord
  belongs_to :job_record
  belongs_to :document
end
