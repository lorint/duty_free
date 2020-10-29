# frozen_string_literal: true

class Vehicle < ActiveRecord::Base
  # For the `Car` and `Bicycle` types, their friendly type names get suffixed such that they become "Car Transpo"
  # and "Bicycle Transpo"
  # update_duty_free friendly_suffix: "Transpo"

  if ActiveRecord.gem_version >= Gem::Version.new('5.0')
    belongs_to :owner, class_name: 'Person', optional: true
  else
    belongs_to :owner, class_name: 'Person'
  end
end
