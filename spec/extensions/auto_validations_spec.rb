require_relative "spec_helper"

describe "Sequel::Plugins::AutoValidations" do
  before do
    fetch_proc = proc do |sql|
      if sql =~ /'a{51}'|'uniq'/
        sql =~ /1 AS one/ ? {:v=>nil} : {:v=>0}
      else
        {:v=>1}
      end
    end

    db = Sequel.mock(:fetch=>fetch_proc)
    def db.schema_parse_table(*) true; end
    def db.schema(t, *)
      t = t.first_source if t.is_a?(Sequel::Dataset)
      return [] if t != :test
      [[:id, {:primary_key=>true, :type=>:integer, :allow_null=>false}],
       [:name, {:primary_key=>false, :type=>:string, :allow_null=>false, :max_length=>50}],
       [:num, {:primary_key=>false, :type=>:integer, :allow_null=>true, :min_value=>-100000, :max_value=>100000}],
       [:d, {:primary_key=>false, :type=>:date, :allow_null=>false}],
       [:nnd, {:primary_key=>false, :type=>:string, :allow_null=>false, :default=>'nnd'}]]
    end
    def db.supports_index_parsing?() true end
    db.singleton_class.send(:alias_method, :supports_index_parsing?, :supports_index_parsing?)
    def db.indexes(t, *)
      raise if t.is_a?(Sequel::Dataset)
      return [] if t != :test
      {:a=>{:columns=>[:name, :num], :unique=>true}, :b=>{:columns=>[:num], :unique=>false}}
    end
    db.singleton_class.send(:alias_method, :indexes, :indexes)
    @c = Class.new(Sequel::Model(db[:test]))
    @c.send(:def_column_accessor, :id, :name, :num, :d, :nnd)
    @c.raise_on_typecast_failure = false
    @c.plugin :auto_validations
    @m = @c.new
    db.sqls
  end

  it "should have automatically created validations" do
    @m.num = 100001
    @m.valid?.must_equal false
    @m.errors.must_equal(:d=>["is not present"], :name=>["is not present"], :num=>["is greater than maximum allowed value"])

    @m.set(:num=>-100001, :name=>"")
    @m.valid?.must_equal false
    @m.errors.must_equal(:d=>["is not present"], :num=>["is less than minimum allowed value"])

    @m.set(:d=>'/', :num=>'a', :name=>"a\0b")
    @m.valid?.must_equal false
    @m.errors.must_equal(:d=>["is not a valid date"], :num=>["is not a valid integer"], :name=>["contains a null byte"])

    @m.set(:d=>Date.today, :num=>1, :name=>'')
    @m.valid?.must_equal false
    @m.errors.must_equal([:name, :num]=>["is already taken"])

    @m.set(:name=>'a'*51)
    @m.valid?.must_equal false
    @m.errors.must_equal(:name=>["is longer than 50 characters"])
  end

  it "should add errors to columns that already have errors by default" do
    def @m.validate
      errors.add(:name, 'no good')
      super
    end
    @m.d = Date.today
    @m.valid?.must_equal false
    @m.errors.must_equal(:name=>['no good', "is not present"])
  end

  it "should not add errors to columns that already have errors when using :skip_invalid plugin option" do
    @c.plugin :auto_validations, :skip_invalid=>true
    def @m.validate
      errors.add(:name, 'no good')
      super
    end
    @m.d = Date.today
    @m.valid?.must_equal false
    @m.errors.must_equal(:name=>['no good'])
  end

  it "should handle simple unique indexes correctly" do
    def (@c.db).indexes(t, *)
      raise if t.is_a?(Sequel::Dataset)
      return [] if t != :test
      {:a=>{:columns=>[:name], :unique=>true}}
    end
    @c.plugin :auto_validations
    @m.set(:name=>'foo', :d=>Date.today)
    @m.valid?.must_equal false
    @m.errors.must_equal(:name=>["is already taken"])
  end

  it "should validate using the underlying column values" do
    @c.send(:define_method, :name){super() * 2}
    @c.db.fetch = {:v=>nil}
    @m.set(:d=>Date.today, :num=>1, :name=>'b'*26)
    @m.valid?.must_equal true
  end

  it "should handle databases that don't support index parsing" do
    def (@m.db).supports_index_parsing?() false end
    @m.model.send(:setup_auto_validations)
    @m.set(:d=>Date.today, :num=>1, :name=>'1')
    @m.valid?.must_equal true
  end

  it "should handle models that select from subqueries" do
    @c.set_dataset @c.dataset.from_self
    @c.send(:setup_auto_validations)
  end

  it "should support :not_null=>:presence option" do
    @c.plugin :auto_validations, :not_null=>:presence
    @m.set(:d=>Date.today, :num=>'')
    @m.valid?.must_equal false
    @m.errors.must_equal(:name=>["is not present"])
  end

  it "should automatically validate explicit nil values for columns with not nil defaults" do
    @m.set(:d=>Date.today, :name=>1, :nnd=>nil)
    @m.id = nil
    @m.valid?.must_equal false
    @m.errors.must_equal(:id=>["is not present"], :nnd=>["is not present"])
  end

  it "should allow skipping validations by type" do
    @c = Class.new(@c)
    @m = @c.new
    @m.skip_auto_validations(:not_null) do
      @m.valid?.must_equal true
      @m.nnd = nil
      @m.valid?.must_equal true
    end
    @m.set(:nnd => 'nnd')
    @c.skip_auto_validations(:not_null)
    @m.valid?.must_equal true
    @m.nnd = nil
    @m.valid?.must_equal true

    @m.set(:d=>'/', :num=>'a', :name=>'1')
    @m.valid?.must_equal false
    @m.errors.must_equal(:d=>["is not a valid date"], :num=>["is not a valid integer"])

    @m.skip_auto_validations(:types, :unique) do
      @m.valid?.must_equal true
    end
    @m.skip_auto_validations(:types) do
      @m.valid?.must_equal false
      @m.errors.must_equal([:name, :num]=>["is already taken"])
    end
    @c.skip_auto_validations(:types)
    @m.valid?.must_equal false
    @m.errors.must_equal([:name, :num]=>["is already taken"])

    @m.skip_auto_validations(:unique) do
      @m.valid?.must_equal true
    end
    @c.skip_auto_validations(:unique)
    @m.valid?.must_equal true

    @m.set(:name=>'a'*51)
    @m.valid?.must_equal false
    @m.errors.must_equal(:name=>["is longer than 50 characters"])

    @m.skip_auto_validations(:max_length) do
      @m.valid?.must_equal true
    end
    @c.skip_auto_validations(:max_length)
    @m.valid?.must_equal true
  end

  it "should allow skipping all auto validations" do
    @c = Class.new(@c)
    @m = @c.new
    @m.skip_auto_validations(:all) do
      @m.valid?.must_equal true
      @m.set(:d=>'/', :num=>'a', :name=>'1')
      @m.valid?.must_equal true
      @m.set(:name=>'a'*51)
      @m.valid?.must_equal true
    end
    @m = @c.new
    @c.skip_auto_validations(:all)
    @m.valid?.must_equal true
    @m.set(:d=>'/', :num=>'a', :name=>'1')
    @m.valid?.must_equal true
    @m.set(:name=>'a'*51)
    @m.valid?.must_equal true
  end

  it "should skip min/max value validations when skipping type validations" do
    @m.set(:d=>Date.today, :num=>100001, :name=>'uniq')
    @m.valid?.must_equal false
    @m.skip_auto_validations(:types) do
      @m.valid?.must_equal true
    end

    @m.num = -100001
    @m.valid?.must_equal false
    @m.skip_auto_validations(:types) do
      @m.valid?.must_equal true
    end
  end

  it "should default to skipping all auto validations if no arguments given to instance method" do
    @c = Class.new(@c)
    @m = @c.new
    @m.skip_auto_validations do
      @m.valid?.must_equal true
      @m.set(:d=>'/', :num=>'a', :name=>'1')
      @m.valid?.must_equal true
      @m.set(:name=>'a'*51)
      @m.valid?.must_equal true
    end
  end

  it "should work correctly in subclasses" do
    @c = Class.new(@c)
    @m = @c.new
    @m.num = 100001
    @m.valid?.must_equal false
    @m.errors.must_equal(:d=>["is not present"], :name=>["is not present"], :num=>["is greater than maximum allowed value"])

    @m.set(:num=>-100001, :name=>"")
    @m.valid?.must_equal false
    @m.errors.must_equal(:d=>["is not present"], :num=>["is less than minimum allowed value"])

    @m.set(:d=>'/', :num=>'a', :name=>"a\0b")
    @m.valid?.must_equal false
    @m.errors.must_equal(:d=>["is not a valid date"], :num=>["is not a valid integer"], :name=>["contains a null byte"])

    @m.set(:d=>Date.today, :num=>1, :name=>'')
    @m.valid?.must_equal false
    @m.errors.must_equal([:name, :num]=>["is already taken"])

    @m.set(:name=>'a'*51)
    @m.valid?.must_equal false
    @m.errors.must_equal(:name=>["is longer than 50 characters"])
  end

  it "should work correctly in STI subclasses" do
    @c.plugin(:single_table_inheritance, :num, :model_map=>{1=>@c}, :key_map=>proc{[1, 2]})
    sc = Class.new(@c)
    @m = sc.new
    @m.valid?.must_equal false
    @m.errors.must_equal(:d=>["is not present"], :name=>["is not present"])

    @m.set(:d=>'/', :num=>'a', :name=>'1')
    @m.valid?.must_equal false
    @m.errors.must_equal(:d=>["is not a valid date"], :num=>["is not a valid integer"])

    @m.db.sqls
    @m.set(:d=>Date.today, :num=>1)
    @m.valid?.must_equal false
    @m.errors.must_equal([:name, :num]=>["is already taken"])
    @m.db.sqls.must_equal ["SELECT 1 AS one FROM test WHERE ((name = '1') AND (num = 1)) LIMIT 1"]

    @m.set(:name=>'a'*51)
    @m.valid?.must_equal false
    @m.errors.must_equal(:name=>["is longer than 50 characters"])
  end

  it "should work correctly when changing the dataset" do
    @c.set_dataset(@c.db[:foo])
    @c.new.valid?.must_equal true
  end

  it "should support setting validator options" do
    sc = Class.new(@c)
    sc.plugin :auto_validations,
      :max_length_opts=> {:message=> 'ml_message'},
      :max_value_opts=> {:message=> 'mv_message'},
      :min_value_opts=> {:message=> 'min_message'},
      :no_null_byte_opts=> {:message=> 'nnb_message'},
      :schema_types_opts=> {:message=> 'st_message'},
      :explicit_not_null_opts=> {:message=> 'enn_message'},
      :unique_opts=> {:message=> 'u_message'}

    @m = sc.new
    @m.set(:name=>'a'*51, :d => '/', :nnd => nil, :num=>1)
    @m.valid?.must_equal false
    @m.errors.must_equal(:name=>["ml_message"], :d=>["st_message"], :nnd=>["enn_message"])

    @m = sc.new
    @m.set(:name=>1, :num=>1, :d=>Date.today)
    @m.valid?.must_equal false
    @m.errors.must_equal([:name, :num]=>["u_message"])

    @m.set(:num=>100001, :name=>"a\0b")
    @m.valid?.must_equal false
    @m.errors.must_equal(:name=>["nnb_message"], :num=>["mv_message"])

    @m.num = -100001
    @m.valid?.must_equal false
    @m.errors.must_equal(:name=>["nnb_message"], :num=>["min_message"])
  end

  it "should store modifying auto validation information in mutable auto_validate_* attributes" do
    @c.auto_validate_not_null_columns.frozen?.must_equal false
    @c.auto_validate_explicit_not_null_columns.frozen?.must_equal false
    @c.auto_validate_max_length_columns.frozen?.must_equal false
    @c.auto_validate_unique_columns.frozen?.must_equal false
    @c.auto_validate_no_null_byte_columns.frozen?.must_equal false
    @c.auto_validate_max_value_columns.frozen?.must_equal false
    @c.auto_validate_min_value_columns.frozen?.must_equal false
    @c.auto_validate_not_null_columns.frozen?.must_equal false

    @c.auto_validate_explicit_not_null_columns.sort.must_equal [:id, :nnd]
    @c.auto_validate_max_length_columns.sort.must_equal [[:name, 50]]
    @c.auto_validate_unique_columns.sort.must_equal [[:name, :num]]
    @c.auto_validate_no_null_byte_columns.sort.must_equal [:name, :nnd]
    @c.auto_validate_max_value_columns.sort.must_equal [[:num, 100000]]
    @c.auto_validate_min_value_columns.sort.must_equal [[:num, -100000]]
  end

  it "should copy auto validation information when subclassing" do
    sc = Class.new(@c)
    @c.auto_validate_not_null_columns.clear
    @c.auto_validate_explicit_not_null_columns.clear
    @c.auto_validate_max_length_columns.clear
    @c.auto_validate_unique_columns.clear
    @c.auto_validate_no_null_byte_columns.clear
    @c.auto_validate_max_value_columns.clear
    @c.auto_validate_min_value_columns.clear
    @c.auto_validate_not_null_columns.clear

    sc.auto_validate_explicit_not_null_columns.sort.must_equal [:id, :nnd]
    sc.auto_validate_max_length_columns.sort.must_equal [[:name, 50]]
    sc.auto_validate_unique_columns.sort.must_equal [[:name, :num]]
    sc.auto_validate_no_null_byte_columns.sort.must_equal [:name, :nnd]
    sc.auto_validate_max_value_columns.sort.must_equal [[:num, 100000]]
    sc.auto_validate_min_value_columns.sort.must_equal [[:num, -100000]]
  end

  it "should not allow modifying auto validation information for frozen model classes" do
    @c.freeze
    @c.auto_validate_not_null_columns.frozen?.must_equal true
    @c.auto_validate_explicit_not_null_columns.frozen?.must_equal true
    @c.auto_validate_max_length_columns.frozen?.must_equal true
    @c.auto_validate_unique_columns.frozen?.must_equal true
    @c.auto_validate_no_null_byte_columns.frozen?.must_equal true
    @c.auto_validate_max_value_columns.frozen?.must_equal true
    @c.auto_validate_min_value_columns.frozen?.must_equal true
  end
end
