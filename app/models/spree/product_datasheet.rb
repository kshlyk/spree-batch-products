module Spree
class ProductDatasheet < ActiveRecord::Base
  require 'csv'
  belongs_to :user
  
  attr_accessor :queries_failed, :records_failed, :records_matched, :records_updated, :touched_product_ids
  alias_method :products_touched, :touched_product_ids
  attr_accessible :xls_file_name, :xls, :deleted_at
  serialize :product_errors
  
  after_initialize do
    self.product_errors ||= []
  end
  
  before_save :update_statistics
  
  after_find :setup_statistics
  after_initialize :setup_statistics
  
  has_attached_file :xls, :url => "/uploads/product_datasheets/:id/:filename", 
                    :path => ":rails_root/public/uploads/product_datasheets/:id/:filename"
  
  validates_attachment_presence :xls
  validates_attachment_content_type :xls, :content_type => ['text/csv', 'text/plain']
  
  scope :not_deleted, where("spree_product_datasheets.deleted_at is NULL")
  scope :deleted, where("spree_product_datasheets.deleted_at is NOT NULL")
  
  ####################
  # Main logic of extension
  # Uses the spreadsheet to define the bounds for iteration (from first used column <inclusive> to first unused column <exclusive>)
  # Sets up statistic variables and separates the headers row from the rest of the spreadsheet
  # Iterates row-by-row to populate a hash of { :attribute => :value } pairs, uses this hash to create or update records accordingly
  ####################
  def perform
    ####################
    # Creating Variants:
    #   1) First cell of headers row must define 'id' as the search key
    #   2) The headers row must define 'product_id' as an attribute to be updated
    #   3) The row containing the values must leave 'id' blank, and define a valid id for 'product_id'
    #
    # Creating Products:
    #   1) First cell of headers row must define 'id' as the search key
    #   2) The row containing the values must leave 'id' blank, and define a valid id for 'product_id'
    #
    # Updating Products:
    #   1) The search key (first cell of headers row) must be present as a column name on the Products table
    #
    # Updating Variants:
    #   1) The search key must be present as a column name on the Variants table.
    ####################
    begin
      before_batch_loop
      
      idx = 0
      csv_enumerator do |row|
        if idx == 0
          @headers = []
          row.each do |key|
            method = "#{key}="
            if Product.new.respond_to?(method) or Variant.new.respond_to?(method)
              @headers << key
            else
              @headers << nil
            end
          end
          @primary_key = @headers[0]
        else
          handle_line(row, idx)
          sleep 0
        end
        idx += 1
      end
      self.update_attribute(:processed_at, Time.now)
      
    ensure
      after_batch_loop
      after_processing
    end
  end
  
  def csv_enumerator(&block)
    if self.class.attachment_definitions[:xls][:storage] == :s3
      CSV.parse(open xls.url).each(&block)
    else
      CSV.foreach(xls.path, {}, &block)
    end
  end
  
  def handle_line(row, idx)
    attr_hash = {}
    lookup_value = (row[0].is_a?(Float) ? row[0].to_i : row[0]).to_s

    row.each_with_index do |value, i|
      next unless value and key = @headers[i] # ignore cell if it has no value
      attr_hash[key] = value
    end
    
    return if attr_hash.empty?
    
    if @primary_key == 'id' and lookup_value.empty? and @headers.include? 'product_id'
      create_variant(attr_hash)
    elsif @primary_key == 'id' and lookup_value.empty?
      create_product(attr_hash)
    elsif Product.column_names.include?(@primary_key)
      products = find_products @primary_key, lookup_value
      update_products(products, attr_hash)
      
      self.touched_product_ids += products.map{|p| p.id}
    elsif Variant.column_names.include?(@primary_key)
      products = find_products_by_variant @primary_key, lookup_value
      update_products(products, attr_hash)
      
      self.touched_product_ids += products.map{|p| p.id}
    else
      @queries_failed = @queries_failed + 1
    end
  end
  
  
  def before_batch_loop
    self.touched_product_ids = []

    if Spree::Product._save_callbacks.detect {|cb| cb.kind == :after && cb.filter == :perform_index_tasks}
      Spree::Product.skip_callback(:save, :after, :perform_index_tasks)
    end
  end
  
  def after_batch_loop
    if Spree::Product.searchable? && Spree::Product._save_callbacks.detect {|cb| cb.kind == :after && cb.filter == :perform_index_tasks}.nil?
      Spree::Product.set_callback(:save, :after, :perform_index_tasks)
    end
  end
  
  def after_processing
    Spree::Product.solr_optimize if Spree::Product.respond_to? :solr_optimize
  end
  
  def create_product(attr_hash)
    new_product = Spree::Product.new(attr_hash)
    unless new_product.save
      @queries_failed += 1
      self.product_errors += new_product.errors.to_a.map{|e| "Product #{new_product.sku}: #{e.downcase}"}.uniq
    end
  end
  
  def create_variant(attr_hash)
    new_variant = Spree::Variant.new(attr_hash)
    begin
      new_variant.save
    rescue
      @queries_failed += 1
      self.product_errors += new_variant.errors.to_a.map{|e| "Variant #{new_variant.sku}: #{e.downcase}"}.uniq
    end
  end
  
  def update_products(products, attr_hash)
    products.each do |product|
      product.instance_variable_set "@readonly", false
      if product.update_attributes attr_hash
        @records_updated +=1
      else
        @records_failed += 1
        self.product_errors += product.errors.to_a.map{|e| "Product #{product.sku}: #{e.downcase}"}.uniq
      end
    end
  end
  
  def find_products_by_variant key, value
    products = Spree::Product.joins(:variants_including_master).where(:spree_variants => {key => value}).all
    @records_matched += products.size
    @queries_failed += 1 if products.size == 0
    
    products
  end
  
  def find_products key, value
    products = Spree::Product.where(key => value).all
    @records_matched += products.size
    @queries_failed += 1 if products.size == 0
    
    products
  end
  
  def update_statistics
    self.matched_records = @records_matched
    self.failed_records = @records_failed
    self.updated_records = @records_updated
    self.failed_queries = @queries_failed
  end
  
  def setup_statistics
    @queries_failed = 0
    @records_failed = 0
    @records_matched = 0
    @records_updated = 0
  end
  
  def processed?
    processed_at.present?
  end
  
  def deleted?
    deleted_at.present?
  end
end
end
