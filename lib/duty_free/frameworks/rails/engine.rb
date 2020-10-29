# frozen_string_literal: true

module DutyFree
  module Rails
    # See http://guides.rubyonrails.org/engines.html
    class Engine < ::Rails::Engine
      # paths['app/models'] << 'lib/duty_free/frameworks/active_record/models'
      config.duty_free = ActiveSupport::OrderedOptions.new
      initializer 'duty_free.initialisation' do |app|
        DutyFree.enabled = app.config.duty_free.fetch(:enabled, true)
      end
    end
  end
end
