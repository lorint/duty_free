# frozen_string_literal: true

module Kitchen
  class Ingredient < ActiveRecord::Base
    has_many :ingredient_recipes
    has_many :recipes, through: :ingredient_recipes
  end
end
