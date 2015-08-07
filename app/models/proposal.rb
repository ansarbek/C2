class Proposal < ActiveRecord::Base
  include WorkflowModel
  include ValueHelper
  has_paper_trail

  FLOWS = %w(parallel linear).freeze

  workflow do
    state :pending do
      event :approve, :transitions_to => :approved
      event :restart, :transitions_to => :pending
      event :cancel, :transitions_to => :cancelled
    end
    state :approved do
      event :restart, :transitions_to => :pending
      event :cancel, :transitions_to => :cancelled
      event :approve, :transitions_to => :approved do
        halt  # no need to trigger a state transition
      end
    end
    state :cancelled do
      event :approve, :transitions_to => :cancelled do
        halt  # can't escape
      end
    end
  end

  has_many :approvals
  has_many :individual_approvals, ->{ individual }, class_name: 'Approvals::Individual'
  has_many :approvers, through: :individual_approvals, source: :user
  has_many :api_tokens, through: :individual_approvals
  has_many :attachments
  has_many :approval_delegates, through: :approvers, source: :outgoing_delegates
  has_many :comments
  has_many :observations
  has_many :observers, through: :observations, source: :user
  belongs_to :client_data, polymorphic: true
  belongs_to :requester, class_name: 'User'

  # The following list also servers as an interface spec for client_datas
  # Note: clients may implement:
  # :fields_for_display
  # :public_identifier
  # :version
  # Note: clients should also implement :version
  delegate :client, to: :client_data, allow_nil: true

  validates :flow, presence: true, inclusion: {in: FLOWS}
  # TODO validates :requester_id, presence: true

  self.statuses.each do |status|
    scope status, -> { where(status: status) }
  end
  scope :closed, -> { where(status: ['approved', 'cancelled']) } #TODO: Backfill to change approvals in 'reject' status to 'cancelled' status
  scope :cancelled, -> { where(status: 'cancelled') }

  after_initialize :set_defaults
  after_create :update_public_id

  # @todo - this should probably be the only entry into the approval system
  def root_approval
    self.approvals.where(parent: nil).first
  end

  def set_defaults
    self.flow ||= 'parallel'
  end

  def parallel?
    self.flow == 'parallel'
  end

  def linear?
    self.flow == 'linear'
  end

  def delegate?(user)
    self.approval_delegates.exists?(assignee_id: user.id)
  end

  def existing_approval_for(user)
    where_clause = <<-SQL
      user_id = :user_id
      OR user_id IN (SELECT assigner_id FROM approval_delegates WHERE assignee_id = :user_id)
      OR user_id IN (SELECT assignee_id FROM approval_delegates WHERE assigner_id = :user_id)
    SQL
    self.approvals.where(where_clause, user_id: user.id).first
  end

  # TODO convert to an association
  def delegates
    self.approval_delegates.map(&:assignee)
  end

  # Returns a list of all users involved with the Proposal.
  def users
    # TODO use SQL
    results = self.approvers + self.observers + self.delegates + [self.requester]
    results.compact
  end

  def root_approval=(root)
    approval_list = root.preorder_list
    self.approvals = approval_list
    # position may be out of whack, so we reset it
    approval_list.each_with_index do |approval, idx|
      approval.set_list_position(idx + 1)   # start with 1
    end
    root.initialize!
    self.reset_status()
  end

  # convenience wrapper for setting a single approver
  def approver=(approver)
    # Don't recreate the approval
    existing = self.existing_approval_for(approver)
    if existing.nil?
      self.root_approval = Approvals::Individual.new(user: approver)
    end
  end

  def reset_status()
    unless self.cancelled?   # no escape from cancelled
      if self.root_approval.nil? || self.root_approval.approved?
        self.update(status: 'approved')
      else
        self.update(status: 'pending')
      end
    end
  end

  def add_observer(email)
    user = User.for_email(email)
    self.observations.find_or_create_by!(user: user)
  end

  def add_requester(email)
    user = User.for_email(email)
    self.set_requester(user)
  end

  def set_requester(user)
    self.update_attributes!(requester_id: user.id)
  end

  # Approvals in which someone can take action
  def currently_awaiting_approvals
    self.individual_approvals.actionable
  end

  def currently_awaiting_approvers
    self.approvers.merge(self.currently_awaiting_approvals)
  end

  # delegated, with a fallback
  # TODO refactor to class method in a module
  def delegate_with_default(method)
    data = self.client_data

    result = nil
    if data && data.respond_to?(method)
      result = data.public_send(method)
    end

    if result.present?
      result
    elsif block_given?
      yield
    else
      result
    end
  end


  ## delegated methods ##

  def public_identifier
    self.delegate_with_default(:public_identifier) { "##{self.id}" }
  end

  def name
    self.delegate_with_default(:name) {
      "Request #{self.public_identifier}"
    }
  end

  def fields_for_display
    # TODO better default
    self.delegate_with_default(:fields_for_display) { [] }
  end

  # Be careful if altering the identifier. You run the risk of "expiring" all
  # pending approval emails
  def version
    [
      self.updated_at.to_i,
      self.client_data.try(:version)
    ].compact.max
  end

  #######################


  def restart
    # Note that none of the state machine's history is stored
    self.api_tokens.update_all(expires_at: Time.now)
    self.approvals.update_all(status: 'pending')
    self.root_approval.initialize! if self.root_approval
    Dispatcher.deliver_new_proposal_emails(self)
  end

  # Returns True if the user is an approver and has acted on the proposal
  def is_active_approver? user
    current_approver = self.approvals.find_by user_id: user.id
    current_approver && current_approver.status != "pending"
  end


  protected
  def update_public_id
    self.update_attribute(:public_id, self.public_identifier)
  end
end
