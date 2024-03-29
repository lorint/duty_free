# frozen_string_literal: true

# :nodoc:
module DutyFree
  module VERSION
    MAJOR = 1
    MINOR = 0
    TINY = 10

    # PRE is nil unless it's a pre-release (beta, RC, etc.)
    PRE = nil

    STRING = [MAJOR, MINOR, TINY, PRE].compact.join('.').freeze

    def self.to_s
      STRING
    end
  end
end
