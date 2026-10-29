Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :v1 do
    post "features/:name", to: "features#create"
    post "converse", to: "conversations#create"
    post "embeddings", to: "embeddings#create"
  end

  match "*unmatched", to: "errors#not_found", via: :all
end
