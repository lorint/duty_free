# frozen_string_literal: true

class BarHabtm < ActiveRecord::Base
  has_and_belongs_to_many :foo_habtms
end
