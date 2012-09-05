class ProductDatasheet < ActiveRecord::Base
  belongs_to :user
  
  attr_accessor :queries_failed, :records_failed, :records_matched, :records_updated, :touched_product_ids
  alias_method :products_touched, :touched_product_ids
  serialize :product_errors
  
  after_initialize do
    self.product_errors ||= []
  end
  
  before_save :update_statistics
  
  after_find :setup_statistics
  after_initialize :setup_statistics
  
  has_attached_file :xls, :path => ":rails_root/uploads/product_datasheets/:id/:basename.:extension"  
  
  validates_attachment_presence :xls
  validates_attachment_content_type :xls, :content_type => ['application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'application/vnd.oasis.opendocument.spreadsheet', 'text/plain']
  
  scope :not_deleted, where("product_datasheets.deleted_at is NULL")
  scope :deleted, where("product_datasheets.deleted_at is NOT NULL")
  
  def path
    "#{Rails.root}/uploads/product_datasheets/#{self.id}/#{self.xls_file_name}"
  end
  
  ####################
  # Main logic of extension
  # Uses the spreadsheet to define the bounds for iteration (from first used column <inclusive> to first unused column <exclusive>)
  # Sets up statistic variables and separates the headers row from the rest of the spreadsheet
  # Iterates row-by-row to populate a hash of { :attribute => :value } pairs, uses this hash to create or update records accordingly
  ####################
  def perform
    workbook =
    begin
      SpreadsheetDocument.load(self.xls.to_s)
    rescue
      puts 'Failed to open xls attachment for processing'
      return false
    end

    columns_range = workbook.first_column..workbook.last_column
    header_row = workbook.row(workbook.first_row)
    
    headers = []
    
    header_row.each do |key|
      method = "#{key}="

      if Product.new.respond_to?(method) or Variant.new.respond_to?(method)
        headers << key
      else
        headers << nil
      end
    end
    
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
      
      ActiveRecord::Base.transaction do 
        range = (workbook.first_row+1..workbook.last_row)
        range.each do |idx|
          row = workbook.row(idx)
          attr_hash = {}
          
          for i in columns_range
            attr_hash[headers[i]] = row[i].to_s if row[i] and headers[i] # if there is a value and a key; .to_s is important for ARel
          end
          
          next if attr_hash.empty?
          
          if headers[0] == 'id' and row[0].nil? and headers.include? 'product_id'
            create_variant(attr_hash)
          elsif headers[0] == 'id' and row[0].nil?
            create_product(attr_hash)
          elsif Product.column_names.include?(headers[0])
            products = find_products headers[0], row[0]
            update_products(products, attr_hash)
            
            self.touched_product_ids += products.map(&:id)
          elsif Variant.column_names.include?(headers[0])
            products = find_products_by_variant headers[0], row[0]
            update_products(products, attr_hash)
            
            self.touched_product_ids += products.map(&:id)
          else
            @queries_failed = @queries_failed + 1
          end
          sleep 0
        end
        self.update_attribute(:processed_at, Time.now)
      end
      
    ensure
      after_batch_loop
      after_processing
    end
  end
  
  def before_batch_loop
    self.touched_product_ids = []

    Product.instance_methods.include?(:solr_save) and
      Product.skip_callback(:save, :after, :solr_save)
  end
  
  def after_batch_loop
    Product.instance_methods.include?(:solr_save) and
      Product.set_callback(:save, :after, :solr_save)
  end
  
  def after_processing
  
  end
  
  def create_product(attr_hash)
    new_product = Product.new(attr_hash)
    unless new_product.save
      @queries_failed += 1
      self.product_errors += new_product.errors.to_a.map{|e| "Product #{new_product.sku}: #{e.downcase}"}.uniq
    end
  end
  
  def create_variant(attr_hash)
    new_variant = Variant.new(attr_hash)
    begin
      new_variant.save
    rescue
      @queries_failed += 1
      self.product_errors += new_variant.errors.to_a.map{|e| "Variant #{new_variant.sku}: #{e.downcase}"}.uniq
    end
  end
  
  def update_products(products, attr_hash)
    products.each do |product|
      if product.update_attributes attr_hash
        @records_updated +=1
      else
        @records_failed += 1
        self.product_errors += product.errors.to_a.map{|e| "Product #{product.sku}: #{e.downcase}"}.uniq
      end
    end
  end
  
  def find_products_by_variant key, value
    products = Variant.includes(:product).where(key => value).all.map(&:product)
    @records_matched += products.size
    @queries_failed += 1 if products.size == 0
    
    products
  end
  
  def find_products key, value
    products = Product.where(key => value).all
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
    !self.processed_at.nil?
  end
  
  def deleted?
    !self.deleted_at.nil?
  end
end
