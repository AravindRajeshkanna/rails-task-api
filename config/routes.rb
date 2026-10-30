Rails.application.routes.draw do
  # Load balancer / Kamal health check.
  get "up" => "rails/health#show", as: :rails_health_check

  # Prometheus scrape endpoint; reachable from inside the cluster only (see Observability::MetricsApp).
  mount Observability::MetricsApp.new => "/metrics"

  # OpenAPI document (generated from the request specs) and Swagger UI.
  mount Rswag::Ui::Engine => "/api-docs"
  mount Rswag::Api::Engine => "/api-docs"

  namespace :api do
    namespace :v1 do
      # Served by the Auth service when AUTH_MODE=jwt (the ingress routes these paths there);
      # here they answer 404 so there is only ever one place that issues credentials.
      constraints(->(_request) { !ExternalAuth.enabled? }) do
        resources :registrations, only: :create
        resource :session, only: %i[create destroy]
        resources :passwords, only: %i[create update], param: :token
      end

      # AI helpers (see Api::V1::AiController): POST /ai/suggest_priority, /ai/create_from_text, ...
      resource :ai, controller: "ai", only: [] do
        %i[suggest_priority suggest_tags suggest_assignee create_from_text chat].each { |action| post action }
        get :usage
      end

      # Read-only GraphQL (POST { query, variables, operationName }); writes stay on REST.
      post "graphql", to: "graphql#create"

      # The caller's in-app inbox (kept current over NotificationsChannel).
      resources :notifications, only: %i[index update destroy] do
        post :read_all, on: :collection
      end

      # What the caller wants to hear about: a daily digest instead of an email per event, and what they muted.
      resource :notification_settings, only: %i[show update]
      resources :notification_mutes, only: %i[index create destroy]

      # Full-text search across the caller's projects (inside one project: `?search=` on its task list).
      get "search", to: "search#index"

      # Everything that happened in the caller's projects (the member's view of the audit log).
      get "activity", to: "activities#index"

      resource :me, controller: "me", only: %i[show update] do
        resource :avatar, only: %i[update destroy]
      end

      # People and the projects they share; members are addressed under their organization.
      resources :organizations do
        resources :members, controller: "organization_memberships", only: %i[index update destroy]
        resources :invitations, controller: "organization_invitations", only: %i[index create destroy]
        resources :audit_events, controller: "organization_audit_events", only: :index
        resources :teams do
          resources :members, controller: "team_memberships", only: %i[index create update destroy]
        end
      end
      # Joining happens by redeeming an invitation (there is no "add by email"): the emailed token, as the invited address.
      post "invitations/accept", to: "invitation_acceptances#create"

      # A team's access to a project is addressed under the project (it only means something there).
      resources :projects, only: [] do
        resources :teams, controller: "project_teams", only: %i[index create update destroy]
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
        resource :summary, only: :show, controller: "project_summaries"
        resource :analytics, only: :show, controller: "analytics"
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
