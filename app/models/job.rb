class Job < ApplicationRecord
  belongs_to :organization
  belongs_to :triggered_by_user
end
