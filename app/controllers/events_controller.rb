class EventsController < ApplicationController
  def index
    @events = Event.order(created_at: :desc)
  end
end
