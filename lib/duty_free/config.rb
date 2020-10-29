# frozen_string_literal: true

require 'singleton'
require 'duty_free/serializers/yaml'

module DutyFree
  # Global configuration affecting all threads. Some thread-specific
  # configuration can be found in `duty_free.rb`, others in `controller.rb`.
  class Config
    include Singleton
    attr_accessor :serializer, :version_limit, :association_reify_error_behaviour,
                  :object_changes_adapter, :root_model

    def initialize
      # Variables which affect all threads, whose access is synchronized.
      @mutex = Mutex.new
      @enabled = true

      # Variables which affect all threads, whose access is *not* synchronized.
      @serializer = DutyFree::Serializers::YAML
    end

    # Indicates whether DutyFree is on or off. Default: true.
    def enabled
      @mutex.synchronize { !!@enabled }
    end

    def enabled=(enable)
      @mutex.synchronize { @enabled = enable }
    end
  end
end
