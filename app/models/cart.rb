require 'csv'

class Cart < ActiveRecord::Base
  has_many :cart_items
  has_one :approval_group

  def update_approval_status
    update_attributes(status: 'approved') if all_approvals_received?
  end

  def all_approvals_received?
    approval_group.approvers.where(status: 'approved').count == approval_group.approvers.count
  end

  def create_items_csv
    csv_string = CSV.generate do |csv|
    csv << ["description","details","vendor","url","notes","part_number","quantity","unit price","price for quantity"]
    cart_items.each do |item|
        csv << [item.description,item.details,item.vendor,item.url,item.notes,item.part_number,item.quantity,item.price,item.quantity*item.price]
        end
    end
    return csv_string
  end

  def self.initialize_cart_with_items(params)
    approval_group_name = params['approvalGroup']

    name = !params['cartName'].blank? ? params['cartName'] : params['cartNumber']

    existing_cart =  Cart.find_by(name: name)
    if existing_cart.blank?
      cart = Cart.new(name: name, status: 'pending', external_id: params['cartNumber'])

      if !approval_group_name.blank?
        cart.approval_group = ApprovalGroup.find_by_name(params['approvalGroup'])
      else
        cart.approval_group = ApprovalGroup.create(
                                name: "approval-group-#{params['cartNumber']}",
                                approvers_attributes: [
                                  { email_address: params['fromAddress'] }
                                ]
                              )
      end

    else

      cart = existing_cart
      cart.cart_items.destroy_all
      cart.approval_group = nil

      #TODO: Refactor duplicated code
      if !approval_group_name.blank?
        cart.approval_group = ApprovalGroup.find_by_name(params['approvalGroup'])
      else
        cart.approval_group = ApprovalGroup.create(
                                name: "approval-group-#{params['cartNumber']}",
                                approvers_attributes: [
                                  { email_address: params['fromAddress'] }
                                ]
                              )
      end
    end

    cart.save


    #TODO: accepts_nested_attributes_for
    #TODO: save green, socio, and features information
    params['cartItems'].each do |cart_item_params|
      CartItem.create(
        :vendor => cart_item_params['vendor'],
        :description => cart_item_params['description'],
        :url => cart_item_params['url'],
        :notes => cart_item_params['notes'],
        :quantity => cart_item_params['qty'],
        :details => cart_item_params['details'],
        :part_number => cart_item_params['partNumber'],
        :price => cart_item_params['price'].gsub(/[\$\,]/,"").to_f,
        :cart_id => cart.id
      )
    end
    return cart
  end

end

# TODO: states: awaiting_approvals, approved, rejected
