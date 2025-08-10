class Organization < ApplicationRecord
  has_many :routing_rules, dependent: :destroy
  has_many :users, dependent: :destroy
  has_many :loan_applications, dependent: :destroy
end
