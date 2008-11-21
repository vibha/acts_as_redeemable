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
          self.code = self.class.generate_unique_code
          unless self.class.valid_for.nil? or self.expires_on?
            self.expires_on = self.created_at + self.class.valid_for
          end
        end
        
        #################### SOME EXTRA FUNCTIONALITY FOR COUPONS
        
        
        # Checks the database to ensure whether any order is attached to the coupon
      #  def coupon_attached?
        #  return true if self.orders 
     #   end       
        
        #Ensures whether to calculate the discount price or not
    #    def check
    #      if coupon_attached?
     #       self.orders.each do |order| 
    #          calculate_discount_price(order)
     #       end
    #      end    
    #    end  
        
        #calculates the discount price after testing all the options
        def calculate_discount_price(cart, total_amount)
           tdiscount = 0
          if self.accept_more and self.is_valid and checked_for_dates and checked_for_order_price(total_amount) and checked_for_span(cart) 
            self.update_attribute("is_valid", false) if self.one_time
            cart.cart_items.each do |item|
              if quantity_of_item_is_valid(item) and product_is_valid(item) and category_is_valid(item) 
                tdiscount += calculate_discount_looking_their_type(item) 
             end  
            end
          end  
          return tdiscount
        end          
        
        def product_is_valid(item)
          psku_ids = []
          self.products.each do |p|
            psku_ids << p.sku_ids
          end
          psku_ids.flatten.include?(item[:id]) if psku_ids
        end  
        
        def category_is_valid(item)
          pcat_ids = []
          sku = Sku.find_by_id(item[:id])
          self.products.each do |p|
            pcat_ids << p.category_ids
          end  
          if sku
            if pcat_ids and sku.product.category_ids
              arr = pcat_ids.flatten - sku.product.category_ids
              if arr.size == pcat_ids.flatten.size
                return false
              else
                return true
              end     
            else
              return false
            end
          else    
            return false  
          end  
        end  
        
        def checked_for_span(cart)
          if self.span
            unless self.min_qty
              self.min_qty = 0
            end  
            cart.cart_items.sum { |item| item[:count] } >= self.min_qty   
          else
            return false
          end    
        end  
        
      #  def checked_for_products(cart)
      #    psku_ids = []
       #   osku_ids = []
       #   self.products.each do |p|
       #     psku_ids << p.sku_ids
       #   end  
       #   cart.cart_items.each do |l|
        #    osku_ids << l[:id]
        #  end                          
        #  if psku_ids.flatten == osku_ids.flatten
        #    return true
        #  else
        #    return false
       #   end
       # end  
              
      #  def checked_for_categories(cart)      
      #    pcat_ids = []
      #    ocat_ids = []
      #    self.products.each do |p|
      #      pcat_ids << p.category_ids
      #    end
      #    cart.cart_items.each do |l|
      #      ocat_ids << Sku.find_by_id(l[:id]).product.category_ids
      #    end
      #    if pcat_ids.flatten == ocat_ids.flatten
       #     return true
      #    else
       #     return false
       #   end    
       # end     
              
        def checked_for_dates
          if self.begin_date or self.expires_on
            self.begin_date <= Time.today if self.begin_date 
            Time.today <= self.expires_on if self.expires_on 
          elsif self.begin_date and self.expires_on
             self.begin_date <= Time.today and Time.today <= self.expires_on    
          elsif !self.begin_date and !self.expires_on
            return true
          end  
        end
        
        def checked_for_order_price(total_amount)
          if self.min_order_price or self.max_order_price
            self.min_order_price <= total_amount if self.min_order_price
            total_amount <= self.max_order_price if self.max_order_price  
          elsif self.min_order_price and self.max_order_price
            self.min_order_price <= total_amount and total_amount <= self.max_order_price
          elsif !self.min_order_price and !self.max_order_price
            return true
          end  
        end          
          
        def quantity_of_item_is_valid(item)
            if self.min_qty or self.max_qty
              self.min_qty <= item[:count] if self.min_qty
              item[:count] <= self.max_qty if self.max_qty
            elsif self.min_qty and self.max_qty
              self.min_qty <= item[:count] and item[:count] <= self.max_qty  
            elsif !self.min_qty and !self.max_qty
              return true
            end 
        end  
      
        #calculates the total number of units in order
        def total_items(order)
          order.line_items.collect{|c| c.quantity}.sum
        end
        
        #calculates discount according to discount types
        def calculate_discount_looking_their_type(item)
          if self.discount_type.name == "Percent of a product"
            discount = self.discount_value * item[:price] / 100
          end 
        end  
        
        #################### END OF SOME EXTRA FUNCTIONALITY FOR COUPONS
        
        
        # Callback for business logic to implement after redemption
        def after_redeem() end

      end
    end
  end
end
