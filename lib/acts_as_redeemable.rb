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
          
          #################### SOME EXTRA FUNCTIONALITY FOR COUPONS
          
          
          # Checks the database to ensure whether any order is attached to the coupon
          def coupon_attached?
            return true if self.orders 
          end       
          
          #Ensures whether to calculate the discount price or not
          def check
            if coupon_attached?
              self.orders.each do |order| 
                calculate_discount_price(order)
              end
            end    
          end  
          
          #when to calculate the discount price
          def calculate_discount_price(order)
            if self.is_valid
              if checked_for_dates
                if checked_for_order_price
                  if checked_for_quantity
                    if self.span and order.line_items.collect{|c| c.quantity}.sum >= self.min_qty
                      if checked_for_products_and_categories(order)
                        calculate_discount_looking_their_type(self, order)
                        self.update_attribute(:is_valid => false) if self.one_time
                      end  
                    end
                  end
                end
              end
            end            
          end                  
          
          def checked_for_products_and_categories(order)
            psku_ids = []
            pcat_ids = []
            osku_ids = []
            ocat_ids = []
            self.products.each do |p|
              psku_ids << p.sku_ids
              pcat_ids << s.product.category_ids
            end                            
            order.line_items.each do |l|
              osku_ids << l.sku.id
              ocat_ids << l.sku.product.category_ids
            end  
            return true if psku_ids.flatten == osku_ids.flatten and pcat_ids.flatten == ocat_ids.flatten
          end  
                
          def checked_for_dates
            if self.begin_date or self.expires_on
            #  return self.begin_date <= order.created_at or order.created_at <= self.expires_on   
            elsif self.begin_date and self.expires_on
            #  return self.begin_date <= order.created_at and order.created_at <= self.expires_on
            elsif !self.begin_date and !self.expires_on
              return true
            else
              return false  
            end  
          end
          
          def checked_for_order_price
            if self.min_order_price or self.max_order_price
            #  return self.min_order_price <= order.total_amount or order.total_amount <= self.max_order_price
            elsif self.min_order_price and self.max_order_price
            #  return self.min_order_price <= order.total_amount and order.total_amount <= self.max_order_price
            elsif !self.min_order_price and !self.max_order_price
              return true
            else
              return false  
            end  
          end          
            
          def checked_for_quantity
            order.line_items.each do |item|
              if self.min_qty or self.max_qty
            #    return self.min_qty <= item.quantity or item.quantity <= self.max_qty
              elsif self.min_qty and self.max_qty
          #      return self.min_qty <= item.quantity or item.quantity <= self.max_qty
              elsif !self.min_qty and !self.max_qty
                return true
              elsif !self.span and  item.quantity >= self.min_qty 
                return true
              else
                return false
              end
            end    
          end  
        
          #calculates the total number of units in order
          def total_items(order)
            order.line_items.collect{|c| c.quantity}.sum
          end
          
          #calculates discount according to discount types
          def calculate_discount_looking_their_type(coupon, order)
            if coupon.discount_type == "PERCENT OFF A PRODUCT"
              return coupon.discount_value * order.price/100
            end 
          end  
          
          #################### END OF SOME EXTRA FUNCTIONALITY FOR COUPONS 
          
          
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
        
        # Callback for business logic to implement after redemption
        def after_redeem() end

      end
    end
  end
end
