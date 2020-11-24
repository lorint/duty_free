# frozen_string_literal: true

# This example shows has_one and has_many working together

require 'spec_helper'
require 'csv'

# Examples
# ========

RSpec.describe 'Fluxor', type: :model do
  before(:each) do
    Widget.destroy_all
  end

  it 'should be able to import from CSV data' do
    csv_in = <<~CSV
      Name,Widget Name,Widget A Text,Widget An Integer,Widget A Float,Widget A Decimal,Widget A Datetime,Widget A Time,Widget A Date,Widget A Boolean,Widget Wotsit Name
      Flux Capacitor,Squidget Widget,Widge Text,42,0.7734,847.63,2020-04-01 23:59,04:20:00 AM,2020-12-02,T,Mr. Wotsit
      Flex Resistor,Budget Widget,Budge Text,100,7.734,243.26,2019-04-01 23:59,16:20:00 PM,2019-12-02,F,Mr. Budgit
      Flex Resistor,Budget Widget,Budge Text,100,7.734,243.26,2019-04-01 23:59,16:20:00 PM,2019-12-02,F,Mr. Fixit
      Nix Resistor,Budget Widget,Budge Text,420,7.734,243.26,2019-04-01 23:59,16:20:00 PM,2019-12-02,F,Mr. Budgit
    CSV

    # %%% TODO: Change the third line to this:  Flex Resistor,Squidget Widget,Widge Text,42,0.7734,847.63,2020-04-01 23:59,04:20:00 AM,2020-12-02,T,Mr. Fixit
    # It builds 3 widgets instead of 2, and meanwhile a fluxor should simply have its foreign key updated to point to the
    # known widget Squidget Widget.

    child_info_csv = CSV.new(csv_in)

    # Import CSV data
    # ---------------
    expect { Fluxor.df_import(child_info_csv) }.not_to raise_error

    expect([Fluxor.count, Widget.count, Wotsit.count]).to eq([3, 2, 4])

    widgets = Widget.order(:id).pluck(:name, :a_text, :an_integer, :a_float, :a_decimal, :a_datetime, :a_time, :a_date, :a_boolean)

    # Take out just the time column and test it
    expect(widgets.map do |w|
      t = w.slice!(6)
      [t.hour, t.min]
    end).to eq([[4, 20], [16, 20]])

    # Now test all the rest
    expect(widgets).to eq(
      [
        ['Squidget Widget', 'Widge Text', 42, 0.7734, BigDecimal(847.63, 5),
         DateTime.new(2020, 4, 1, 23, 59).in_time_zone - widgets.first[5].utc_offset.seconds,
         Date.new(2020, 12, 2), true],
        ['Budget Widget', 'Budge Text', 420, 7.734, BigDecimal(243.26, 5),
         DateTime.new(2019, 4, 1, 23, 59).in_time_zone - widgets.first[5].utc_offset.seconds,
         Date.new(2019, 12, 2), false]
      ]
    )

    flux_widg = Fluxor.joins(:widget)
                      .order('fluxors.id', 'widgets.id')
                      .pluck('fluxors.name', 'widgets.name AS name2')
    widg_wots = Widget.joins(:wotsit)
                      .order('widgets.id', 'wotsits.id')
                      .pluck('widgets.name', 'wotsits.name AS name2')

    expect(flux_widg).to eq([['Flux Capacitor', 'Squidget Widget'],
                             ['Flex Resistor', 'Budget Widget'],
                             ['Nix Resistor', 'Budget Widget']])
    expect(widg_wots).to eq([['Squidget Widget', 'Mr. Wotsit'],
                             ['Budget Widget', 'Mr. Budgit'],
                             ['Budget Widget', 'Mr. Fixit'],
                             ['Budget Widget', 'Mr. Budgit']])
  end
end
