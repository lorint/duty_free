# frozen_string_literal: true

module Kitchen
  class Recipe < ActiveRecord::Base
    has_many :ingredient_recipes
    has_many :ingredients, through: :ingredient_recipes
  end
end
