require 'md5'
module Squeejee  #:nodoc:
  module Acts  #:nodoc:
    module Redeemable  #:nodoc:
      def self.included(base)
        base.extend(ClassMethods)
      end
      # This act provides the capabilities for redeeming and expiring models. Useful for things like
      # coupons, invitations, and special offers.
      #
      # Coupon example:
      #
      #   class Coupon < ActiveRecord::Base
      #     acts_as_redeemable :valid_for => 30.days, :code_length => 8 # optional expiration, code length
      #   end
      #
      #
      #   c = Coupon.new
      #   c.user_id = 1 # The user who created the coupon 
      #   c.save
      #   c.code 
      #       
      #   # "4D9110A3"
      module ClassMethods
        # Configuration options are:
        #
        # * +valid_for+ - specifies the duration until redeemable expire. Default is no expiration
        # * +code_length+ - set the length of the generated unique code. Default is six alphanumeric characters
        # * example: <tt>acts_as_redeemable :valid_for => 30.days, :code_length => 8</tt>
        def acts_as_redeemable(options = {})
          unless redeemable? # don't let AR call this twice
            cattr_accessor :valid_for
            cattr_accessor :code_length
            before_create :setup_new
            self.valid_for = options[:valid_for] unless options[:valid_for].nil?
            self.code_length = (options[:code_length].nil? ? 6 : options[:code_length])
          end
          include InstanceMethods
          # Generates an alphanumeric code using an MD5 hash
          # * +code_length+ - number of characters to return
          def generate_code(code_length=6)
            chars = ("a".."z").to_a + ("1".."9").to_a 
            new_code = Array.new(code_length, '').collect{chars[rand(chars.size)]}.join
            Digest::MD5.hexdigest(new_code)[0..(code_length-1)].upcase
          end

          # Generates unique code based on +generate_code+ method
          def generate_unique_code
            begin
              new_code = generate_code(self.code_length)
            end until !active_code?(new_code)
            new_code
          end
          
          # Checks the database to ensure the specified code is not taken
          def active_code?(code)
            find :first, :conditions => {:code => code}
          end
        end
        
        def redeemable? #:nodoc:
          self.included_modules.include?(InstanceMethods)
        end
      end
      
      module InstanceMethods

        # Marks the redeemable redeemed by the given user id
        # * +redeemed_by_id+ - id of redeeming user
        def redeem!(redeemed_by_id)
          unless self.redeemed? or self.expired?
            self.update_attributes({:redeemed_by_id => redeemed_by_id, :recipient_id => redeemed_by_id, :redeemed_at => Time.now}) 
            self.after_redeem
	        end
        end

        # Returns whether or not the redeemable has been redeemed
        def redeemed?
          self.redeemed_at?
        end

        # Returns whether or not the redeemable has expired
        def expired?
          self.expires_on? and self.expires_on < Time.now
        end

        def setup_new #:nodoc:
          self.code = self.class.generate_unique_code if self.code.blank?
          unless self.class.valid_for.nil? or self.expires_on?
            self.expires_on = self.created_at + self.class.valid_for
          end
        end
        
        #################### SOME EXTRA FUNCTIONALITY FOR COUPONS
        # This functionality is used when the coupon is applied to any product or item under certain conditions like: 
        
        # Minimum or Maximum Quantity of product
        # Minimum or Maximum order price
        # Begin and End dates for the coupon
        # Calculating the discount after looking the type of discount e.g. Dollar amount off a product
        # Can be used with any other coupon
        # Coupon can be applied to some distinct products or categories of products     
        # Span is given for coupon i.e. if not checked item count should be greater than min qty of item
        
        
        #calculates the total discount price on entire cart 
        def calculate_discount_price(cart, total_amount)
          tdiscount = 0
          if self.is_valid and checked_for_dates and checked_for_order_price(total_amount)  
           if self.discount_type.name == "Percent off a product" or self.discount_type.name == "Dollar amount off a product" 
             cart.cart_items.each do |item|
              if item[:item_type] == "Sku"
                if quantity_of_item_is_valid(item) and product_is_valid(item) and checked_for_span(cart, item)
                  item[:count].times do
                    tdiscount += self.discount_value if self.discount_type.name == "Dollar amount off a product" 
                    tdiscount += self.discount_value * item[:price] / 100 if self.discount_type.name == "Percent off a product"
                  end  
                end  
              end  
            end                
           elsif self.discount_type.name == "Percent off entire order" or self.discount_type.name == "Dollar amount off an entire order" 
            if checked_all_conditions_on_each_item_of_entire_cart(cart)
              tdiscount = self.discount_value * total_amount / 100 if self.discount_type.name == "Percent off entire order"
              tdiscount = self.discount_value if self.discount_type.name == "Dollar amount off an entire order" 
            end   
           end
          end  
          return tdiscount < 0 ? 0 : tdiscount
        end          

        def checked_all_conditions_on_each_item_of_entire_cart(cart)
          cart.cart_items.each do |item|
            return (quantity_of_item_is_valid(item) and product_is_valid(item) and checked_for_span(cart, item)) ? true : false if item[:item_type] == "Sku"
          end
        end  

        def product_is_valid(item)
          if self.products.blank? and self.categories.blank?
            return true
          elsif self.products.size > 0 and self.categories.size > 0
             self.sku_ids.include?(item[:item_id]) or collect_sku_ids_from_categories.include?(item[:item_id])
          elsif self.products.size > 0
            self.sku_ids.include?(item[:item_id])
          elsif self.categories.size > 0   
            collect_sku_ids_from_categories.include?(item[:item_id]) 
          end    
        end  

        def collect_sku_ids_from_categories
          return Sku.find_by_sql("SELECT DISTINCT skus.id FROM skus INNER JOIN categories_products ON categories_products.product_id = skus.product_id WHERE categories_products.category_id IN (#{self.category_ids}) ").collect{|s| s.id}
        end 

        def checked_for_span(cart, item)
          return self.span ? cart.cart_items.sum { |item| item[:count] } >= self.min_qty : item[:count] >= self.min_qty
        end    

        def checked_for_dates
          if !self.begin_date.nil? or !self.expires_on.nil?
            if !self.begin_date.nil? and !self.expires_on.nil?
              self.begin_date <= Time.today and Time.today <= self.expires_on 
            elsif !self.expires_on.nil?  
              Time.today <= self.expires_on 
            elsif !self.begin_date.nil? 
              self.begin_date <= Time.today 
            end             
          elsif !self.begin_date and !self.expires_on
            return true
          end  
        end

        def checked_for_order_price(total_amount)
          if self.min_order_price or self.max_order_price
            return (self.min_order_price <= total_amount and total_amount <= self.max_order_price) if self.min_order_price and self.max_order_price
            return self.min_order_price <= total_amount if self.min_order_price
            return total_amount <= self.max_order_price if self.max_order_price  
          else
            return true
          end  
        end          

        def quantity_of_item_is_valid(item)
          return self.max_qty ? (self.min_qty <= item[:count] and item[:count] <= self.max_qty) : true
        end
        
        #################### END OF SOME EXTRA FUNCTIONALITY FOR COUPONS
        
        
        # Callback for business logic to implement after redemption
        def after_redeem() end

      end
    end
  end
end