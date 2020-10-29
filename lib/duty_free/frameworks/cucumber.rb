# frozen_string_literal: true

# before hook for Cucumber
Before do
  DutyFree.enabled = false
  DutyFree.request.enabled = true
  DutyFree.request.whodunnit = nil
  DutyFree.request.controller_info = {} if defined?(::Rails)
end

module DutyFree
  module Cucumber
    # Helper method for enabling DutyFree in Cucumber features.
    module Extensions
      def with_df_importing
        was_enabled = ::DutyFree.enabled?
        ::DutyFree.enabled = true
        begin
          yield
        ensure
          ::DutyFree.enabled = was_enabled
        end
      end
    end
  end
end

World DutyFree::Cucumber::Extensions
