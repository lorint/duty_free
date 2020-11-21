# frozen_string_literal: true

class Wotsit < ActiveRecord::Base
  if ActiveRecord.version >= Gem::Version.new('5.0')
    belongs_to :widget, optional: true
  else
    belongs_to :widget
  end

  def created_on
    created_at.to_date
  end
end
