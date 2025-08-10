Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"

  mount MissionControl::Jobs::Engine, at: "/jobs"

  # Loan approval webhooks and triggers
  post "loan_approvals/webhook", to: "loan_approvals#webhook"
  post "loan_approvals/batch_webhook", to: "loan_approvals#batch_webhook"
  post "loan_approvals/manual_trigger", to: "loan_approvals#manual_trigger"
  post "loan_approvals/manual_batch_trigger", to: "loan_approvals#manual_batch_trigger"
  
  # RPA upload monitoring and management
  get "rpa_uploads/status", to: "rpa_uploads#status"
  get "rpa_uploads/job_record/:id", to: "rpa_uploads#job_record_status"
  get "rpa_uploads/stuck", to: "rpa_uploads#stuck_uploads"
  post "rpa_uploads/escalate_stuck", to: "rpa_uploads#escalate_stuck"
  post "rpa_uploads/retry_failed", to: "rpa_uploads#retry_failed"
  get "rpa_uploads/metrics", to: "rpa_uploads#metrics"
  
  # Batch job monitoring and management
  get "batch_jobs", to: "batch_jobs#index"
  get "batch_jobs/running", to: "batch_jobs#running"
  get "batch_jobs/analytics", to: "batch_jobs#analytics"
  get "batch_jobs/:id/status", to: "batch_jobs#status"
  post "batch_jobs/:id/cancel", to: "batch_jobs#cancel"
  post "batch_jobs/:id/retry_failed", to: "batch_jobs#retry_failed"
  
  get "audit" => "events#index"
end
