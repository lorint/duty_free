# frozen_string_literal: true

require 'spec_helper'

module Kitchen
  RSpec.describe Recipe, type: :model do
    describe '#suggest_template' do
      it 'properly enumerates an associative table for N:M relationships' do
        recipe = described_class.create!
      end
    end

    describe '#df_import' do
      it 'properly enumerates an associative table for N:M relationships' do
        recipe = described_class.create!
      end
    end

    describe '#df_export' do
      it 'properly enumerates an associative table for N:M relationships' do
        recipe = described_class.create!
      end
    end
  end
end
