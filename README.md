# DutyFree gem

### Import and Export your data in the least taxing way possible!

An ActiveRecord extension that simplifies importing and exporting of data stored in
one or more models.  Source and destination can be CSV, XLS, XLSX, ODT, HTML tables,
or simple Ruby arrays.  What really sets this gem apart from other similar gems is
the ability to work with related tables as a set.  For example you might have data
from one spreadsheet target category, subcategory, and product tables all at once,
seamlessly importing and exporting that data.

## Documentation

| Version        | Documentation                                             |
| -------------- | --------------------------------------------------------- |
| Unreleased     | https://github.com/lorint/duty_free/blob/master/README.md |
| 1.0.3          | https://github.com/lorint/duty_free/blob/v1.0.3/README.md |

## Table of Contents

<!-- toc -->

- [1. Getting Started](#1-getting-started)
  - [1.a. Compatibility](#1a-compatibility)
  - [1.b. Installation](#1b-installation)
  - [1.c. Generating Templates](#1c-generating-templates)
  - [1.d. Exporting Data](#1d-exporting-data)
  - [1.e. Importing Data](#1e-importing-data)
- [2. More Fancy Exports](#2-limiting-what-is-versioned-and-when)
  - [2.a. Simplify Column Names Using Aliases](#2a-simplify-column-names-using-aliases)
  - [2.b. Filtering the Rows to Export](#2b-filtering-the-rows-to-export)
  - [2.c. Seeing the Resulting JOIN Strategy and SQL Used](#2c-seeing-the-resulting-join-strategy-and-sql-used)
- [3. More Fancy Imports](#3-more-fancy-imports)
  - [3.a. Self-referencing models](#3a-self-referencing-models)
  - [3.b. Polymorphic Inheritance](#3b-polymorphic-inheritance)
  - [3.c. Single Table Inheritance (STI)](#3c-single-table-inheritance-sti)
  - [3.d. Tweaking For Performance](#3d-tweaking-for-performance)
  - [3.e. Using Callbacks](#3e-using-callbacks)
- [4. Similar Gems](#10-similar-gems)
- [Problems](#problems)
- [Contributing](#contributing)
- [Intellectual Property](#intellectual-property)

<!-- tocstop -->

## 1. Getting Started

### 1.a. Compatibility

| duty_free      | branch     | tags   | ruby     | activerecord  |
| -------------- | ---------- | ------ | -------- | ------------- |
| unreleased     | master     |        | >= 2.4.0 | >= 4.2, < 6   |
| 1.0            | 1-stable   | v1.x   | >= 2.4.0 | >= 4.2, < 6   |

### 1.b. Installation

1. Add DutyFree to your `Gemfile`.

    `gem 'duty_free'`

1. To test things, then from within `rails c`, you can see that it's working by exporting some data from
   one of your models.  In this case let's have our `Product` data go out to an array.  `Product` does not yet specify anything about DutyFree, and seeing this the `#df_export` routine automatically generates its own temporary template behind-the-scenes in order to define columns.  The parameter `true` being fed in says to not just show a header with column names, but also export all data as well.  To retrieve the data, the generated template is adapted to leverage ActiveRecord's `#left_joins` call to create an appropriate SQL query and retrieve all the Product data:

    ```ruby
    northwind$ bin/rails c
    Running via Spring preloader ...
    Loading development environment ...
    2.6.5 :001 > Product.df_export(true)
    Product Load (0.6ms)  SELECT "products"."product_name", categories.category_name AS category_category_name, "products"."quantity_per_unit", "products"."unit_price", "products"."units_in_stock", "products"."units_on_order", "products"."reorder_level", "products"."discontinued" FROM "products" LEFT OUTER JOIN "categories" ON "categories"."id" = "products"."category_id"
    => [["* Product Name", "* Category", "Quantity Per Unit", "Unit Price", "Units In Stock", "Units On Order", "Reorder Level", "Discontinued"], ["Camembert Pierrot", "Seafood", "100 - 100 g pieces", "43.9", "49", "0", "30", "No"], ["Pâté chinois", "Seafood", "25 - 825 g cans", "45.6", "26", "0", "0", "Yes"], ["Uncle Bob's Organic Dried Pears", "Produce", "50 bags x 30 sausgs.", "123.79", "0", "0", "0", "Yes"], ... ]
    ```

   The SQL query JOINs `products` and `categories` because the template generation logic found a `belongs_to` association going from `Product` to `Category`.  Rather than expose any numeric ID key data used between these tables, `#df_export` and `#df_import` strive to work only with non-metadata information, i.e. only human-readable columns.  The same kind of data you'd expect to find in the average spreadsheet.  To override this behaviour a template can be defined that indicates exactly the columns you'd like to use during import and export.  By default any ID columns, as well as `created_at` and `updated_at`, are omitted.

### 1.c. Generating Templates

If you'd like to examine the default internal template that is generated, then use `#suggest_template` like this:

```ruby
2.6.5 :002 > Product.suggest_template

# Place the following into app/models/product.rb:
# Generated by:  Product.suggest_template(0, false, true)
IMPORT_TEMPLATE = {
  uniques: [:product_name],
  required: [],
  all: [:product_name, :quantity_per_unit, :unit_price, :units_in_stock, :units_on_order, :reorder_level, :discontinued,
    { category: [:category_name] }],
  as: {}
}.freeze
# ------------------------------------------

 => {:uniques=>[:product_name], :required=>[], :all=>[:product_name, ...
2.6.5 :002 >
```

Note the constant `IMPORT_TEMPLATE`.  Although its name might make it sound at first like it's only used for importing, as we have seen from above this template is also used for exporting.  Specifically the `:all` portion defines the `belongs_to` and `has_many` links to follow, as well as all columns to retrieve from related tables.

To customise things, just take the displayed `IMPORT_TEMPLATE` constant and place it within your `Product` model as a handy starting point.  This will describe to `#df_export` and `#df_import` which columns to utilise.  The `:uniques` and `:required` data indicates which columns can be used during import to identify unique new rows vs existing rows, in order to choose on a row-by-row basis between doing an INSERT vs an UPDATE.  With `:uniques` defined, INSERT vs UPDATE is automatically determined by seeing if any existing row matches against the incoming rows for those specific columns.  If you always want to add new rows then leave :uniques empty, and then doing the same import three times would generate triple the data, leaving you to sort out the duplicates perhaps with ActiveRecord's own :id and :created_at columns.  So generally it's a good idea to populate the :uniques entry with appropriate values to minimise the risk of duplicate data coming in.

Seeing this simple starting template for `Product` is useful, but perhaps you'd like a more thorough template to work with.  After all, ActiveRecord is a very powerful ORM when used with relational data sets, so as long as you've got appropriate `belongs_to` and `has_many` associations established then `#suggest_template` can use these to work across multiple related tables.  Effectively the schema in your application becomes a graph of nodes which gets traversed.  Let's see how easy it is to create a more rounded out template, this time examining a template for the `Order` model.  Not specifying any extra "hops" brings back a template with this `:all` portion:

```ruby
all: [:order_date, :required_date, :shipped_date, :ship_via_id, :freight, :ship_name, :ship_address, :ship_city, :ship_region, :ship_postal_code, :ship_country, :customer_code,
    { customer: [:company_code] },
    { employee: [:first_name] }]
```

You might want to include more tables, or have the existing ones be more "rounded out" with all their columns.  for these kinds of tricks the `#suggest_template` method accepts two incoming parameters, the number of hops to traverse to related tables, and a boolean for if you would like to also navigate across `has_many` associations in addition to the `belongs_to` associations (which are always traversed).  In the last example, even without specifying a number of hops the related tables `customer` and `employee` were referenced, but each with just one column listed as the system did a best-effort approach to find the most human-readable unique-ish column to utilise for doing a lookup.  These appeared because the `Order` model has belongs_to associations, and thus foreign keys for, these two associated tables.  The template generation logic examined these two destination tables, and not knowing initially what non-metadata column might be considered unique, had just chosen the first string columns available in these, which were `company_code` and `first_name`.  Thankfully these end up being good choices for our data.

To go further, we can now specify one additional hop to traverse from that starting table, as well as indicate that we'd like to go across the `has_many` associations as well, by doing:

```ruby
Order.suggest_template(1, true)
```

which returns this `:all` entry:

```ruby
all: [:order_date, :required_date, :shipped_date, :ship_via_id, :freight, :ship_name, :ship_address, :ship_city, :ship_region, :ship_postal_code, :ship_country, :customer_code,
    { customer: [:company_code, :company_name, :contact_name, :contact_title, :address, :city, :region, :postal_code, :country, :phone, :fax] },
    { employee: [:first_name, :last_name, :title, :title_of_courtesy, :birth_date, :hire_date, :address, :city, :region, :postal_code, :country, :home_phone, :extension, :notes,
      { reports_to: [:first_name] }] },
    { order_details: [:unit_price, :quantity, :discount,
      { product: [:product_name] }] }]
```

We see here that the entries for `customer` and `employee` are much more rounded out, having all their column detail included.  Plus it further includes listings for any belongs_to associations these tables have, such as `reports_to` for `employee`.  This is effectively already two hops away even though we had only specified one, so what gives?  Well, it would be impossible to represent an entry for the reports_to_id unless you were using numerical IDs, so in lieu of this DutyFree goes the distance and finds some kind of human-readable option to let you associate an Employee to their boss (through the reports_to association).

Because :customer and :employee have all columns shown, this allows all their data to be exported or imported along with the `Order` data.  Doing an export will do the JOINs and grab all these columns in what would be termed a "denormalised" set of data, much like many people's busy spreadsheets resemble.  If you put this into Excel and remove a few columns, such as omitting :region, :fax, and :home_phone, then the import is fine with this and simply puts NULL values in the database for whatever columns are omitted.  As well, if you'd like to rearrange the order of the columns then it works fine.  Because the first row contains the column header data, the system is able to identify which columns relate to which data.

The `:order_details` entry is there simply because we specified to also include `has_many`, this by calling the method with the second argument as `true`.  Generally it's best to only traverse `belongs_to` associations, which by default is all that `#suggest_template` tries to do.  But in this case it would be impossible to populate `order_details` (without using ID fields and numerical metadata anyway) unless we had possibility to use this kind of `has_many` linkage.  So including `has_many` associations here makes total sense.

### 1.d. Exporting Data

(Coming soon)

### 1.e. Importing Data

(Coming soon)

## 2. More Fancy Exports

### 2.a. Simplify Column Names Using Aliases

(Coming soon)

### 2.b. Filtering the Rows to Export

(Coming soon)

### 2.c. Seeing the Resulting JOIN Strategy and SQL Used

(Coming soon)

### 2.d. Turning DutyFree Off

(Coming soon)

### 2.e. Limiting the Number of Versions Created

(Coming soon)

## 3. More Fancy Imports

### 3.a. Self-referencing models

(Coming soon)

### 3.b. Polymorphic Inheritance

(Coming soon)

### 3.c. Single Table Inheritance (STI)

(Coming soon)

### 3.d. Tweaking For Performance

(Coming soon)

### 3.e. Using Callbacks

(Coming soon)

## Problems

Please use GitHub's [issue tracker](https://github.com/lorint/duty_free/issues).

## Contributing

See our [contribution guidelines][5]

## Intellectual Property

Copyright (c) 2020 Lorin Thwaits (lorint@gmail.com)
Released under the MIT licence.

[1]: https://github.com/lorint/duty_free/tree/1-stable
[3]: http://api.rubyonrails.org/classes/ActiveRecord/Associations/ClassMethods.html#module-ActiveRecord::Associations::ClassMethods-label-Polymorphic+Associations
[4]: http://api.rubyonrails.org/classes/ActiveRecord/Base.html#class-ActiveRecord::Base-label-Single+table+inheritance
[5]: https://github.com/lorint/duty_free/blob/master/doc/CONTRIBUTING.md
