# frozen_string_literal: true

class FooHabtm < ActiveRecord::Base
  has_and_belongs_to_many :bar_habtms
  accepts_nested_attributes_for :bar_habtms
end
