# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DutyFree do
  it 'baseline test setup' do
    # expect(Person.new).to be_versioned
  end

  describe '#association reify error behaviour' do
    it 'association reify error behaviour = :error' do
      # ::DutyFree.config.association_reify_error_behaviour = :error

      person = Person.create(name: 'Frank')
      car = Car.create(name: 'BMW 325')
      bicycle = Bicycle.create(name: 'BMX 1.0')

      person.car = car
      person.bicycle = bicycle
      person.update(name: 'Steve')

      car.update(name: 'BMW 330')
      bicycle.update(name: 'BMX 2.0')
      person.update(name: 'Peter')
    end
  end
end
