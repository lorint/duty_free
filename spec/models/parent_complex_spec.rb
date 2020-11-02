# frozen_string_literal: true

require 'spec_helper'
require 'csv'

# Set up Models
# =============

# Two without IMPORT_TEMPLATEs

class Parent < ActiveRecord::Base
  has_many :children, dependent: :destroy

  def self.import(file)
    df_import(file)
  end
end

class Child < ActiveRecord::Base
  belongs_to :parent
end

# Examples
# ========

RSpec.describe Parent, type: :model do
  before(:each) do
    Parent.destroy_all
  end

  context 'with valid attributes' do
    it 'should be able to suggest a template that relates Parent and Child' do
      # Default template has only Parent information
      template = Parent.suggest_template
      # All columns includes the three string columns in the parents table
      expect(template[:all]).to eq([:firstname, :lastname, :address])
      # Uniques finds the first available string column
      expect(template[:uniques]).to eq([:firstname])

      # ----------------------------------------------------
      # Now including tables directly linked by any has_many
      template_has_many_children = Parent.suggest_template(0, true)
      # All columns should include the three string columns in the parents table,
      # plus the first column in children
      expect(template_has_many_children[:all]).to eq([:firstname, :lastname, :address,
                                     { children: [:firstname] }])
      # # Uniques should now also include the first available string column in the children table
      # expect(template_has_many_children[:uniques]).to eq ([:firstname, :children_firstname])

      # Using this template should generate column headers
      column_headers = Parent.df_export(false, template_has_many_children)
      expect(column_headers).to eq(['Firstname', 'Lastname', 'Address', 'Children Firstname'])

      # ------------------------------------------------------------------------------
      # Now including one full hop away of tables, and directly linked by any has_many
      template_with_children = Parent.suggest_template(1, true)
      # All columns should include the three string columns in the parents table,
      # plus the first column in children
      expect(template_with_children[:all]).to eq([:firstname, :lastname, :address,
                                     { children: [:firstname, :lastname, :dateofbirth] }])
      # # Uniques should still include the first available string column in the children table
      # expect(template_with_children[:uniques]).to eq ([:firstname, :children_firstname])

      # Using this template should generate column headers
      column_headers = Parent.df_export(false, template_with_children)
      expect(column_headers).to eq(
        ['Firstname', 'Lastname', 'Address', 'Children Firstname', 'Children Lastname', 'Children Dateofbirth']
      )
      # Adding aliases to the template using :as allows for custom column headings to work
      template_with_children[:as] = {
        'parent_1_firstname' => 'Firstname',
        'parent_1_lastname' => 'Lastname',
        'address' => 'Address',
        'childfirstname' => 'Children Firstname',
        'childlastname' => 'Children Lastname',
        'childdateofbirth' => 'Children Dateofbirth'
      }
      column_headers = Parent.df_export(false, template_with_children)
      expect(column_headers).to eq(
        %w[parent_1_firstname parent_1_lastname address childfirstname childlastname childdateofbirth]
      )
    end

    it 'should be able to import from an array' do
      child_info = [
        ['Firstname', 'Lastname', 'Address', 'Children Firstname', 'Children Lastname', 'Children Dateofbirth'],
        ['Homer', 'Simpson', '742 Evergreen Terrace', 'Bart', 'Simpson', '2002-11-11'],
        ['Homer', 'Simpson', '742 Evergreen Terrace', 'Lisa', 'Simpson', '2006-10-01'],
        ['Marge', 'Simpson', '742 Evergreen Terrace', 'Bart', 'Simpson', '2002-11-11'],
        ['Marge', 'Simpson', '742 Evergreen Terrace', 'Lisa', 'Simpson', '2006-10-01'],
        ['Clancey', 'Wiggum', '732 Evergreen Terrace', 'Ralph', 'Wiggum', '2005-04-01']
      ]

      # Perform the import on CSV data
      # Get the suggested default import template for the Parent model
      template_with_children = Parent.suggest_template(1, true)
      # Initially we only force uniqueness on the first string column of Parent
      expect(template_with_children[:uniques]).to eq([:firstname])
      # Add in uniqueness for the Child portion of each incoming row.  (Without this then
      # the import would end up with three children stored instead of five -- one for each
      # of the parents -- and in both cases Bart would be updated with Lisa, so there
      # would be two Lisa entries and no Bart entries.)
      # Note that the prefix "children_" comes from the name of the has_many association
      # found in the Parent model.
      template_with_children[:uniques] << :children_firstname

      # Do the import
      expect {
        Parent.df_import(child_info, template_with_children)
      }.not_to raise_error

      parents = Parent.order(:id).pluck(:firstname, :lastname, :address)
      expect(parents.count).to eq(3)
      expect(parents).to eq([['Homer', 'Simpson', '742 Evergreen Terrace'], ['Marge', 'Simpson', '742 Evergreen Terrace'], ['Clancey', 'Wiggum', '732 Evergreen Terrace']])

      parent_ids = Parent.order(:id).pluck(:id)
      children = Child.order(:id).pluck(:firstname, :lastname, :dateofbirth, :parent_id)
      expect(children.count).to eq(5)
      expect(children).to eq([
        ['Bart', 'Simpson', Date.new(2002, 11, 11), parent_ids.first],
        ['Lisa', 'Simpson', Date.new(2006, 10, 1), parent_ids.first],
        ['Bart', 'Simpson', Date.new(2002, 11, 11), parent_ids.second],
        ['Lisa', 'Simpson', Date.new(2006, 10, 1), parent_ids.second],
        ['Ralph', 'Wiggum', Date.new(2005, 4, 1), parent_ids.third]
      ])
      # As an aside -- if you feel that seeing these four entries is inappropriate repetition
      # then consider that having only this one to many relationship means that for two parents
      # that have the same children, being as each Child object has just one foreign key then
      # it is impossible to have them relate to multiple parents.  If you want to be able to
      # properly represent Bart and Lisa just once each then what's really appropriate here is
      # a different data structure, a many to many relationship that uses 3 tables.  This setup
      # would have a central associative table in the middle that belongs to both Parent and
      # Child, like this:
      #
      # .    Parent --> ChildParent <-- Child
      #
      # To see an example import with this many-to-many setup in action, check out
      # recipe_spec.rb.
    end

    it 'should be able to import from CSV data' do
      # Set the import template for the Parent model to a suggested default
      # Parent::IMPORT_TEMPLATE = Parent.suggest_template(1, true)

      # Firstname,Lastname,Address,Children Firstname,Children Lastname,Children Dateofbirth
      child_info_csv = CSV.new(
        <<-CSV
parent_1_firstname,parent_1_lastname,address,childfirstname,childlastname,childdateofbirth
John,Wilson,68 Bell Road,Jessica,Wilson,2002-11-11
John,Wilson,68 Bell Road,Josh,Wilson,2006-10-01
        CSV
      )

      # Perform the import on CSV data, overriding the default generated template
      expect { Parent.df_import(child_info_csv, {
        uniques: [:firstname, :children_firstname],
        required: [],
        all: [:firstname, :lastname, :address,
          { children: [:firstname, :lastname, :dateofbirth] }],
        # An alias for each incoming column
        as: {
              'parent_1_firstname' => 'Firstname',
              'parent_1_lastname' => 'Lastname',
              'address' => 'Address',
              'childfirstname' => 'Children Firstname',
              'childlastname' => 'Children Lastname',
              'childdateofbirth' => 'Children Dateofbirth'
            }
      }.freeze) }.not_to raise_error

      parents = Parent.order(:id).pluck(:firstname, :lastname, :address)
      expect(parents.count).to eq(1)
      expect(parents).to eq([['John', 'Wilson', '68 Bell Road']])

      children = Child.order(:id).pluck(:firstname, :lastname, :dateofbirth)
      expect(children.count).to eq(2)
      expect(children).to eq(
        [
          ['Jessica', 'Wilson', Date.new(2002, 11, 11)],
          ['Josh', 'Wilson', Date.new(2006, 10, 1)]
        ]
      )
    end
  end
end
