class JobRecord < ApplicationRecord
  belongs_to :job
  belongs_to :loan_application
end
