Rails.application.routes.draw do
  # Load balancer / Kamal health check.
  get "up" => "rails/health#show", as: :rails_health_check

  # OpenAPI document (generated from the request specs) and Swagger UI.
  mount Rswag::Ui::Engine => "/api-docs"
  mount Rswag::Api::Engine => "/api-docs"

  namespace :api do
    namespace :v1 do
      resources :registrations, only: :create
      resource :session, only: %i[create destroy]
      resources :passwords, only: %i[create update], param: :token

      resource :me, controller: "me", only: %i[show update] do
        resource :avatar, only: %i[update destroy]
      end

      # Shallow nesting: collections hang off their parent
      # (/projects/1/tasks), members stand alone (/tasks/7).
      resources :projects, shallow: true do
        post :restore, on: :member

        resources :tasks do
          post :restore, on: :member
          resources :comments, only: %i[index create update destroy]
          resources :attachments, only: %i[create destroy]
        end
        resources :memberships, only: %i[index create update destroy]
        resources :tags, only: %i[index create destroy]
        resources :webhooks do
          resources :deliveries, only: :index, controller: "webhook_deliveries"
        end
        resources :audit_events, only: :index
      end
    end
  end

  # Errors raised outside controllers (see config.exceptions_app).
  match "/:status", to: "errors#show", via: :all, constraints: { status: /\d{3}/ }
end
