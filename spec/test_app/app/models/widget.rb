# frozen_string_literal: true

class Widget < ActiveRecord::Base
  EXCLUDED_NAME = 'Biglet'
  has_one :wotsit
  if ActiveRecord.version >= ::Gem::Version.new('4.0')
    has_many(:fluxors, -> { order(:name) })
  else
    has_many(:fluxors)
  end
  has_many :whatchamajiggers, as: :owner
  validates :name, exclusion: { in: [EXCLUDED_NAME] }
end
