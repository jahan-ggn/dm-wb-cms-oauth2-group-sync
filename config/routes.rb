# frozen_string_literal: true

DmWbCmsOauth2GroupSync::Engine.routes.draw do
  get "/examples" => "examples#index"
  # define routes here
end

Discourse::Application.routes.draw { mount ::DmWbCmsOauth2GroupSync::Engine, at: "dm-wb-cms-oauth2-group-sync" }
